#![no_main]

use libfuzzer_sys::fuzz_target;
use native_note_core::Request;
use native_note_testkit::client;

fuzz_target!(|input: &[u8]| {
	if let Ok(request) = Request::decode(input) {
		assert_eq!(client::encode_request(&request), input);
	}
});
