use super::{State, state, sync, write};
use crate::store::Store;
use native_note_core::{Request, Version};
use native_note_testkit::corpus::SplitMix64;
use native_note_testkit::scratch::Scratch;
use std::fs;
use std::path::Path;

const DATABASE: &str = "native-note.sqlite";
const WAL: &str = "native-note.sqlite-wal";
const PAGE: usize = 4096;
const FRAME: usize = 24 + PAGE;
const WAL_HEADER: usize = 32;
const FRAMES_TRIED: usize = 16;
const MIXES_TRIED: usize = 8;

#[derive(Clone)]
struct Files {
	database: Vec<u8>,
	wal: Vec<u8>,
}

impl Files {
	fn read(directory: &Path) -> Files {
		Files {
			database: fs::read(directory.join(DATABASE)).expect("reads the database"),
			wal: fs::read(directory.join(WAL)).unwrap_or_default(),
		}
	}

	fn boot(&self, directory: &Path) -> State {
		for file in [DATABASE, WAL, "native-note.sqlite-shm"] {
			fs::remove_file(directory.join(file)).ok();
		}
		fs::write(directory.join(DATABASE), &self.database).expect("writes the database");
		if !self.wal.is_empty() {
			fs::write(directory.join(WAL), &self.wal).expect("writes the log");
		}
		let store = Store::open(&directory.join(DATABASE)).expect("boots after the cut");
		state(&store.0)
	}
}

/// `new` written up to `cut` over `old`, or over zeros when the file grew before its bytes landed.
fn torn(old: &[u8], new: &[u8], cut: usize, zero_tail: bool) -> Vec<u8> {
	let mut bytes = new[..cut].to_vec();
	if zero_tail {
		bytes.resize(new.len(), 0);
	} else if old.len() > cut {
		bytes.extend_from_slice(&old[cut..]);
	}
	bytes
}

/// The bytes a request wrote to the log, through the end of the last frame it changed.
fn written(old: &[u8], new: &[u8]) -> Option<(usize, usize)> {
	let differs = |at: usize| old.get(at) != new.get(at);
	let first = (0..new.len()).find(|&at| differs(at))?;
	let last = (0..new.len()).rev().find(|&at| differs(at))?;
	let frames = (last + 1).saturating_sub(WAL_HEADER).div_ceil(FRAME);
	Some((first, (WAL_HEADER + frames * FRAME).min(new.len())))
}

fn cuts(first: usize, end: usize) -> Vec<usize> {
	let frame_of = |at: usize| at.saturating_sub(WAL_HEADER) / FRAME;
	let frames: Vec<usize> = (frame_of(first)..=frame_of(end - 1)).collect();
	let step = frames.len().div_ceil(FRAMES_TRIED).max(1);
	let mut cuts = vec![first, end - 1, end];
	for (index, frame) in frames.iter().enumerate() {
		if index % step == 0 || index + 2 >= frames.len() {
			let start = WAL_HEADER + frame * FRAME;
			cuts.extend([start, start + 24, start + 24 + 512]);
		}
	}
	cuts.retain(|&cut| (first..=end).contains(&cut));
	cuts.sort_unstable();
	cuts.dedup();
	cuts
}

fn mixed(old: &[u8], new: &[u8], rng: &mut SplitMix64, round: usize) -> Vec<u8> {
	let pages = new.len().div_ceil(PAGE);
	(0..pages)
		.flat_map(|page| {
			let range = page * PAGE..((page + 1) * PAGE).min(new.len());
			let landed = match round {
				0 => page % 2 == 0,
				1 => page % 2 == 1,
				_ => rng.next_u64().is_multiple_of(2),
			};
			if landed {
				new[range].to_vec()
			} else {
				old.get(range.clone())
					.map_or_else(|| vec![0; range.len()], <[u8]>::to_vec)
			}
		})
		.collect()
}

fn workload() -> Vec<Request> {
	let mut rng = SplitMix64::new(0x0063_7261_7368);
	let mut versions = [0_u32; 40];
	let mut since = 0;
	let mut requests = Vec::new();
	for round in 0..24 {
		let mut writes = Vec::new();
		for _ in 0..6 {
			let id = rng.between(0, versions.len() - 1);
			versions[id] += 1;
			writes.push(write(id as u8, versions[id], rng.between(200, 20_000)));
		}
		if round % 6 == 5 {
			versions[39] += 1;
			writes.push(write(39, versions[39], 300_000));
		}
		requests.push(sync(since, &writes));
		since += writes.len() as u64;
		if round % 8 == 3 {
			requests.push(Request::Put {
				v: Version(round / 8 + 1),
				blob: vec![round as u8; 60],
			});
		}
	}
	requests
}

#[test]
fn a_power_cut_at_any_write_of_a_request_boots_to_the_state_before_or_after_it() {
	let scratch = Scratch::new("crash");
	let images = Scratch::new("crash-images");
	let mut store = Store::open(&scratch.join(DATABASE)).expect("opens");
	store
		.0
		.pragma_update(None, "wal_autocheckpoint", 64)
		.expect("checkpoints often");
	let mut rng = SplitMix64::new(0x6375_7473);
	let mut before = (Files::read(scratch.path()), state(&store.0));
	let (mut torn_before, mut torn_after, mut mixes) = (0, 0, 0);
	for (index, request) in workload().iter().enumerate() {
		store.answer(request).expect("answers");
		let after = (Files::read(scratch.path()), state(&store.0));
		assert_ne!(after.1, before.1, "request {index} changed nothing");

		let (old, new) = (&before.0, &after.0);
		let (first, end) = written(&old.wal, &new.wal).expect("the request wrote to the log");
		for cut in cuts(first, end) {
			for zero_tail in [false, true] {
				let image = Files {
					database: old.database.clone(),
					wal: torn(&old.wal, &new.wal, cut, zero_tail),
				};
				let committed = image.wal.get(..end) == new.wal.get(..end);
				let expected = if committed { &after.1 } else { &before.1 };
				assert!(
					image.boot(images.path()) == *expected,
					"request {index}, log cut at {cut} of {first}..{end}, zero tail {zero_tail}"
				);
				*if committed {
					&mut torn_after
				} else {
					&mut torn_before
				} += 1;
			}
		}
		if old.database != new.database {
			for round in 0..MIXES_TRIED {
				let image = Files {
					database: mixed(&old.database, &new.database, &mut rng, round),
					wal: new.wal.clone(),
				};
				assert!(
					image.boot(images.path()) == after.1,
					"request {index}, checkpoint mix {round}"
				);
				mixes += 1;
			}
		}
		before = after;
	}
	assert!(
		torn_before >= 1_000 && torn_after >= 50 && mixes >= 4 * MIXES_TRIED,
		"{torn_before} torn before, {torn_after} torn after, {mixes} checkpoint mixes"
	);
}
