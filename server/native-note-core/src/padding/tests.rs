use super::{BODY_MAX, PADDED_MIN, pad, unpad};
use crate::tests::hex;
use serde_json::Value;
use std::path::Path;

fn length(value: &Value) -> usize {
	usize::try_from(value.as_u64().expect("a length")).expect("a usize")
}

fn padding_cases() -> Vec<Value> {
	let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/vectors/padding.json");
	let file: Value = serde_json::from_slice(&std::fs::read(path).expect("padding.json"))
		.expect("padding.json is JSON");
	file["cases"].as_array().expect("cases").clone()
}

fn buckets() -> impl Iterator<Item = usize> {
	std::iter::successors(Some(PADDED_MIN), |size| Some(size * 2))
		.take_while(|&size| size <= BODY_MAX)
}

#[test]
fn the_body_limit_is_two_mib_and_the_smallest_bucket_256_bytes() {
	assert_eq!(BODY_MAX, 2 << 20);
	assert_eq!(PADDED_MIN, 256);
	assert_eq!(buckets().count(), 14);
}

#[test]
fn every_padding_vector_holds() {
	let (mut round_trips, mut pads_not, mut unpads_not) = (0, 0, 0);
	for case in padding_cases() {
		let name = case["name"].as_str().expect("a name");
		if case["roundTrips"] == true {
			let inner = vec![0x41; length(&case["innerLength"])];
			let padded = pad(&inner).expect(name);
			assert_eq!(padded.len(), length(&case["paddedLength"]), "{name}");
			assert_eq!(
				padded[..4],
				hex(case["lengthPrefix"].as_str().expect("a hex prefix"))[..],
				"{name}"
			);
			assert_eq!(padded[4..4 + inner.len()], inner[..], "{name}");
			assert!(
				padded[4 + inner.len()..].iter().all(|&byte| byte == 0),
				"{name}"
			);
			assert_eq!(unpad(&padded), Some(&inner[..]), "{name}");
			round_trips += 1;
		} else if case["pads"] == false {
			assert_eq!(
				pad(&vec![0x41; length(&case["innerLength"])]),
				None,
				"{name}"
			);
			pads_not += 1;
		} else if case["unpads"] == false {
			let padded = hex(case["padded"].as_str().expect("a hex buffer"));
			if !case["paddedLength"].is_null() {
				assert_eq!(padded.len(), length(&case["paddedLength"]), "{name}");
			}
			assert_eq!(unpad(&padded), None, "{name}");
			unpads_not += 1;
		} else {
			panic!("padding.json case {name} is not replayed");
		}
	}
	assert_eq!((round_trips, pads_not, unpads_not), (10, 1, 4));
}

#[test]
fn every_bucket_boundary_pads_to_its_bucket_and_round_trips() {
	for size in buckets() {
		let filled = vec![0x5a; size - 4];
		let padded = pad(&filled).expect("fills its bucket");
		assert_eq!(padded.len(), size);
		assert_eq!(unpad(&padded), Some(&filled[..]));

		let over = vec![0x5a; size - 3];
		match pad(&over) {
			Some(padded) => {
				assert_eq!(padded.len(), size * 2);
				assert_eq!(unpad(&padded), Some(&over[..]));
			}
			None => assert_eq!(size, BODY_MAX),
		}
	}
}

#[test]
fn unpad_rejects_input_too_short_for_a_bucket() {
	for len in 0..=4 {
		assert_eq!(unpad(&vec![0; len]), None, "{len}");
	}
}

#[test]
fn unpad_rejects_a_length_prefix_past_the_end() {
	let mut padded = vec![0; PADDED_MIN];
	padded[..4].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(unpad(&padded), None);
	padded[..4].copy_from_slice(&253u32.to_be_bytes());
	assert_eq!(unpad(&padded), None);
	padded[..4].copy_from_slice(&252u32.to_be_bytes());
	assert_eq!(unpad(&padded), Some(&[0; 252][..]));
}

#[test]
fn unpad_rejects_each_non_zero_fill_byte() {
	let padded = pad(b"hi").expect("pads");
	for at in 6..padded.len() {
		let mut dirty = padded.clone();
		dirty[at] = 0x01;
		assert_eq!(unpad(&dirty), None, "{at}");
	}
	assert_eq!(unpad(&padded), Some(&b"hi"[..]));
}

#[test]
fn unpad_rejects_a_self_consistent_buffer_past_the_body_limit() {
	let size = BODY_MAX * 2;
	let mut padded = vec![0x5a; size];
	padded[..4].copy_from_slice(&u32::try_from(size - 4).expect("fits").to_be_bytes());
	assert_eq!(unpad(&padded), None);
}

mod props {
	use crate::padding::{BODY_MAX, PADDED_MIN, pad, unpad};
	use proptest::collection::vec;
	use proptest::prelude::*;
	use proptest::sample::Index;

	fn padded_or_not() -> impl Strategy<Value = Vec<u8>> {
		prop_oneof![
			vec(any::<u8>(), 0..=1024),
			(vec(any::<u8>(), 0..=600), any::<Index>(), any::<u8>()).prop_map(
				|(inner, at, byte)| {
					let mut padded = pad(&inner).expect("pads");
					let at = at.index(padded.len());
					padded[at] = byte;
					padded
				}
			),
			(vec(any::<u8>(), 0..=600), 0..=PADDED_MIN).prop_map(|(inner, len)| {
				let mut padded = pad(&inner).expect("pads");
				padded[..4].copy_from_slice(&u32::try_from(len).expect("small").to_be_bytes());
				padded
			}),
			(vec(any::<u8>(), 0..=600), 0..=2048usize).prop_map(|(inner, len)| {
				let mut padded = pad(&inner).expect("pads");
				padded.resize(len, 0);
				padded
			}),
		]
	}

	proptest! {
		#[test]
		fn pad_round_trips_into_the_smallest_bucket(inner in vec(any::<u8>(), 0..=4096)) {
			let padded = pad(&inner).expect("4 KiB pads");
			let needed = (inner.len() + 4).max(PADDED_MIN);
			prop_assert!(padded.len().is_power_of_two());
			prop_assert!(padded.len() >= needed && padded.len() < needed * 2);
			prop_assert!(padded.len() <= BODY_MAX);
			prop_assert_eq!(unpad(&padded), Some(&inner[..]));
		}

		#[test]
		fn whatever_unpads_is_exactly_what_pad_produces(padded in padded_or_not()) {
			if let Some(inner) = unpad(&padded) {
				prop_assert_eq!(pad(inner), Some(padded.clone()));
			}
		}
	}
}
