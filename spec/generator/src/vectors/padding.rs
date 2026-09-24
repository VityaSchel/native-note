use serde_json::{Value, json};

use super::file;
use crate::envelope;
use crate::hex::encode as hx;

pub fn padding() -> Value {
	let mut cases: Vec<Value> = [0usize, 251, 252, 253, 507, 508, 509, 1020, 1021]
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

	cases.push(json!({
		"name": "rejectNonBucketLength",
		"padded": hx(&[0u8; 128]),
		"paddedLength": 128,
		"unpads": envelope::unpad(&[0u8; 128]).is_ok(),
	}));
	cases.push(json!({
		"name": "rejectNonZeroFill",
		"padded": hx(&dirty),
		"unpads": envelope::unpad(&dirty).is_ok(),
	}));

	file(
		"padded = len_be32 ‖ inner ‖ zero fill, to the next doubling bucket from 256 B.",
		cases,
	)
}
