use crate::NOTE_MAX;
use native_note_core::{BlindedNoteId, Record, Version};
use std::sync::OnceLock;

const SEED: u64 = 0x6e61_7469_7665_6e6f;
const NOTES: usize = 2_000;
const EMPTY_AT: usize = 11;
const NOTE_MAX_AT: usize = 1_000;
const OVER_NOTE_MAX_AT: usize = 1_989;

pub struct SplitMix64(u64);

impl SplitMix64 {
	pub fn new(seed: u64) -> Self {
		Self(seed)
	}

	pub fn next_u64(&mut self) -> u64 {
		self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
		let mut z = self.0;
		z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
		z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
		z ^ (z >> 31)
	}

	pub fn between(&mut self, low: usize, high: usize) -> usize {
		let span = u64::try_from(high - low + 1).expect("a span fits u64");
		low + usize::try_from(self.next_u64() % span).expect("below the span")
	}

	pub fn array<const N: usize>(&mut self) -> [u8; N] {
		let mut out = [0; N];
		self.fill(&mut out);
		out
	}

	fn fill(&mut self, out: &mut [u8]) {
		for chunk in out.chunks_mut(8) {
			let word = self.next_u64().to_le_bytes();
			chunk.copy_from_slice(&word[..chunk.len()]);
		}
	}
}

/// A write whose `writeId` is the id repeated with `v` in its last four bytes.
pub fn write(id: u8, v: u32, len: usize) -> Record {
	let mut write_id = [id; 16];
	write_id[12..].copy_from_slice(&v.to_be_bytes());
	Record {
		id: BlindedNoteId([id; 16]),
		v: Version(v),
		write_id,
		payload: payload(len, u64::from(id) << 32 | u64::from(v)),
	}
}

pub fn payload(len: usize, seed: u64) -> Vec<u8> {
	let mut out = vec![0; len];
	SplitMix64::new(seed).fill(&mut out);
	out
}

pub fn corpus() -> &'static [Record] {
	static CORPUS: OnceLock<Vec<Record>> = OnceLock::new();
	CORPUS.get_or_init(|| {
		let mut rng = SplitMix64::new(SEED);
		(0..NOTES)
			.map(|index| {
				let len = match index {
					EMPTY_AT => 0,
					NOTE_MAX_AT => NOTE_MAX,
					OVER_NOTE_MAX_AT => NOTE_MAX + 1,
					_ => payload_len(&mut rng),
				};
				Record {
					id: BlindedNoteId(rng.array()),
					v: Version(1),
					write_id: rng.array(),
					payload: payload(len, rng.next_u64()),
				}
			})
			.collect()
	})
}

fn payload_len(rng: &mut SplitMix64) -> usize {
	match rng.between(0, 99) {
		0..70 => rng.between(64, 4 << 10),
		70..95 => rng.between((4 << 10) + 1, 64 << 10),
		95..99 => rng.between((64 << 10) + 1, 512 << 10),
		_ => rng.between((512 << 10) + 1, NOTE_MAX),
	}
}
