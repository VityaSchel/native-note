use serde_json::Value;
use std::path::PathBuf;

pub enum Listing {
	Replayed {
		replayed: &'static [&'static str],
		client_only: &'static [&'static str],
	},
	ClientOnly,
}

pub const REGISTRY: [(&str, Listing); 13] = [
	("argon2.json", Listing::ClientOnly),
	("blinding.json", Listing::ClientOnly),
	("content.json", Listing::ClientOnly),
	(
		"envelope.json",
		Listing::Replayed {
			replayed: &[
				"request",
				"response",
				"rejectTruncated",
				"rejectResponseOpenedAsRequest",
				"errorForUnpaddableRequest",
				"errorForUndecodableRequest",
			],
			client_only: &[
				"rejectResponseUnderWrongRequestNonce",
				"rejectRequestOpenedAsResponse",
			],
		},
	),
	("export.json", Listing::ClientOnly),
	(
		"frames.json",
		Listing::Replayed {
			replayed: &[
				"syncEmpty",
				"syncOneWrite",
				"getRecovery",
				"putRecovery",
				"rejectUnknownAction",
				"rejectImpossibleCount",
				"rejectImpossibleLength",
				"rejectTrailingBytes",
				"rejectErrorAsRequest",
				"syncAccepted",
				"syncConflict",
				"syncConflictAtLastVersion",
				"syncTooLarge",
				"syncChanges",
				"getRecoveryResult",
				"getRecoveryEmpty",
				"putRecoveryResult",
				"error",
			],
			client_only: &[
				"rejectNonCanonicalBool",
				"rejectSeqOnNonAcceptedResult",
				"rejectUnknownStatus",
				"rejectBadItemBeforeShortCount",
				"rejectTooLargeOnPut",
				"rejectUnknownResponseAction",
				"rejectTrailingBytesAfterError",
			],
		},
	),
	(
		"hkdf.json",
		Listing::Replayed {
			replayed: &["envelopeKey"],
			client_only: &[
				"blindingKey",
				"noteKey",
				"machineId",
				"localDbKey",
				"localDbKeyWithoutMachineId",
			],
		},
	),
	("markdown.json", Listing::ClientOnly),
	("mnemonic.json", Listing::ClientOnly),
	("note.json", Listing::ClientOnly),
	(
		"padding.json",
		Listing::Replayed {
			replayed: &[
				"inner0",
				"inner251",
				"inner252",
				"inner253",
				"inner507",
				"inner508",
				"inner509",
				"inner1020",
				"inner1021",
				"inner2097148",
				"rejectAboveLargestBucket",
				"rejectNonBucketLength",
				"rejectLargerBucket",
				"rejectLengthPastEnd",
				"rejectNonZeroFill",
			],
			client_only: &[],
		},
	),
	(
		"recovery.json",
		Listing::Replayed {
			replayed: &[
				"getEmpty",
				"put",
				"putAgain",
				"getAfterConflict",
				"getOnJoin",
				"rotateOnB",
				"rotateOnAWithStalePin",
				"rejectBlobRotatedElsewhere",
			],
			client_only: &["blob", "rejectWrongRecoveryKey", "rejectWrongLength"],
		},
	),
	(
		"sync.json",
		Listing::Replayed {
			replayed: &[
				"step1", "step2", "step3", "step4", "step5", "step6", "step7",
			],
			client_only: &[],
		},
	),
];

pub fn vectors_dir() -> PathBuf {
	PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/vectors")
}

pub fn load(file: &str) -> Value {
	let path = vectors_dir().join(file);
	let bytes = std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
	serde_json::from_slice(&bytes).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

pub fn cases(file: &str) -> Vec<Value> {
	match load(file)["cases"].take() {
		Value::Array(cases) => cases,
		other => panic!("{file} cases are {other}"),
	}
}

pub fn replayed(file: &str) -> Vec<Value> {
	let Some((_, Listing::Replayed { replayed, .. })) =
		REGISTRY.iter().find(|(listed, _)| *listed == file)
	else {
		panic!("{file} is not listed as replayed");
	};
	cases(file)
		.into_iter()
		.filter(|case| replayed.iter().any(|name| case["name"] == *name))
		.collect()
}

pub fn case(file: &str, name: &str) -> Value {
	cases(file)
		.into_iter()
		.find(|case| case["name"] == name)
		.unwrap_or_else(|| panic!("{file} has no case {name}"))
}

pub fn hex_array<const N: usize>(value: &Value) -> [u8; N] {
	hex(value)
		.try_into()
		.unwrap_or_else(|bytes: Vec<u8>| panic!("{value} is {} bytes, not {N}", bytes.len()))
}

pub fn hex(value: &Value) -> Vec<u8> {
	let text = value
		.as_str()
		.unwrap_or_else(|| panic!("{value} is not a hex string"));
	assert!(text.len().is_multiple_of(2), "{text} has an odd length");
	(0..text.len())
		.step_by(2)
		.map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap_or_else(|_| panic!("{text}")))
		.collect()
}
