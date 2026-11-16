use crate::durable;
use crate::log::Cause;
use native_note_core::Seq;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const FILE: &str = "seq";
const GAP_AFTER_LOSS: u64 = 1 << 40;

pub struct SeqFile {
	directory: PathBuf,
	highest: Option<Seq>,
}

impl SeqFile {
	pub fn load(data: &Path) -> Result<SeqFile, Cause> {
		let highest = match fs::read(data.join(FILE)) {
			Ok(text) => Some(parse(&text).ok_or(Cause::Malformed)?),
			Err(error) if error.kind() == io::ErrorKind::NotFound => None,
			Err(error) => return Err(error.into()),
		};
		Ok(SeqFile {
			directory: data.to_path_buf(),
			highest,
		})
	}

	pub fn highest(&self) -> Seq {
		self.highest.unwrap_or(Seq(0))
	}

	pub fn resume_beside(&mut self, stored: Seq) {
		self.highest
			.get_or_insert(Seq(stored.0.saturating_add(GAP_AFTER_LOSS)));
	}

	pub fn record(&mut self, seq: Seq) -> io::Result<()> {
		durable::replace(&self.directory, FILE, format!("{}\n", seq.0).as_bytes())?;
		self.highest = Some(seq);
		Ok(())
	}
}

fn parse(text: &[u8]) -> Option<Seq> {
	text.strip_suffix(b"\n")
		.filter(|digits| !digits.is_empty())?
		.iter()
		.try_fold(0_u64, |value, &digit| {
			let digit = digit
				.is_ascii_digit()
				.then(|| u64::from(digit.wrapping_sub(b'0')))?;
			value.checked_mul(10)?.checked_add(digit)
		})
		.map(Seq)
}
