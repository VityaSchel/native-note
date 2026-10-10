use serde_json::{Value, json};

use super::file;
use crate::envelope::{self, MAX_BUCKET};
use crate::hex::encode as hx;

pub fn padding() -> Value {
	let lengths = [0, 251, 252, 253, 507, 508, 509, 1020, 1021, MAX_BUCKET - 4];
	let mut cases: Vec<Value> = lengths
		.iter()
		.map(|&len| {
			let inner = vec![0x41u8; len];
			let padded = envelope::pad(&inner).unwrap();
			json!({
				"name": format!("inner{len}"),
				"innerLength": len,
				"paddedLength": padded.len(),
				"lengthPrefix": hx(&padded[..4]),
				"roundTrips": envelope::unpad(&padded).unwrap() == inner,
			})
		})
		.collect();

	let mut dirty = envelope::pad(b"hi").unwrap();
	dirty[200] = 0xff;
	let mut larger = envelope::pad(b"hi").unwrap();
	larger.resize(512, 0);
	let mut past_end = envelope::pad(b"hi").unwrap();
	past_end[..4].copy_from_slice(&253u32.to_be_bytes());
	let above = vec![0x41u8; MAX_BUCKET - 3];
	let unpads = |name: &str, padded: &[u8]| {
		json!({
			"name": name,
			"padded": hx(padded),
			"paddedLength": padded.len(),
			"unpads": envelope::unpad(padded).is_some(),
		})
	};

	cases.push(json!({
		"name": "rejectAboveLargestBucket",
		"innerLength": above.len(),
		"pads": envelope::pad(&above).is_some(),
	}));
	cases.push(unpads("rejectNonBucketLength", &[0; 128]));
	cases.push(unpads("rejectLargerBucket", &larger));
	cases.push(unpads("rejectLengthPastEnd", &past_end));
	cases.push(json!({
		"name": "rejectNonZeroFill",
		"padded": hx(&dirty),
		"unpads": envelope::unpad(&dirty).is_some(),
	}));

	file(
		"padded = len_be32 ‖ inner ‖ zero fill, to the smallest doubling bucket from 256 B that holds it, up to the body limit, fixed at 2 MiB. Unpadding accepts only that bucket and zero fill.",
		cases,
	)
}
