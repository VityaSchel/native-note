use super::{Fault, INNER_MAX, Reply, collect_changes};
use crate::frame::{Changes, WriteResult, sync_response};
use crate::padding::pad;
use crate::types::{BlindedNoteId, Record, Seq, Version};
use crate::version::{NOTE_MAX, Status};
use std::convert::Infallible;

const MOST_WRITES: usize = (INNER_MAX - 13) / 40;
const MOST_RESULTS: usize = (INNER_MAX - 18) / 13;

type Library = [(Seq, Record)];

#[derive(Debug, PartialEq, Eq)]
struct Down(usize);

fn record(seq: u64, len: usize) -> (Seq, Record) {
	let tag = u128::from(seq);
	(
		Seq(seq),
		Record {
			id: BlindedNoteId((tag | 0x1d << 120).to_be_bytes()),
			v: Version(u32::try_from(seq % 7 + 1).expect("small")),
			write_id: (tag | 0x3e << 120).to_be_bytes(),
			payload: vec![seq.to_be_bytes()[7]; len],
		},
	)
}

fn accepted(count: usize) -> Vec<WriteResult> {
	(1..=count)
		.map(|index| WriteResult {
			status: Status::Accepted,
			v: Version(1),
			seq: Seq(u64::try_from(index).expect("fits")),
		})
		.collect()
}

fn next_after(library: &Library, after: Seq) -> Option<(Seq, Record)> {
	library
		.get(library.partition_point(|(seq, _)| *seq <= after))
		.cloned()
}

fn source(library: &Library) -> impl FnMut(Seq) -> Result<Option<(Seq, Record)>, Infallible> + '_ {
	move |after| Ok(next_after(library, after))
}

fn failing(
	library: &Library,
	fail_at: usize,
) -> impl FnMut(Seq) -> Result<Option<(Seq, Record)>, Down> + '_ {
	let mut calls = 0;
	move |after| {
		let call = calls;
		calls += 1;
		if call == fail_at {
			Err(Down(call))
		} else {
			Ok(next_after(library, after))
		}
	}
}

fn encoded_len(results: usize, records: &[Record]) -> usize {
	18 + 13 * results
		+ records
			.iter()
			.map(|record| 40 + record.payload.len())
			.sum::<usize>()
}

fn pull(results: &[WriteResult], since: Seq, latest: Seq, library: &Library) -> Changes {
	let changes =
		collect_changes(results.len(), since, latest, source(library)).expect("answerable");
	let inner = sync_response(results, &changes);
	assert_eq!(inner.len(), encoded_len(results.len(), &changes.records));

	let start = library.partition_point(|(seq, _)| *seq <= since);
	let end = start + changes.records.len();
	assert!(
		changes
			.records
			.iter()
			.eq(library[start..end].iter().map(|(_, record)| record))
	);
	if changes.more {
		assert!(end > start, "more with no changes");
		assert_eq!(changes.next_seq, library[end - 1].0);
		let (_, next) = &library[end];
		assert!(inner.len() + 40 + next.payload.len() > INNER_MAX);
	} else {
		assert_eq!(end, library.len());
		assert_eq!(changes.next_seq, latest);
	}

	assert!(pad(&inner).is_some(), "a page pads");
	changes
}

fn pull_all(library: &Library, first_results: &[WriteResult]) -> usize {
	let latest = library.last().map_or(Seq(0), |(seq, _)| *seq);
	let (mut results, mut since, mut pages) = (first_results, Seq(0), 0);
	loop {
		let changes = pull(results, since, latest, library);
		pages += 1;
		if !changes.more {
			return pages;
		}
		(results, since) = (&[], changes.next_seq);
	}
}

#[test]
fn the_error_reply_is_its_action_byte_padded_to_the_smallest_bucket() {
	let padded = Reply::error().0;
	assert_eq!(padded.len(), 256);
	assert_eq!(padded[..5], [0x00, 0x00, 0x00, 0x01, 0xff]);
	assert!(padded[5..].iter().all(|&byte| byte == 0));
}

#[test]
fn a_pull_with_nothing_new_answers_the_latest_seq_without_more() {
	let empty = Changes {
		records: Vec::new(),
		next_seq: Seq(9),
		more: false,
	};
	let library = [record(2, 10), record(5, 0), record(9, 3)];
	for since in [9, 10, u64::MAX] {
		assert_eq!(pull(&accepted(2), Seq(since), Seq(9), &library), empty);
	}
	assert_eq!(
		pull(&[], Seq(0), Seq(0), &[]),
		Changes {
			next_seq: Seq(0),
			..empty
		}
	);
}

#[test]
fn a_change_that_fills_the_budget_exactly_fits_and_one_byte_more_sets_more() {
	for count in [0, 1, MOST_WRITES] {
		let results = accepted(count);
		let fill = INNER_MAX - 18 - 13 * count - (40 + NOTE_MAX) - 40;
		let exact = [record(3, NOTE_MAX), record(7, fill), record(8, 0)];

		let fits = pull(&results, Seq(0), Seq(7), &exact[..2]);
		assert_eq!((fits.records.len(), fits.more), (2, false), "{count}");
		assert_eq!(sync_response(&results, &fits).len(), INNER_MAX);

		let full = pull(&results, Seq(0), Seq(8), &exact);
		assert_eq!(
			(full.records.len(), full.more, full.next_seq),
			(2, true, Seq(7)),
			"{count}"
		);
		let rest = pull(&[], Seq(7), Seq(8), &exact);
		assert_eq!((rest.records.len(), rest.more), (1, false), "{count}");

		let over = [record(3, NOTE_MAX), record(7, fill + 1)];
		let first = pull(&results, Seq(0), Seq(7), &over);
		assert_eq!(
			(first.records.len(), first.more, first.next_seq),
			(1, true, Seq(3)),
			"{count}"
		);
		let second = pull(&[], Seq(3), Seq(7), &over);
		assert_eq!((second.records.len(), second.more), (1, false), "{count}");
	}
}

#[test]
fn the_most_results_a_request_can_ask_for_and_a_maximum_size_change_fit_one_response() {
	assert_eq!(MOST_WRITES, 52_428);
	let results = accepted(MOST_WRITES);
	let library = [record(52_429, NOTE_MAX)];
	let changes = pull(&results, Seq(0), Seq(52_429), &library);
	assert_eq!((changes.records.len(), changes.more), (1, false));
	assert_eq!(sync_response(&results, &changes).len(), 1_730_198);
}

#[test]
fn a_change_that_fits_no_response_is_unanswerable() {
	let alone = INNER_MAX - 18 - 40;
	let fits = pull(&[], Seq(0), Seq(1), &[record(1, alone)]);
	assert_eq!(fits.records.len(), 1);
	assert_eq!(
		collect_changes(0, Seq(0), Seq(1), source(&[record(1, alone + 1)])),
		Err(Fault::Unanswerable)
	);

	let library = [record(1, 10), record(2, alone + 1)];
	let first = pull(&[], Seq(0), Seq(2), &library);
	assert_eq!(
		(first.records.len(), first.more, first.next_seq),
		(1, true, Seq(1))
	);
	assert_eq!(
		collect_changes(0, Seq(1), Seq(2), source(&library)),
		Err(Fault::Unanswerable)
	);
}

#[test]
fn results_that_leave_no_room_for_a_pending_change_are_unanswerable() {
	assert_eq!(MOST_RESULTS, 161_317);
	let library = [record(1, 0)];
	assert_eq!(
		collect_changes(MOST_RESULTS, Seq(0), Seq(1), source(&library)),
		Err(Fault::Unanswerable)
	);
}

#[test]
fn a_source_error_is_a_storage_fault_wherever_it_strikes() {
	let library: Vec<_> = (1..=5).map(|seq| record(seq, 100)).collect();
	for fail_at in 0..=5 {
		assert_eq!(
			collect_changes(2, Seq(0), Seq(5), failing(&library, fail_at)),
			Err(Fault::Storage(Down(fail_at)))
		);
	}
	let all = collect_changes(2, Seq(0), Seq(5), failing(&library, 6)).expect("no call fails");
	assert_eq!(all.records.len(), 5);
}

#[test]
fn pages_of_large_changes_cover_every_change_once_in_seq_order() {
	let sizes = [0, 1, 4 << 10, 64 << 10, 512 << 10, NOTE_MAX];
	let library: Vec<_> = (1..=64)
		.zip(sizes.iter().cycle())
		.map(|(seq, &len)| record(seq, len))
		.collect();
	let pages = pull_all(&library, &accepted(3));
	assert!(pages >= 8, "{pages} pages");
}

mod props {
	use super::{MOST_WRITES, accepted, pull_all, record};
	use crate::version::NOTE_MAX;
	use proptest::collection::vec;
	use proptest::prelude::*;

	fn change_len() -> impl Strategy<Value = usize> {
		prop_oneof![
			3 => 0..=4096usize,
			1 => 0..=NOTE_MAX,
			1 => Just(NOTE_MAX),
		]
	}

	fn result_count() -> impl Strategy<Value = usize> {
		prop_oneof![0..=16usize, 0..=MOST_WRITES]
	}

	proptest! {
		#![proptest_config(ProptestConfig::with_cases(64))]

		#[test]
		fn pages_cover_every_change_once_in_order_within_the_body_limit(
			changes in vec((1..=3u64, change_len()), 0..=16),
			results in result_count(),
		) {
			let mut seq = 0;
			let library: Vec<_> = changes
				.into_iter()
				.map(|(gap, len)| {
					seq += gap;
					record(seq, len)
				})
				.collect();
			pull_all(&library, &accepted(results));
		}
	}
}
