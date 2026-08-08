mod content;
mod credentials;
mod frames;
mod keys;
mod padding;
mod sync;

use serde_json::{json, Value};

pub const API_KEY: u8 = 0x00;
pub const CONTENT_KEY: u8 = 0x20;
pub const RECOVERY_KEY: u8 = 0x40;
pub const WRITE_ID: u8 = 0x60;
pub const NONCE: u8 = 0x70;
pub const LOCAL_SALT: u8 = 0x80;
pub const RESPONSE_NONCE: u8 = 0x90;
pub const UUID: &str = "0b8f1d2e-3a4b-4c5d-8e9f-001122334455";

pub fn uuid_bytes() -> [u8; 16] {
	let hex: String = UUID.chars().filter(|c| *c != '-').collect();
	crate::hex::decode(&hex).unwrap().try_into().unwrap()
}

pub fn file(description: &str, cases: Vec<Value>) -> Value {
	json!({ "description": description, "cases": cases })
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
		("scalar.json", keys::scalar()),
		("argon2.json", keys::argon2()),
		("mnemonic.json", credentials::mnemonic()),
		("pairing.json", credentials::pairing()),
		("sync.json", sync::scenario()),
	]
}

pub fn render(value: &Value) -> String {
	let mut s = serde_json::to_string_pretty(value).expect("vector values always serialize");
	s.push('\n');
	s
}
