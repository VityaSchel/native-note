#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
	Truncated,
	TrailingBytes,
	NotCanonical,
	UnknownDiscriminant,
}

pub struct Reader<'a> {
	input: &'a [u8],
	pos: usize,
}

impl<'a> Reader<'a> {
	pub fn new(input: &'a [u8]) -> Self {
		Self { input, pos: 0 }
	}

	pub fn remaining(&self) -> usize {
		self.input.len() - self.pos
	}

	pub fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
		let end = self.pos.checked_add(n).ok_or(DecodeError::Truncated)?;
		let slice = self
			.input
			.get(self.pos..end)
			.ok_or(DecodeError::Truncated)?;
		self.pos = end;
		Ok(slice)
	}

	pub fn array<const N: usize>(&mut self) -> Result<[u8; N], DecodeError> {
		Ok(self
			.take(N)?
			.try_into()
			.expect("take returns exactly N bytes"))
	}

	pub fn u8(&mut self) -> Result<u8, DecodeError> {
		Ok(self.array::<1>()?[0])
	}

	pub fn u32(&mut self) -> Result<u32, DecodeError> {
		Ok(u32::from_be_bytes(self.array()?))
	}

	pub fn u64(&mut self) -> Result<u64, DecodeError> {
		Ok(u64::from_be_bytes(self.array()?))
	}

	pub fn bool(&mut self) -> Result<bool, DecodeError> {
		match self.u8()? {
			0 => Ok(false),
			1 => Ok(true),
			_ => Err(DecodeError::NotCanonical),
		}
	}

	pub fn bytes(&mut self) -> Result<&'a [u8], DecodeError> {
		let len = self.u32()? as usize;
		self.take(len)
	}

	pub fn finish(self) -> Result<(), DecodeError> {
		if self.remaining() == 0 {
			Ok(())
		} else {
			Err(DecodeError::TrailingBytes)
		}
	}
}

#[derive(Default)]
pub struct Writer {
	out: Vec<u8>,
}

impl Writer {
	pub fn new() -> Self {
		Self::default()
	}

	pub fn u8(&mut self, v: u8) -> &mut Self {
		self.out.push(v);
		self
	}

	pub fn u32(&mut self, v: u32) -> &mut Self {
		self.out.extend_from_slice(&v.to_be_bytes());
		self
	}

	pub fn u64(&mut self, v: u64) -> &mut Self {
		self.out.extend_from_slice(&v.to_be_bytes());
		self
	}

	pub fn bool(&mut self, v: bool) -> &mut Self {
		self.u8(v as u8)
	}

	pub fn raw(&mut self, v: &[u8]) -> &mut Self {
		self.out.extend_from_slice(v);
		self
	}

	pub fn count(&mut self, n: usize) -> &mut Self {
		self.u32(u32::try_from(n).expect("callers enforce the size limits"))
	}

	pub fn bytes(&mut self, v: &[u8]) -> &mut Self {
		self.count(v.len()).raw(v)
	}

	pub fn into_bytes(self) -> Vec<u8> {
		self.out
	}
}
