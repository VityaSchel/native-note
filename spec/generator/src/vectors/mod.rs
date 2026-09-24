mod content;
mod credentials;
mod frames;
mod keys;
mod padding;
mod sync;

use serde::Serialize;
use serde_json::ser::PrettyFormatter;
use serde_json::{Serializer, Value, json};

const API_KEY: u8 = 0x00;
const BLINDED_ID: u8 = 0x10;
pub const CONTENT_KEY: u8 = 0x20;
const RECOVERY_KEY: u8 = 0x40;
const WRITE_ID: u8 = 0x60;
const DEVICE_A: u8 = 0x60;
const NONCE: u8 = 0x70;
const LOCAL_SALT: u8 = 0x80;
const RESPONSE_NONCE: u8 = 0x90;
const ARGON_OUT: u8 = 0xa0;
const DEVICE_B: u8 = 0xb0;
const MACHINE_ID: u8 = 0xc0;
const SHARED_SECRET: u8 = 0xd0;
const PAYLOAD: u8 = 0xd0;
const BLOB: u8 = 0xe0;
const UUID: &str = "0b8f1d2e-3a4b-4c5d-8e9f-001122334455";

pub fn seq_bytes(start: u8, len: usize) -> Vec<u8> {
	(0..len).map(|i| start.wrapping_add(i as u8)).collect()
}

pub fn seq_array<const N: usize>(start: u8) -> [u8; N] {
	std::array::from_fn(|i| start.wrapping_add(i as u8))
}

fn uuid_bytes() -> [u8; 16] {
	let hex: String = UUID.chars().filter(|c| *c != '-').collect();
	crate::hex::decode(&hex).unwrap().try_into().unwrap()
}

fn file(description: &str, cases: Vec<Value>) -> Value {
	json!({
		"$generated": "spec/generator — do not edit; run `cargo run --bin gen-vectors`",
		"description": description,
		"cases": cases,
	})
}

pub fn all() -> Vec<(&'static str, Value)> {
	vec![
		("hkdf.json", keys::hkdf()),
		("blinding.json", keys::blinding()),
		("content.json", content::content()),
		("note.json", content::note()),
		("frames.json", frames::frames()),
		("envelope.json", frames::envelope()),
		("padding.json", padding::padding()),
		("argon2.json", keys::argon2()),
		("mnemonic.json", credentials::mnemonic()),
		("pairing.json", credentials::pairing()),
		("sync.json", sync::scenario()),
	]
}

pub fn render(value: &Value) -> String {
	let mut out = Vec::new();
	let mut serializer = Serializer::with_formatter(&mut out, PrettyFormatter::with_indent(b"\t"));
	value
		.serialize(&mut serializer)
		.expect("vector values always serialize");
	out.push(b'\n');
	String::from_utf8(out).expect("serde_json emits UTF-8")
}
