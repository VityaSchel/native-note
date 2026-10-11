use crate::frame::DecodeError;

pub(crate) struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
	pub(crate) fn new(input: &'a [u8]) -> Self {
		Self(input)
	}

	pub(crate) fn array<const N: usize>(&mut self) -> Result<[u8; N], DecodeError> {
		let (head, rest) = self
			.0
			.split_first_chunk::<N>()
			.ok_or(DecodeError::Truncated)?;
		self.0 = rest;
		Ok(*head)
	}

	pub(crate) fn u8(&mut self) -> Result<u8, DecodeError> {
		self.array().map(u8::from_be_bytes)
	}

	pub(crate) fn u32(&mut self) -> Result<u32, DecodeError> {
		self.array().map(u32::from_be_bytes)
	}

	pub(crate) fn u64(&mut self) -> Result<u64, DecodeError> {
		self.array().map(u64::from_be_bytes)
	}

	pub(crate) fn bytes(&mut self) -> Result<&'a [u8], DecodeError> {
		let len = usize::try_from(self.u32()?).unwrap_or(usize::MAX);
		let (head, rest) = self.0.split_at_checked(len).ok_or(DecodeError::Truncated)?;
		self.0 = rest;
		Ok(head)
	}

	pub(crate) fn finish(self) -> Result<(), DecodeError> {
		if self.0.is_empty() {
			Ok(())
		} else {
			Err(DecodeError::TrailingBytes)
		}
	}
}

pub(crate) struct Writer(Vec<u8>);

impl Writer {
	pub(crate) fn new() -> Self {
		Self(Vec::new())
	}

	pub(crate) fn raw(&mut self, bytes: &[u8]) -> &mut Self {
		self.0.extend_from_slice(bytes);
		self
	}

	pub(crate) fn u8(&mut self, value: u8) -> &mut Self {
		self.raw(&[value])
	}

	pub(crate) fn u32(&mut self, value: u32) -> &mut Self {
		self.raw(&value.to_be_bytes())
	}

	pub(crate) fn u64(&mut self, value: u64) -> &mut Self {
		self.raw(&value.to_be_bytes())
	}

	pub(crate) fn count(&mut self, count: usize) -> &mut Self {
		self.u32(u32::try_from(count).unwrap_or(u32::MAX))
	}

	pub(crate) fn bytes(&mut self, bytes: &[u8]) -> &mut Self {
		self.count(bytes.len()).raw(bytes)
	}

	pub(crate) fn into_bytes(self) -> Vec<u8> {
		self.0
	}
}

#[cfg(test)]
mod tests;
