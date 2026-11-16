use crate::durable;
use crate::log::{Cause, Event, Log};
use crate::serve::Fill;
use native_note_core::Secret;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::Path;

const FILE: &str = "api-key";

pub fn load_or_create(data: &Path, fill: Fill, log: &dyn Log) -> Result<Secret<[u8; 32]>, Cause> {
	let path = data.join(FILE);
	match fs::read(&path) {
		Ok(text) => parse(&text).map(Secret::new).ok_or(Cause::Malformed),
		Err(error) if error.kind() == io::ErrorKind::NotFound => {
			let key = create(data, fill)?;
			log.record(Event::KeyCreated { path: &path });
			Ok(key)
		}
		Err(error) => Err(error.into()),
	}
}

fn create(data: &Path, fill: Fill) -> Result<Secret<[u8; 32]>, Cause> {
	let mut key = [0; 32];
	fill(&mut key).map_err(|_| Cause::Random)?;
	let text = key.iter().fold(String::new(), |mut text, byte| {
		write!(text, "{byte:02x}").unwrap_or(());
		text
	});
	durable::replace(data, FILE, format!("{text}\n").as_bytes())?;
	Ok(Secret::new(key))
}

fn parse(text: &[u8]) -> Option<[u8; 32]> {
	let text = text.trim_ascii();
	if text.len() != 64 {
		return None;
	}
	let mut key = [0; 32];
	for (byte, [high, low]) in key.iter_mut().zip(text.as_chunks::<2>().0) {
		*byte = nibble(*high)?.wrapping_shl(4) | nibble(*low)?;
	}
	Some(key)
}

fn nibble(digit: u8) -> Option<u8> {
	match digit {
		b'0'..=b'9' => Some(digit.wrapping_sub(b'0')),
		b'a'..=b'f' => Some(digit.wrapping_sub(b'a').wrapping_add(10)),
		_ => None,
	}
}
