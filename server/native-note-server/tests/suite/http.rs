use crate::support::{
	Client, DEADLINE, IO, Running, api_key, call, call_inner, connect, hasty, post, read_reply,
	request, runtime, send, serve_at, start,
};
use native_note_core::{Request, Seq, Version};
use native_note_testkit::SEALED_MAX;
use native_note_testkit::client::{self, Response, Status, sync};
use native_note_testkit::corpus::{payload, write};
use native_note_testkit::session::Exchange;
use rusqlite::Connection;
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// Holds the database's write lock from another connection until told to let go.
fn hold_write_lock(data: &Path) -> (Sender<()>, JoinHandle<()>) {
	let connection = Connection::open(data.join("native-note.sqlite")).expect("opens");
	connection
		.execute_batch("BEGIN IMMEDIATE")
		.expect("takes the write lock");
	let (release, released) = mpsc::channel();
	let holder = thread::spawn(move || {
		released.recv().ok();
		connection.execute_batch("ROLLBACK").expect("lets go");
	});
	(release, holder)
}

fn head_of(len: usize, body: &[u8]) -> Vec<u8> {
	let fixed = format!(
		"POST / HTTP/1.1\r\nContent-Length: {}\r\nX-Pad: \r\n\r\n",
		body.len()
	);
	let pad = "a".repeat(len - fixed.len());
	[
		format!(
			"POST / HTTP/1.1\r\nContent-Length: {}\r\nX-Pad: {pad}\r\n\r\n",
			body.len()
		)
		.as_bytes(),
		body,
	]
	.concat()
}

fn status(running: &Running, bytes: &[u8]) -> Option<u16> {
	send(running.address, bytes).map(|reply| {
		assert!(
			reply.status == 200 || reply.body.is_empty(),
			"{}",
			reply.head
		);
		reply.status
	})
}

#[test]
fn malformed_or_unopenable_requests_get_a_bare_400_and_no_log_line() {
	let running = start("http-400");
	let sealed = running
		.client(3)
		.seal(&client::encode_request(&Request::Get));
	let foreign = Client::new(running.address, [7; 32], 3).seal(&[0x02]);
	let cases: Vec<(&str, Vec<u8>)> =
		vec![
		("GET", b"GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n".to_vec()),
		(
			"path",
			[
				format!("POST /x HTTP/1.1\r\nContent-Length: {}\r\n\r\n", sealed.len()).as_bytes(),
				&sealed,
			]
			.concat(),
		),
		(
			"chunked",
			[
				&b"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 300\r\n\r\n"[..],
				&sealed,
			]
			.concat(),
		),
		("no length", b"POST / HTTP/1.1\r\nHost: x\r\n\r\n".to_vec()),
		("short", request(&[0; 27])),
		("foreign key", request(&foreign)),
		("tampered", request(&[&sealed[..40], &[sealed[40] ^ 1], &sealed[41..]].concat())),
		("head of 8 KiB and a byte", head_of(8193, &sealed)),
	];
	for (name, bytes) in cases {
		assert_eq!(status(&running, &bytes), Some(400), "{name}");
	}
	for (name, bytes) in [
		("plain", request(&sealed)),
		("head of 8 KiB", head_of(8192, &sealed)),
		(
			"bytes after the body",
			[request(&sealed), b"!".to_vec()].concat(),
		),
	] {
		assert_eq!(status(&running, &bytes), Some(200), "{name}");
	}
	assert_eq!(running.log.lines(), Vec::<String>::new());
}

#[test]
fn an_oversized_body_gets_413_before_any_of_it_is_sent() {
	let running = start("http-413");
	let mut stream = connect(running.address);
	write!(
		stream,
		"POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
		SEALED_MAX + 1
	)
	.expect("sends the head");
	let reply = read_reply(stream).expect("a reply");
	assert_eq!((reply.status, reply.body.len()), (413, 0));

	let mut uploading = connect(running.address);
	write!(
		uploading,
		"POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
		SEALED_MAX + 1
	)
	.expect("sends the head");
	uploading
		.write_all(&payload(256 << 10, 1))
		.expect("keeps sending the body");
	uploading.shutdown(Shutdown::Write).ok();
	let reply = read_reply(uploading).expect("the refusal outlives the upload");
	assert_eq!(reply.status, 413);

	let mut client = running.client(4);
	let largest = client.seal(&[0; (2 << 20) - 4]);
	assert_eq!(largest.len(), SEALED_MAX);
	let reply = post(running.address, &largest);
	let inner = client.open(&largest, &reply).expect("opens");
	assert_eq!(client::decode_response(&inner), Response::Error);
	assert_eq!(
		running.log.lines(),
		["level=error event=request_failed failure=decode cause=UnknownDiscriminant"]
	);
}

#[test]
fn a_request_that_unseals_but_does_not_decode_gets_a_sealed_error_and_one_log_line() {
	let running = start("http-decode");
	let mut client = running.client(5);
	assert_eq!(call_inner(&mut client, &[0x02, 0x00]), Response::Error);
	let unpadded = client::seal(&client::envelope_key(&running.key), [9; 12], &[0; 300]);
	let reply = post(running.address, &unpadded);
	let inner = client.open(&unpadded, &reply).expect("opens");
	assert_eq!(client::decode_response(&inner), Response::Error);
	assert_eq!(
		running.log.lines(),
		[
			"level=error event=request_failed failure=decode cause=TrailingBytes",
			"level=error event=request_failed failure=decode cause=Padding",
		]
	);
}

#[test]
fn a_body_cut_short_gets_no_reply_and_no_log_line() {
	let running = start("http-short");
	let body = running.client(5).seal(&[0x02]);
	let whole = request(&body);
	assert!(send(running.address, &whole[..whole.len() - 10]).is_none());
	assert_eq!(status(&running, &whole), Some(200));
	assert_eq!(running.log.lines(), Vec::<String>::new());
}

#[test]
fn an_expect_header_gets_no_interim_response() {
	let running = start("http-expect");
	let mut client = running.client(6);
	let body = client.seal(&client::encode_request(&Request::Get));
	let mut stream = connect(running.address);
	write!(
		stream,
		"POST / HTTP/1.1\r\nExpect: 100-continue\r\ncontent-length:{}\r\n\r\n",
		body.len()
	)
	.expect("sends the head");
	thread::sleep(IO / 3);
	stream.write_all(&body).expect("sends the body");
	let reply = read_reply(stream).expect("a reply");
	assert!(
		reply.head.starts_with("HTTP/1.1 200 OK\r\n"),
		"{}",
		reply.head
	);
	assert_eq!(
		client::decode_response(&client.open(&body, &reply).expect("opens")),
		Response::Get {
			v: Version(0),
			blob: Vec::new()
		}
	);
}

fn closed_after(address: SocketAddr, trickle: Option<Duration>) -> Duration {
	let started = Instant::now();
	let mut stream = connect(address);
	stream.write_all(b"POST / HT").expect("starts a head");
	if let Some(every) = trickle {
		let writer = stream.try_clone().expect("clones");
		thread::spawn(move || {
			let mut writer = writer;
			while writer.write_all(b"X").is_ok() {
				thread::sleep(every);
			}
		});
	}
	let mut rest = Vec::new();
	stream.read_to_end(&mut rest).ok();
	assert!(rest.is_empty(), "{rest:?}");
	started.elapsed()
}

#[test]
fn a_stalled_client_is_closed_at_the_read_timeout_and_a_trickling_one_at_the_deadline() {
	let running = start("http-slow");
	let address = serve_at(running.data.path(), hasty(&running.log));
	let stalled = closed_after(address, None);
	assert!(stalled >= IO && stalled < DEADLINE, "{stalled:?}");
	let trickling = closed_after(address, Some(IO / 4));
	assert!(
		trickling >= DEADLINE && trickling < DEADLINE + IO,
		"{trickling:?}"
	);
	assert_eq!(running.log.lines(), Vec::<String>::new());
}

#[test]
fn stalled_clients_hold_only_their_own_workers_and_the_ninth_waits_in_the_backlog() {
	let running = start("http-workers");
	let address = serve_at(running.data.path(), hasty(&running.log));
	let mut client = Client::new(address, running.key, 7);
	let stall = |count: usize| -> Vec<TcpStream> {
		let streams: Vec<_> = (0..count).map(|_| connect(address)).collect();
		thread::sleep(IO / 6);
		streams
	};

	let seven = stall(7);
	let started = Instant::now();
	let Response::Sync { results, .. } = call(&mut client, &sync(0, &[write(1, 1, 64)])) else {
		panic!("a sync response");
	};
	assert_eq!(results[0].status, Status::Accepted);
	assert!(started.elapsed() < IO * 3 / 4, "{:?}", started.elapsed());
	drop(seven);

	thread::sleep(IO * 2);
	let eight = stall(8);
	let started = Instant::now();
	let Response::Sync { changes, .. } = call(&mut client, &sync(0, &[])) else {
		panic!("a sync response");
	};
	assert_eq!(changes, [write(1, 1, 64)]);
	assert!(started.elapsed() >= IO / 2, "{:?}", started.elapsed());
	drop(eight);
}

#[test]
fn concurrent_clients_each_get_their_writes_with_distinct_seqs() {
	let running = Arc::new(start("http-concurrent"));
	let workers: Vec<_> = (0..16_u8)
		.map(|worker| {
			let running = Arc::clone(&running);
			thread::spawn(move || {
				let mut client = running.client(u64::from(worker) + 100);
				let mut seqs = Vec::new();
				for round in 0..8_u8 {
					let write = write(worker * 8 + round, 1, 2_000);
					let Response::Sync { results, .. } = call(&mut client, &sync(0, &[write]))
					else {
						panic!("a sync response");
					};
					assert_eq!(results[0].status, Status::Accepted);
					seqs.push(results[0].seq);
				}
				seqs
			})
		})
		.collect();
	let mut seqs: Vec<Seq> = workers
		.into_iter()
		.flat_map(|worker| worker.join().expect("finishes"))
		.collect();
	seqs.sort();
	assert_eq!(seqs, (1..=128).map(Seq).collect::<Vec<_>>());
}

#[test]
fn a_storage_failure_answers_a_sealed_error_logged_by_category_and_stores_nothing() {
	let running = start("http-busy");
	let (release, holder) = hold_write_lock(running.data.path());
	let mut client = running.client(8);
	assert_eq!(
		call(&mut client, &sync(0, &[write(1, 1, 64)])),
		Response::Error
	);
	release.send(()).expect("lets go");
	holder.join().expect("lets go");
	assert_eq!(
		running.log.lines(),
		["level=error event=request_failed failure=storage cause=sqlite:DatabaseBusy"]
	);
	let Response::Sync { changes, .. } = call(&mut client, &sync(0, &[])) else {
		panic!("a sync response");
	};
	assert_eq!(changes, []);
}

#[test]
fn a_failed_nonce_draw_or_a_reflected_nonce_answers_500_and_one_log_line() {
	let running = start("http-500");
	let mut broken = runtime(&running.log);
	broken.fill = |_| Err(ring::error::Unspecified);
	let failing = serve_at(running.data.path(), broken);
	let mut reflecting = runtime(&running.log);
	reflecting.fill = |bytes| {
		bytes.fill(0x24);
		Ok(())
	};
	let reflected = serve_at(running.data.path(), reflecting);

	let key = client::envelope_key(&api_key(running.data.path()));
	let push = client::encode_request(&sync(0, &[write(1, 1, 64)]));
	for (address, body) in [
		(failing, client::seal_request(&key, [0x23; 12], &push)),
		(reflected, client::seal_request(&key, [0x24; 12], &[0x02])),
	] {
		let reply = post(address, &body);
		assert_eq!((reply.status, reply.body.len()), (500, 0));
	}
	let Response::Sync { changes, .. } = call(&mut running.client(11), &sync(0, &[])) else {
		panic!("a sync response");
	};
	assert_eq!(changes, []);
	assert_eq!(
		running.log.lines(),
		[
			"level=error event=request_failed failure=random",
			"level=error event=request_failed failure=seal",
		]
	);
	let reply = post(reflected, &client::seal_request(&key, [0x25; 12], &[0x02]));
	assert_eq!(reply.status, 200);
}

#[test]
fn a_reply_ready_only_after_the_deadline_is_not_sent_and_is_logged_as_a_failed_response() {
	let running = start("http-late");
	let address = serve_at(running.data.path(), hasty(&running.log));
	let (release, holder) = hold_write_lock(running.data.path());
	let body = running
		.client(9)
		.seal(&client::encode_request(&sync(0, &[write(1, 1, 64)])));
	let mut stream = connect(address);
	stream.write_all(&request(&body)).expect("sends");
	thread::sleep(DEADLINE + IO);
	release.send(()).expect("lets go");
	holder.join().expect("lets go");
	assert!(read_reply(stream).is_none());
	assert_eq!(
		running.log.lines(),
		["level=error event=request_failed failure=respond cause=io:TimedOut"]
	);
	let Response::Sync { changes, .. } = call(&mut running.client(10), &sync(0, &[])) else {
		panic!("a sync response");
	};
	assert_eq!(changes, [write(1, 1, 64)]);
}
