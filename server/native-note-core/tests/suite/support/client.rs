use super::BODY_MAX;
use native_note_core::{BlindedNoteId, Record, Request, Seq, Version};
use ring::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, KeyType, Salt};

const LEN_PREFIX: usize = 4;
const SYNC_HEADER: usize = 1 + 8 + 4;
const WRITE_HEADER: usize = 16 + 4 + 16 + 4;
pub const INNER_MAX: usize = BODY_MAX - LEN_PREFIX;

pub fn encode_request(request: &Request) -> Vec<u8> {
	let mut out = Vec::new();
	match request {
		Request::Sync { since, writes } => {
			out.push(0x01);
			out.extend_from_slice(&since.0.to_be_bytes());
			out.extend_from_slice(&width(writes.len()));
			for write in writes {
				out.extend_from_slice(&write.id.0);
				out.extend_from_slice(&write.v.0.to_be_bytes());
				out.extend_from_slice(&write.write_id);
				out.extend_from_slice(&width(write.payload.len()));
				out.extend_from_slice(&write.payload);
			}
		}
		Request::Get => out.push(0x02),
		Request::Put { v, blob } => {
			out.push(0x03);
			out.extend_from_slice(&v.0.to_be_bytes());
			out.extend_from_slice(&width(blob.len()));
			out.extend_from_slice(blob);
		}
	}
	out
}

fn width(len: usize) -> [u8; 4] {
	u32::try_from(len).expect("a field fits u32").to_be_bytes()
}

fn bucket(needed: usize) -> usize {
	let mut bucket = 256;
	while bucket < needed {
		bucket *= 2;
	}
	bucket
}

pub fn pad(inner: &[u8]) -> Option<Vec<u8>> {
	let bucket = bucket(LEN_PREFIX + inner.len());
	if bucket > BODY_MAX {
		return None;
	}
	let mut padded = width(inner.len()).to_vec();
	padded.extend_from_slice(inner);
	padded.resize(bucket, 0);
	Some(padded)
}

fn unpad(padded: &[u8]) -> Option<&[u8]> {
	let (len, rest) = padded.split_first_chunk::<LEN_PREFIX>()?;
	let len = usize::try_from(u32::from_be_bytes(*len)).expect("a u32 fits usize");
	let (inner, fill) = rest.split_at_checked(len)?;
	let canonical = padded.len() <= BODY_MAX
		&& padded.len() == bucket(LEN_PREFIX + len)
		&& fill.iter().all(|&byte| byte == 0);
	canonical.then_some(inner)
}

pub fn sync_len(writes: &[Record]) -> usize {
	SYNC_HEADER
		+ writes
			.iter()
			.map(|write| WRITE_HEADER + write.payload.len())
			.sum::<usize>()
}

pub fn batch(writes: &[Record]) -> Vec<&[Record]> {
	let mut batches = Vec::new();
	let mut start = 0;
	let mut len = SYNC_HEADER;
	for (index, write) in writes.iter().enumerate() {
		let write_len = WRITE_HEADER + write.payload.len();
		assert!(
			SYNC_HEADER + write_len <= INNER_MAX,
			"write {index} fits no request"
		);
		if len + write_len > INNER_MAX {
			batches.push(&writes[start..index]);
			start = index;
			len = SYNC_HEADER;
		}
		len += write_len;
	}
	if start < writes.len() {
		batches.push(&writes[start..]);
	}
	batches
}

struct KeyLen;

impl KeyType for KeyLen {
	fn len(&self) -> usize {
		32
	}
}

pub fn envelope_key(api_key: &[u8; 32]) -> [u8; 32] {
	let mut key = [0; 32];
	Salt::new(HKDF_SHA256, &[0; 32])
		.extract(api_key)
		.expand(&[b"native-note/envelope/v1".as_slice()], KeyLen)
		.and_then(|okm| okm.fill(&mut key))
		.expect("HKDF-SHA256 yields 32 bytes");
	key
}

pub fn seal(key: &[u8; 32], nonce: [u8; 12], padded: &[u8]) -> Vec<u8> {
	let key = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).expect("a 32-byte key"));
	let mut sealed = padded.to_vec();
	key.seal_in_place_append_tag(
		Nonce::assume_unique_for_key(nonce),
		Aad::empty(),
		&mut sealed,
	)
	.expect("seals");
	[&nonce[..], &sealed].concat()
}

pub fn seal_request(key: &[u8; 32], nonce: [u8; 12], inner: &[u8]) -> Vec<u8> {
	seal(
		key,
		nonce,
		&pad(inner).expect("the request fits the body limit"),
	)
}

pub fn open_response(key: &[u8; 32], request_nonce: &[u8; 12], body: &[u8]) -> Option<Vec<u8>> {
	let (nonce, sealed) = body.split_first_chunk::<12>()?;
	let key = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).expect("a 32-byte key"));
	let mut sealed = sealed.to_vec();
	let padded = key
		.open_in_place(
			Nonce::assume_unique_for_key(*nonce),
			Aad::from(request_nonce),
			&mut sealed,
		)
		.ok()?;
	Some(unpad(padded).expect("a response unpads").to_vec())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
	Accepted,
	Conflict,
	TooLarge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WriteResult {
	pub status: Status,
	pub v: Version,
	pub seq: Seq,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Response {
	Sync {
		results: Vec<WriteResult>,
		changes: Vec<Record>,
		next_seq: Seq,
		more: bool,
	},
	Get {
		v: Version,
		blob: Vec<u8>,
	},
	Put {
		status: Status,
		v: Version,
	},
	Error,
}

struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
	fn take(&mut self, len: usize) -> &'a [u8] {
		let Some((head, rest)) = self.0.split_at_checked(len) else {
			panic!("Truncated: {len} bytes wanted, {} left", self.0.len());
		};
		self.0 = rest;
		head
	}

	fn array<const N: usize>(&mut self) -> [u8; N] {
		self.take(N).try_into().expect("N bytes")
	}

	fn u8(&mut self) -> u8 {
		u8::from_be_bytes(self.array())
	}

	fn u32(&mut self) -> u32 {
		u32::from_be_bytes(self.array())
	}

	fn u64(&mut self) -> u64 {
		u64::from_be_bytes(self.array())
	}

	fn bytes(&mut self) -> Vec<u8> {
		let len = usize::try_from(self.u32()).expect("a u32 fits usize");
		self.take(len).to_vec()
	}

	fn status(&mut self) -> Status {
		match self.u8() {
			0x01 => Status::Accepted,
			0x02 => Status::Conflict,
			0x03 => Status::TooLarge,
			code => panic!("UnknownDiscriminant: status {code:#04x}"),
		}
	}
}

fn items<T>(cursor: &mut Cursor, item: fn(&mut Cursor) -> T) -> Vec<T> {
	let count = cursor.u32();
	let mut items = Vec::new();
	for _ in 0..count {
		items.push(item(cursor));
	}
	items
}

fn result(cursor: &mut Cursor) -> WriteResult {
	let status = cursor.status();
	let v = Version(cursor.u32());
	let seq = Seq(cursor.u64());
	assert!(
		status == Status::Accepted || seq.0 == 0,
		"NotCanonical: {status:?} with seq {}",
		seq.0
	);
	assert!(
		status != Status::Accepted || seq.0 != 0,
		"accepted with seq 0"
	);
	WriteResult { status, v, seq }
}

fn change(cursor: &mut Cursor) -> Record {
	Record {
		id: BlindedNoteId(cursor.array()),
		v: Version(cursor.u32()),
		write_id: cursor.array(),
		payload: cursor.bytes(),
	}
}

pub fn decode_response(inner: &[u8]) -> Response {
	let mut cursor = Cursor(inner);
	let response = match cursor.u8() {
		0x01 => {
			let results = items(&mut cursor, result);
			let changes = items(&mut cursor, change);
			let next_seq = Seq(cursor.u64());
			let more = match cursor.u8() {
				0x00 => false,
				0x01 => true,
				byte => panic!("NotCanonical: more is {byte:#04x}"),
			};
			assert!(!more || !changes.is_empty(), "more with no changes");
			Response::Sync {
				results,
				changes,
				next_seq,
				more,
			}
		}
		0x02 => {
			let v = Version(cursor.u32());
			let blob = cursor.bytes();
			assert!(v.0 != 0 || blob.is_empty(), "a blob at v 0");
			Response::Get { v, blob }
		}
		0x03 => {
			let status = cursor.status();
			assert!(
				status != Status::TooLarge,
				"UnknownDiscriminant: too_large on a put"
			);
			Response::Put {
				status,
				v: Version(cursor.u32()),
			}
		}
		0xff => Response::Error,
		action => panic!("UnknownDiscriminant: action {action:#04x}"),
	};
	assert!(
		cursor.0.is_empty(),
		"TrailingBytes: {} after the response",
		cursor.0.len()
	);
	response
}
