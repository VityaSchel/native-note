use sha2::{Digest, Sha256};

const WORDLIST: &str = include_str!("../../wordlists/english.txt");

pub const WORDLIST_SHA256: &str =
	"2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda";

pub const ENTROPY_LEN: usize = 32;
pub const WORD_COUNT: usize = 24;
const BITS_PER_WORD: usize = 11;

#[derive(Debug, PartialEq, Eq)]
pub enum MnemonicError {
	WordCount,
	UnknownWord(usize),
	Checksum,
}

pub fn words() -> Vec<&'static str> {
	WORDLIST.lines().collect()
}

fn checksum(entropy: &[u8; ENTROPY_LEN]) -> u8 {
	Sha256::digest(entropy)[0]
}

pub fn encode(entropy: &[u8; ENTROPY_LEN]) -> Vec<&'static str> {
	let list = words();
	let mut buf = entropy.to_vec();
	buf.push(checksum(entropy));

	(0..WORD_COUNT)
		.map(|i| {
			let bit = i * BITS_PER_WORD;
			let mut index = 0usize;
			for offset in 0..BITS_PER_WORD {
				let b = bit + offset;
				let set = buf[b / 8] >> (7 - b % 8) & 1;
				index = index << 1 | set as usize;
			}
			list[index]
		})
		.collect()
}

pub fn decode(mnemonic: &[&str]) -> Result<[u8; ENTROPY_LEN], MnemonicError> {
	if mnemonic.len() != WORD_COUNT {
		return Err(MnemonicError::WordCount);
	}
	let list = words();

	let mut buf = [0u8; ENTROPY_LEN + 1];
	for (i, word) in mnemonic.iter().enumerate() {
		let index = list
			.iter()
			.position(|w| w == word)
			.ok_or(MnemonicError::UnknownWord(i))?;
		for offset in 0..BITS_PER_WORD {
			if index >> (BITS_PER_WORD - 1 - offset) & 1 == 1 {
				let b = i * BITS_PER_WORD + offset;
				buf[b / 8] |= 1 << (7 - b % 8);
			}
		}
	}

	let entropy: [u8; ENTROPY_LEN] = buf[..ENTROPY_LEN].try_into().unwrap();
	if buf[ENTROPY_LEN] != checksum(&entropy) {
		return Err(MnemonicError::Checksum);
	}
	Ok(entropy)
}
