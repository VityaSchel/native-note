use crate::support::BODY_MAX;
use crate::support::client::{self, INNER_MAX, sync};
use crate::support::corpus::{SplitMix64, corpus, payload};
use native_note_core::{BlindedNoteId, DecodeError, Record, Request, Version};
use std::collections::BTreeSet;

const SMALL_NOTE_MAX: usize = 4 << 10;

fn small_notes() -> Vec<Record> {
	corpus()
		.iter()
		.filter(|note| note.payload.len() <= SMALL_NOTE_MAX)
		.cloned()
		.collect()
}

#[test]
fn the_corpus_batched_to_the_body_limit_decodes_back_equal() {
	let notes = corpus();
	let batches = client::batch(notes);
	let mut rng = SplitMix64::new(44);
	let (mut carried, mut full) = (0, 0);
	for (index, writes) in batches.iter().enumerate() {
		let since = match index {
			0 => 0,
			1 => u64::MAX,
			_ => rng.next_u64(),
		};
		let request = sync(since, writes);
		let inner = client::encode_request(&request);
		assert_eq!(inner.len(), client::sync_len(writes));
		let padded = client::pad(&inner).expect("every batch pads");
		assert_eq!(
			Request::decode(&inner).as_ref(),
			Ok(&request),
			"batch {index}"
		);
		if let Some(next) = notes.get(carried + writes.len()) {
			let grown = client::sync_len(&[writes, std::slice::from_ref(next)].concat());
			assert!(grown > INNER_MAX, "batch {index} is not full");
		}
		carried += writes.len();
		full += usize::from(padded.len() == BODY_MAX);
	}
	assert_eq!(carried, notes.len());
	assert!(batches.len() >= 25, "{} batches", batches.len());
	assert!(
		full >= batches.len() - 1,
		"{full} of {} batches are full",
		batches.len()
	);
	let total: usize = notes.iter().map(|note| note.payload.len()).sum();
	assert!((50 << 20..80 << 20).contains(&total), "{total} bytes");
}

#[test]
fn the_most_writes_one_request_can_carry_decode() {
	const MOST: usize = 52_428;
	let mut rng = SplitMix64::new(0x0005_2428);
	let writes: Vec<Record> = (0..=MOST)
		.map(|_| Record {
			id: BlindedNoteId(rng.array()),
			v: Version(1),
			write_id: rng.array(),
			payload: Vec::new(),
		})
		.collect();

	let request = sync(1, &writes[..MOST]);
	let inner = client::encode_request(&request);
	assert_eq!(inner.len(), 2_097_133);
	assert_eq!(
		client::pad(&inner).map(|padded| padded.len()),
		Some(BODY_MAX)
	);
	assert_eq!(Request::decode(&inner), Ok(request));

	let over = client::encode_request(&sync(1, &writes));
	assert!(over.len() > INNER_MAX);
	assert_eq!(client::pad(&over), None);
}

#[test]
fn every_prefix_of_a_twenty_write_request_is_truncated() {
	let mut rng = SplitMix64::new(20);
	let versions = [1, 2, 255, 256, 65_536, 0x0102_0304, u32::MAX - 1, u32::MAX];
	let writes: Vec<Record> = versions
		.iter()
		.cycle()
		.take(20)
		.map(|&v| Record {
			id: BlindedNoteId(rng.array()),
			v: Version(v),
			write_id: rng.array(),
			payload: payload(rng.between(48, 112), rng.next_u64()),
		})
		.collect();
	let request = sync(0x0102_0304_0506_0708, &writes);
	let inner = client::encode_request(&request);
	assert!(
		(2_000..3_000).contains(&inner.len()),
		"{} bytes",
		inner.len()
	);

	for cut in 0..inner.len() {
		assert_eq!(
			Request::decode(&inner[..cut]),
			Err(DecodeError::Truncated),
			"cut at {cut}"
		);
	}
	assert_eq!(Request::decode(&inner).as_ref(), Ok(&request));
	let mut longer = inner;
	longer.push(0x00);
	assert_eq!(Request::decode(&longer), Err(DecodeError::TrailingBytes));
}

#[test]
fn prefixes_cut_around_the_fields_of_a_full_batch_are_truncated() {
	let small = small_notes();
	let writes = client::batch(&small)[0];
	let request = sync(3, writes);
	let inner = client::encode_request(&request);
	assert_eq!(
		client::pad(&inner).map(|padded| padded.len()),
		Some(BODY_MAX)
	);

	let count = writes.len();
	assert!(count > 400, "{count} writes");
	let mut boundaries = vec![0, 1, 9, 13];
	let mut offset = 13;
	for (index, write) in writes.iter().enumerate() {
		let sampled = index < 20 || index >= count - 20 || index % 50 == 0;
		if sampled {
			boundaries.push(offset);
		}
		for len in [16, 4, 16, 4, write.payload.len()] {
			offset += len;
			if sampled {
				boundaries.push(offset);
			}
		}
	}
	assert_eq!(offset, inner.len());

	let cuts: BTreeSet<usize> = boundaries
		.iter()
		.flat_map(|&boundary| [boundary.saturating_sub(1), boundary, boundary + 1])
		.filter(|&cut| cut < inner.len())
		.collect();
	assert!(cuts.len() > 900, "{} cuts", cuts.len());
	for cut in cuts {
		assert_eq!(
			Request::decode(&inner[..cut]),
			Err(DecodeError::Truncated),
			"cut at {cut}"
		);
	}
	assert_eq!(Request::decode(&inner), Ok(request));
}

#[test]
fn an_unknown_action_is_reported_before_an_impossible_count() {
	let tail = [
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0xff, 0xff, 0xff, 0xff,
	];
	for action in (0x00..=0xff).filter(|action| !(0x01..=0x03).contains(action)) {
		let input = [&[action][..], &tail].concat();
		assert_eq!(
			Request::decode(&input),
			Err(DecodeError::UnknownDiscriminant),
			"action {action:02x}"
		);
		assert_eq!(
			Request::decode(&[action]),
			Err(DecodeError::UnknownDiscriminant),
			"action {action:02x}"
		);
	}
	let sync = [&[0x01][..], &tail].concat();
	assert_eq!(Request::decode(&sync), Err(DecodeError::Truncated));
}
