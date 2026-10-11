#![no_main]

use libfuzzer_sys::fuzz_target;
use native_note_core::Request;

fuzz_target!(|input: &[u8]| {
	let carried = match Request::decode(input) {
		Ok(Request::Sync { writes, .. }) => writes.iter().map(|write| write.payload.len()).sum(),
		Ok(Request::Put { blob, .. }) => blob.len(),
		Ok(Request::Get) | Err(_) => 0,
	};
	assert!(carried <= input.len());
});
