use std::fmt;

pub struct Secret<T>(T);

impl<T> Secret<T> {
	pub fn new(value: T) -> Self {
		Self(value)
	}

	pub fn expose(&self) -> &T {
		&self.0
	}
}

impl<T> fmt::Debug for Secret<T> {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("[redacted]")
	}
}

#[cfg(test)]
mod tests;
