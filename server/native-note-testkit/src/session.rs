use crate::client::{self, Response, Status, WriteResult};
use crate::model::{Model, View};
use native_note_core::{BlindedNoteId, Record, Request, Seq, Version};

pub trait Exchange {
	fn seal(&mut self, inner: &[u8]) -> Vec<u8>;

	/// Posts a sealed request and returns the opened reply, panicking on anything but a sealed reply.
	fn post(&mut self, body: &[u8]) -> Vec<u8>;
}

#[derive(Clone, Copy)]
pub enum Sent {
	Sync {
		since: Seq,
		writes: &'static [Record],
	},
	Get,
	Put {
		v: Version,
	},
}

pub struct Captured {
	pub body: Vec<u8>,
	pub sent: Sent,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Replays {
	pub conflicts: usize,
	pub too_large: usize,
	pub gets: usize,
	pub puts: usize,
}

pub struct Device {
	since: Seq,
	view: View,
	received: Vec<(Seq, BlindedNoteId)>,
}

impl Default for Device {
	fn default() -> Self {
		Self {
			since: Seq(0),
			view: View::new(),
			received: Vec::new(),
		}
	}
}

impl Device {
	pub fn since(&self) -> Seq {
		self.since
	}

	pub fn view(&self) -> &View {
		&self.view
	}

	pub fn received(&self) -> &[(Seq, BlindedNoteId)] {
		&self.received
	}

	pub fn next_version(&self, id: &BlindedNoteId) -> Version {
		Version(self.view.get(id).map_or(0, |(v, _)| v.0) + 1)
	}
}

pub struct Session<E> {
	pub server: E,
	pub model: Model,
	pub captured: Vec<Captured>,
}

impl<E: Exchange> Session<E> {
	pub fn new(server: E) -> Self {
		Self {
			server,
			model: Model::default(),
			captured: Vec::new(),
		}
	}

	pub fn sync_once(
		&mut self,
		device: &mut Device,
		writes: &'static [Record],
	) -> (Vec<WriteResult>, bool) {
		let since = device.since;
		let inner = client::encode_request(&Request::Sync {
			since,
			writes: writes.to_vec(),
		});
		let body = self.server.seal(&inner);
		let inner = self.server.post(&body);
		let Response::Sync {
			results,
			changes,
			next_seq,
			more,
		} = client::decode_response(&inner)
		else {
			panic!("a sync gets a sync response");
		};
		let expected: Vec<_> = writes.iter().map(|write| self.model.apply(write)).collect();
		assert_eq!(results, expected);
		let delivered = self
			.model
			.check_changes(since, &changes, next_seq, more, inner.len());
		for (seq, change) in delivered.into_iter().zip(changes) {
			device.view.insert(change.id, (change.v, change.write_id));
			device.received.push((seq, change.id));
		}
		device.since = next_seq;
		self.captured.push(Captured {
			body,
			sent: Sent::Sync { since, writes },
		});
		(results, more)
	}

	pub fn sync(&mut self, device: &mut Device, writes: &'static [Record]) -> Vec<WriteResult> {
		let (results, mut more) = self.sync_once(device, writes);
		while more {
			more = self.sync_once(device, &[]).1;
		}
		results
	}

	pub fn get(&mut self) -> Response {
		let body = self.server.seal(&client::encode_request(&Request::Get));
		let response = client::decode_response(&self.server.post(&body));
		assert_eq!(response, self.model.get());
		self.captured.push(Captured {
			body,
			sent: Sent::Get,
		});
		response
	}

	pub fn put(&mut self, v: Version, blob: &'static [u8]) -> Response {
		let request = Request::Put {
			v,
			blob: blob.to_vec(),
		};
		let body = self.server.seal(&client::encode_request(&request));
		let response = client::decode_response(&self.server.post(&body));
		assert_eq!(response, self.model.put(v, blob));
		self.captured.push(Captured {
			body,
			sent: Sent::Put { v },
		});
		response
	}

	/// Checks the reply to a captured request posted again, which must change nothing.
	pub fn check_replay(&self, index: usize, inner: &[u8], replays: &mut Replays) {
		match (self.captured[index].sent, client::decode_response(inner)) {
			(
				Sent::Sync {
					since,
					writes: sent,
				},
				Response::Sync {
					results,
					changes,
					next_seq,
					more,
				},
			) => {
				let expected: Vec<_> = sent.iter().map(|write| self.model.judge(write)).collect();
				assert_eq!(results, expected, "replay {index}");
				for result in results {
					assert_eq!(result.seq, Seq(0), "replay {index}");
					match result.status {
						Status::Conflict => replays.conflicts += 1,
						Status::TooLarge => replays.too_large += 1,
						Status::Accepted => panic!("replay {index} stored a write"),
					}
				}
				self.model
					.check_changes(since, &changes, next_seq, more, inner.len());
			}
			(Sent::Get, response) => {
				assert_eq!(response, self.model.get(), "replay {index}");
				replays.gets += 1;
			}
			(Sent::Put { v }, response) => {
				assert_eq!(response, self.model.judge_put(v), "replay {index}");
				assert!(
					matches!(
						response,
						Response::Put {
							status: Status::Conflict,
							..
						}
					),
					"replay {index}"
				);
				replays.puts += 1;
			}
			(_, response) => panic!("replay {index} got the wrong action: {response:?}"),
		}
	}
}
