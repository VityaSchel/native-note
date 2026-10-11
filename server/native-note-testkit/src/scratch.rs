use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A directory of its own under the system temporary directory, removed on drop.
pub struct Scratch(PathBuf);

impl Scratch {
	pub fn new(name: &str) -> Scratch {
		static NEXT: AtomicUsize = AtomicUsize::new(0);
		let path = env::temp_dir().join("native-note-tests").join(format!(
			"{name}-{}-{}",
			process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		fs::remove_dir_all(&path).ok();
		fs::create_dir_all(&path).expect("creates a scratch directory");
		Scratch(path)
	}

	pub fn path(&self) -> &Path {
		&self.0
	}

	pub fn join(&self, name: &str) -> PathBuf {
		self.0.join(name)
	}
}

pub fn mode(path: &Path) -> u32 {
	fs::metadata(path).expect("exists").permissions().mode() & 0o777
}

impl Drop for Scratch {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).ok();
	}
}
