use super::{NOTE_MAX, Status, put_status, write_status};
use crate::types::{BlindedNoteId, Record, Version};

const LAST: u32 = u32::MAX;
const EDGES: [u32; 7] = [0, 1, 2, LAST / 2, LAST / 2 + 1, LAST - 1, LAST];
const REPLAY_EDGES: [u32; 5] = [0, 1, 2, LAST - 1, LAST];

fn write(v: u32, len: usize) -> Record {
	Record {
		id: BlindedNoteId([7; 16]),
		v: Version(v),
		write_id: [1; 16],
		payload: vec![0; len],
	}
}

fn protocol_status(stored: u32, v: u32, len: usize) -> Status {
	if len > 1024 * 1024 {
		Status::TooLarge
	} else if u64::from(v) == u64::from(stored) + 1 {
		Status::Accepted
	} else {
		Status::Conflict
	}
}

#[test]
fn the_note_limit_is_one_mib() {
	assert_eq!(NOTE_MAX, 1 << 20);
}

#[test]
fn a_write_failing_both_checks_gets_too_large() {
	for (too_large, conflicts, expected) in [
		(false, false, Status::Accepted),
		(false, true, Status::Conflict),
		(true, false, Status::TooLarge),
		(true, true, Status::TooLarge),
	] {
		let v = if conflicts { 1 } else { 2 };
		let len = if too_large { NOTE_MAX + 1 } else { NOTE_MAX };
		assert_eq!(
			write_status(Version(1), &write(v, len)),
			expected,
			"{too_large} {conflicts}"
		);
	}
}

#[test]
fn a_note_at_the_last_version_accepts_no_further_writes() {
	assert_eq!(
		write_status(Version(LAST - 1), &write(LAST, 0)),
		Status::Accepted
	);
	for v in [0, 1, LAST] {
		assert_eq!(
			write_status(Version(LAST), &write(v, 0)),
			Status::Conflict,
			"v {v}"
		);
	}
}

#[test]
fn the_recovery_blob_follows_the_version_rule() {
	let mut stored = Version(0);
	for (v, expected) in [
		(2, Status::Conflict),
		(1, Status::Accepted),
		(1, Status::Conflict),
		(3, Status::Conflict),
		(2, Status::Accepted),
	] {
		let status = put_status(stored, Version(v));
		assert_eq!(status, expected, "{stored:?} then v {v}");
		if status == Status::Accepted {
			stored = Version(v);
		}
	}
	assert_eq!(stored, Version(2));

	for v in [0, 1, LAST] {
		assert_eq!(
			put_status(Version(LAST), Version(v)),
			Status::Conflict,
			"v {v}"
		);
	}
}

#[test]
fn a_payload_at_the_note_limit_is_accepted_and_one_byte_more_is_too_large() {
	for (len, expected) in [
		(0, Status::Accepted),
		(NOTE_MAX - 1, Status::Accepted),
		(NOTE_MAX, Status::Accepted),
		(NOTE_MAX + 1, Status::TooLarge),
	] {
		assert_eq!(write_status(Version(0), &write(1, len)), expected, "{len}");
	}
}

#[test]
fn notes_and_the_recovery_blob_agree_with_the_protocol_formula_at_every_edge() {
	let mut tally = [0; 3];
	for len in [0, NOTE_MAX, NOTE_MAX + 1] {
		let mut record = write(0, len);
		for stored in EDGES {
			for v in EDGES {
				record.v = Version(v);
				let status = write_status(Version(stored), &record);
				assert_eq!(
					status,
					protocol_status(stored, v, len),
					"{stored} {v} {len}"
				);
				tally[status as usize] += 1;
			}
		}
	}
	assert_eq!(tally, [8, 90, 49]);

	for stored in EDGES {
		for v in EDGES {
			assert_eq!(
				put_status(Version(stored), Version(v)),
				protocol_status(stored, v, 0),
				"{stored} {v}"
			);
		}
	}
}

#[test]
fn a_write_or_put_at_or_below_the_stored_version_never_passes() {
	let mut replays = 0;
	for (len, expected) in [
		(0, Status::Conflict),
		(NOTE_MAX, Status::Conflict),
		(NOTE_MAX + 1, Status::TooLarge),
	] {
		let mut record = write(0, len);
		for stored in REPLAY_EDGES {
			for v in REPLAY_EDGES.into_iter().filter(|&v| v <= stored) {
				record.v = Version(v);
				assert_eq!(
					write_status(Version(stored), &record),
					expected,
					"{stored} {v} {len}"
				);
				assert_eq!(
					put_status(Version(stored), Version(v)),
					Status::Conflict,
					"{stored} {v}"
				);
				replays += 1;
			}
		}
	}
	assert_eq!(replays, 3 * 15);
}

mod props {
	use super::{protocol_status, write};
	use crate::types::Version;
	use crate::version::{NOTE_MAX, put_status, write_status};
	use proptest::prelude::*;

	fn version() -> impl Strategy<Value = u32> {
		prop_oneof![
			any::<u32>(),
			Just(0),
			Just(1),
			Just(u32::MAX - 1),
			Just(u32::MAX)
		]
	}

	fn offset() -> impl Strategy<Value = u32> {
		prop_oneof![any::<u32>(), 0..=2u32, Just(u32::MAX)]
	}

	fn payload_len() -> impl Strategy<Value = usize> {
		prop_oneof![0..=64usize, NOTE_MAX - 64..=NOTE_MAX + 64, 0..=2 * NOTE_MAX]
	}

	proptest! {
		#[test]
		fn notes_and_the_recovery_blob_follow_the_protocol_formula(
			stored in version(),
			offset in offset(),
			len in payload_len(),
		) {
			let v = stored.wrapping_add(offset);
			prop_assert_eq!(
				write_status(Version(stored), &write(v, len)),
				protocol_status(stored, v, len)
			);
			prop_assert_eq!(
				put_status(Version(stored), Version(v)),
				protocol_status(stored, v, 0)
			);
		}
	}
}
