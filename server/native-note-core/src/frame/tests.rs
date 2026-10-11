use super::{Changes, WriteResult, get_response, put_response, sync_response};
use crate::tests::hex;
use crate::types::{BlindedNoteId, Record, Seq, Version};
use crate::version::Status;

const RECOVERY_BLOB: &str = "707172737475767778797a7bf3c4993bba7dc22d837691769329350ef83953a22430f40dceb4acbe193feb9ec3713126e6440746f49bffc271e6731e";

fn sequential<const N: usize>(first: u8) -> [u8; N] {
	std::array::from_fn(|index| first + u8::try_from(index).expect("small"))
}

fn no_changes(next_seq: u64) -> Changes {
	Changes {
		records: Vec::new(),
		next_seq: Seq(next_seq),
		more: false,
	}
}

#[test]
fn the_sync_result_vectors_encode_byte_for_byte() {
	for (name, status, v, seq, encoded) in [
		(
			"syncAccepted",
			Status::Accepted,
			1,
			1,
			"01000000010100000001000000000000000100000000000000000000000100",
		),
		(
			"syncConflict",
			Status::Conflict,
			1,
			0,
			"01000000010200000001000000000000000000000000000000000000000100",
		),
		(
			"syncConflictAtLastVersion",
			Status::Conflict,
			u32::MAX,
			0,
			"010000000102ffffffff000000000000000000000000000000000000000100",
		),
		(
			"syncTooLarge",
			Status::TooLarge,
			1,
			0,
			"01000000010300000001000000000000000000000000000000000000000100",
		),
	] {
		let results = [WriteResult {
			status,
			v: Version(v),
			seq: Seq(seq),
		}];
		assert_eq!(
			sync_response(&results, &no_changes(1)),
			hex(encoded),
			"{name}"
		);
	}
}

#[test]
fn the_sync_changes_vector_encodes_byte_for_byte() {
	let changes = Changes {
		records: vec![Record {
			id: BlindedNoteId(sequential(0x10)),
			v: Version(2),
			write_id: sequential(0x60),
			payload: sequential::<24>(0xd0).to_vec(),
		}],
		next_seq: Seq(4),
		more: true,
	};
	assert_eq!(
		sync_response(&[], &changes),
		hex(
			"010000000000000001101112131415161718191a1b1c1d1e1f00000002606162636465666768696a6b6c6d6e6f00000018d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7000000000000000401"
		)
	);
}

#[test]
fn the_recovery_response_vectors_encode_byte_for_byte() {
	assert_eq!(
		get_response(Version(2), &hex(RECOVERY_BLOB)),
		hex(&format!("02000000020000003c{RECOVERY_BLOB}"))
	);
	assert_eq!(get_response(Version(0), &[]), hex("020000000000000000"));
	assert_eq!(
		put_response(Status::Accepted, Version(3)),
		hex("030100000003")
	);
}
