use std::fs;
use std::path::Path;

use native_note_vectors::vectors;

fn main() {
	let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../vectors");
	fs::create_dir_all(&dir).expect("vectors directory is writable");

	for (name, value) in vectors::all() {
		let path = dir.join(name);
		fs::write(&path, vectors::render(&value)).expect("vector file is writable");
		println!("wrote {}", path.display());
	}
}
