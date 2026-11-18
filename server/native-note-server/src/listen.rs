use std::fmt;
use std::fs::{self, Permissions};
use std::io::{self, Read, Write};
use std::net::{AddrParseError, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Duration;

const SOCKET_MODE: u32 = 0o666;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Listen {
	Tcp(SocketAddr),
	Unix(PathBuf),
}

impl FromStr for Listen {
	type Err = AddrParseError;

	fn from_str(text: &str) -> Result<Listen, AddrParseError> {
		if text.starts_with('/') {
			return Ok(Listen::Unix(PathBuf::from(text)));
		}
		text.parse().map(Listen::Tcp)
	}
}

impl From<SocketAddr> for Listen {
	fn from(address: SocketAddr) -> Listen {
		Listen::Tcp(address)
	}
}

impl fmt::Display for Listen {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Listen::Tcp(address) => write!(f, "{address}"),
			Listen::Unix(path) => write!(f, "{path:?}"),
		}
	}
}

impl Listen {
	pub(crate) fn bind(&self) -> io::Result<(Listener, Listen)> {
		match self {
			Listen::Tcp(address) => {
				let listener = TcpListener::bind(address)?;
				let bound = listener.local_addr()?;
				Ok((Listener::Tcp(listener), Listen::Tcp(bound)))
			}
			Listen::Unix(path) => Ok((Listener::Unix(bind_unix(path)?), self.clone())),
		}
	}
}

fn bind_unix(path: &Path) -> io::Result<UnixListener> {
	let listener = match UnixListener::bind(path) {
		Err(error) if error.kind() == io::ErrorKind::AddrInUse && abandoned(path) => {
			fs::remove_file(path)?;
			UnixListener::bind(path)?
		}
		bound => bound?,
	};
	fs::set_permissions(path, Permissions::from_mode(SOCKET_MODE))?;
	Ok(listener)
}

fn abandoned(path: &Path) -> bool {
	fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
		&& UnixStream::connect(path)
			.is_err_and(|error| error.kind() == io::ErrorKind::ConnectionRefused)
}

pub(crate) enum Listener {
	Tcp(TcpListener),
	Unix(UnixListener),
}

impl Listener {
	pub(crate) fn accept(&self) -> io::Result<Stream> {
		match self {
			Listener::Tcp(listener) => listener.accept().map(|(stream, _)| Stream::Tcp(stream)),
			Listener::Unix(listener) => listener.accept().map(|(stream, _)| Stream::Unix(stream)),
		}
	}
}

pub(crate) enum Stream {
	Tcp(TcpStream),
	Unix(UnixStream),
}

impl Stream {
	pub(crate) fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
		match self {
			Stream::Tcp(stream) => stream.read(buffer),
			Stream::Unix(stream) => stream.read(buffer),
		}
	}

	pub(crate) fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
		match self {
			Stream::Tcp(stream) => stream.write(bytes),
			Stream::Unix(stream) => stream.write(bytes),
		}
	}

	pub(crate) fn set_read_timeout(&self, timeout: Duration) -> io::Result<()> {
		match self {
			Stream::Tcp(stream) => stream.set_read_timeout(Some(timeout)),
			Stream::Unix(stream) => stream.set_read_timeout(Some(timeout)),
		}
	}

	pub(crate) fn set_write_timeout(&self, timeout: Duration) -> io::Result<()> {
		match self {
			Stream::Tcp(stream) => stream.set_write_timeout(Some(timeout)),
			Stream::Unix(stream) => stream.set_write_timeout(Some(timeout)),
		}
	}

	pub(crate) fn shutdown_write(&self) -> io::Result<()> {
		match self {
			Stream::Tcp(stream) => stream.shutdown(Shutdown::Write),
			Stream::Unix(stream) => stream.shutdown(Shutdown::Write),
		}
	}

	pub(crate) fn send_without_delay(&self) -> io::Result<()> {
		match self {
			Stream::Tcp(stream) => stream.set_nodelay(true),
			Stream::Unix(_) => Ok(()),
		}
	}
}
