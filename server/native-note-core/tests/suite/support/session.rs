use super::client::{self, Response, WriteResult};
use super::harness::Harness;
use super::memory::MemoryStorage;
use super::model::{Model, View};
use native_note_core::{BlindedNoteId, Record, Request, Seq, Version};

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

pub struct Session {
	pub harness: Harness,
	pub model: Model,
	pub captured: Vec<Captured>,
}

impl Session {
	pub fn new(api_key: [u8; 32]) -> Self {
		Self {
			harness: Harness::new(api_key, MemoryStorage::default()),
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
		let body = self.harness.seal(&inner);
		let inner = self.harness.post(&body);
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
		let body = self.harness.seal(&client::encode_request(&Request::Get));
		let response = client::decode_response(&self.harness.post(&body));
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
		let body = self.harness.seal(&client::encode_request(&request));
		let response = client::decode_response(&self.harness.post(&body));
		assert_eq!(response, self.model.put(v, blob));
		self.captured.push(Captured {
			body,
			sent: Sent::Put { v },
		});
		response
	}
}
