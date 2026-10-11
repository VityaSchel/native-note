#![no_main]

use libfuzzer_sys::fuzz_target;
use native_note_core::{Envelope, EnvelopeKey, Secret};
use ring::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, Salt};
use std::sync::LazyLock;

const API_KEY: [u8; 32] = [0x5a; 32];
const NONCE: [u8; 12] = [0x24; 12];
const BODY_MAX: usize = 2 << 20;
const SEALED_MAX: usize = BODY_MAX + 28;

static KEY: LazyLock<EnvelopeKey> =
	LazyLock::new(|| EnvelopeKey::derive(&Secret::new(API_KEY)).expect("derives"));

static CLIENT_KEY: LazyLock<LessSafeKey> = LazyLock::new(|| {
	Salt::new(HKDF_SHA256, &[0; 32])
		.extract(&API_KEY)
		.expand(&[b"native-note/envelope/v1"], &AES_256_GCM)
		.map(UnboundKey::from)
		.map(LessSafeKey::new)
		.expect("derives")
});

fn client_opens(body: &[u8]) -> bool {
	let Some((nonce, sealed)) = body.split_first_chunk::<12>() else {
		return false;
	};
	let nonce = Nonce::assume_unique_for_key(*nonce);
	let mut sealed = sealed.to_vec();
	CLIENT_KEY
		.open_in_place(nonce, Aad::empty(), &mut sealed)
		.is_ok()
}

fuzz_target!(|input: &[u8]| {
	let opened = Envelope::parse(input.to_vec()).and_then(|envelope| KEY.open(envelope));
	assert_eq!(
		opened.is_ok(),
		input.len() <= SEALED_MAX && client_opens(input)
	);

	if input.len() <= BODY_MAX {
		let mut sealed = input.to_vec();
		CLIENT_KEY
			.seal_in_place_append_tag(
				Nonce::assume_unique_for_key(NONCE),
				Aad::empty(),
				&mut sealed,
			)
			.expect("seals");
		let body = [NONCE.as_slice(), &sealed].concat();
		let opened = Envelope::parse(body)
			.and_then(|envelope| KEY.open(envelope))
			.expect("a sealed padded buffer opens");
		assert_eq!(opened.nonce(), NONCE);
		let _ = opened.request();
	}
});
