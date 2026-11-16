use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub fn replace(directory: &Path, name: &str, contents: &[u8]) -> io::Result<()> {
	let temporary = directory.join(format!("{name}.new"));
	fs::remove_file(&temporary).ok();
	let mut file = OpenOptions::new()
		.write(true)
		.create_new(true)
		.mode(0o600)
		.open(&temporary)?;
	file.write_all(contents)?;
	file.sync_all()?;
	fs::rename(&temporary, directory.join(name))?;
	File::open(directory)?.sync_all()
}
