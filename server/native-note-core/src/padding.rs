pub(crate) const BODY_MAX: usize = 2_097_152;
const PADDED_MIN: usize = 256;
pub(crate) const LEN_PREFIX: usize = 4;

fn bucket(len: usize) -> Option<usize> {
	len.max(PADDED_MIN)
		.checked_next_power_of_two()
		.filter(|&size| size <= BODY_MAX)
}

pub(crate) fn pad(inner: &[u8]) -> Option<Vec<u8>> {
	let size = bucket(inner.len().saturating_add(LEN_PREFIX))?;
	let len = u32::try_from(inner.len()).unwrap_or(u32::MAX);
	let mut padded = len.to_be_bytes().to_vec();
	padded.extend_from_slice(inner);
	padded.resize(size, 0);
	Some(padded)
}

pub(crate) fn unpad(padded: &[u8]) -> Option<&[u8]> {
	let (len, rest) = padded.split_first_chunk::<LEN_PREFIX>()?;
	let len = usize::try_from(u32::from_be_bytes(*len)).unwrap_or(usize::MAX);
	let (inner, fill) = rest.split_at_checked(len)?;
	let canonical = bucket(len.saturating_add(LEN_PREFIX)) == Some(padded.len())
		&& fill.iter().all(|&byte| byte == 0);
	canonical.then_some(inner)
}

#[cfg(test)]
mod tests;
