use crate::NOTE_MAX;
use crate::client::{self, Response, Status, WriteResult};
use crate::corpus::{SplitMix64, corpus, payload};
use crate::session::{Device, Exchange, Session};
use native_note_core::{Record, Seq, Version};
use std::collections::BTreeMap;

pub fn result(status: Status, v: u32, seq: u64) -> WriteResult {
	WriteResult {
		status,
		v: Version(v),
		seq: Seq(seq),
	}
}

fn get(v: u32, blob: &[u8]) -> Response {
	Response::Get {
		v: Version(v),
		blob: blob.to_vec(),
	}
}

fn put(status: Status, v: u32) -> Response {
	Response::Put {
		status,
		v: Version(v),
	}
}

fn leak_blob(rng: &mut SplitMix64) -> &'static [u8] {
	Vec::leak(payload(60, rng.next_u64()))
}

fn edits(device: &Device, originals: &[&Record], rng: &mut SplitMix64) -> &'static [Record] {
	let edits = originals
		.iter()
		.map(|original| Record {
			id: original.id,
			v: device.next_version(&original.id),
			write_id: rng.array(),
			payload: payload(original.payload.len(), rng.next_u64()),
		})
		.collect();
	Vec::leak(edits)
}

fn push<E: Exchange>(
	session: &mut Session<E>,
	device: &mut Device,
	writes: &'static [Record],
) -> Vec<Status> {
	client::batch(writes)
		.into_iter()
		.flat_map(|batch| session.sync(device, batch))
		.map(|result| result.status)
		.collect()
}

/// Three devices push the corpus, edit into conflicts, rotate the recovery blob and page a full pull.
pub fn three_devices<E: Exchange>(session: &mut Session<E>) {
	let (a_notes, b_notes) = corpus().split_at(1_500);
	let mut rng = SplitMix64::new(50);
	let (mut a, mut b, mut c) = (Device::default(), Device::default(), Device::default());

	let blob_a = leak_blob(&mut rng);
	assert_eq!(session.get(), get(0, &[]));
	assert_eq!(session.put(Version(1), blob_a), put(Status::Accepted, 1));
	assert_eq!(session.put(Version(1), blob_a), put(Status::Conflict, 1));
	assert_eq!(session.get(), get(1, blob_a));

	let statuses = push(session, &mut a, a_notes);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));
	assert_eq!(session.get(), get(1, blob_a));
	let statuses = push(session, &mut b, b_notes);
	let too_large: Vec<_> = (0..b_notes.len())
		.filter(|&index| statuses[index] == Status::TooLarge)
		.collect();
	assert_eq!(too_large, [489]);
	assert_eq!(b_notes[489].payload.len(), NOTE_MAX + 1);
	assert_eq!(session.model.latest(), Seq(1_999));
	assert_eq!(b.view(), &session.model.view());

	let chosen: Vec<&Record> = (0..200).map(|k| &a_notes[k * 7 + 6]).collect();
	let first: Vec<&Record> = chosen.iter().step_by(4).copied().collect();
	assert!(chosen.iter().any(|note| note.payload.len() == NOTE_MAX));
	let a_edits = edits(&a, &first, &mut rng);
	let statuses = push(session, &mut a, a_edits);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));
	let b_edits = edits(&b, &chosen, &mut rng);
	let statuses = push(session, &mut b, b_edits);
	let conflicted: Vec<&Record> = chosen
		.iter()
		.zip(&statuses)
		.filter(|&(_, &status)| status == Status::Conflict)
		.map(|(&note, _)| note)
		.collect();
	assert!(
		conflicted
			.iter()
			.map(|note| note.id)
			.eq(first.iter().map(|note| note.id))
	);
	assert_eq!(statuses.len() - conflicted.len(), 150);
	let rewrites = edits(&b, &conflicted, &mut rng);
	assert!(rewrites.iter().all(|edit| edit.v == Version(3)));
	let statuses = push(session, &mut b, rewrites);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));

	let blob_b = leak_blob(&mut rng);
	assert_eq!(session.put(Version(2), blob_b), put(Status::Accepted, 2));
	let stale = leak_blob(&mut rng);
	assert_eq!(session.put(Version(2), stale), put(Status::Conflict, 2));
	assert_eq!(session.get(), get(2, blob_b));

	let mut pages = 0;
	while pages < 15 {
		assert!(session.sync_once(&mut c, &[]).1, "page {pages}");
		pages += 1;
	}
	let had = c.received()[0].1;
	let lacking = b_notes[b_notes.len() - 1].id;
	assert!(session.model.current(&had).0 <= c.since());
	assert!(session.model.current(&lacking).0 > c.since());
	assert!(!c.view().contains_key(&lacking));
	session.sync(&mut a, &[]);
	let originals = [
		session.model.current(&had).1,
		session.model.current(&lacking).1,
	];
	let a_rewrites = edits(&a, &originals, &mut rng);
	assert_eq!(
		session.sync(&mut a, a_rewrites),
		[
			result(Status::Accepted, 2, 2_250),
			result(Status::Accepted, 2, 2_251)
		]
	);
	while session.sync_once(&mut c, &[]).1 {
		pages += 1;
	}
	pages += 1;
	let bytes = session.model.payload_bytes();
	assert!((50 << 20..80 << 20).contains(&bytes), "{bytes} bytes");
	assert!(
		pages >= 30 && pages > bytes / client::INNER_MAX,
		"{pages} pages"
	);

	let seqs: Vec<Seq> = c.received().iter().map(|&(seq, _)| seq).collect();
	assert!(seqs.windows(2).all(|pair| pair[0] < pair[1]));
	let mut receipts = BTreeMap::new();
	for (_, id) in c.received() {
		*receipts.entry(*id).or_insert(0) += 1;
	}
	assert_eq!(receipts.len(), 1_999);
	assert_eq!((receipts[&had], receipts[&lacking]), (2, 1));
	assert_eq!(receipts.values().sum::<usize>(), 2_000);
	assert_eq!(c.received().last(), Some(&(Seq(2_251), lacking)));

	session.sync(&mut a, &[]);
	session.sync(&mut b, &[]);
	let view = session.model.view();
	assert_eq!(view.len(), 1_999);
	assert_eq!((a.view(), b.view(), c.view()), (&view, &view, &view));
	assert_eq!(session.model.latest(), Seq(2_251));
}

/// Shuffles the captured requests deterministically, keeping at least one out of order.
pub fn shuffled(count: usize, rng: &mut SplitMix64) -> Vec<usize> {
	let mut order: Vec<usize> = (0..count).collect();
	for last in (1..count).rev() {
		order.swap(last, rng.between(0, last));
	}
	assert!(order.windows(2).any(|pair| pair[0] > pair[1]));
	order
}
