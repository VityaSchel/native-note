pub const LEN: usize = 64;
const KEY_LEN: usize = LEN / 2;

pub fn encode(api_key: &[u8; KEY_LEN], recovery_key: &[u8; KEY_LEN]) -> [u8; LEN] {
	let mut blob = [0; LEN];
	blob[..KEY_LEN].copy_from_slice(api_key);
	blob[KEY_LEN..].copy_from_slice(recovery_key);
	blob
}

pub fn split(blob: &[u8]) -> Option<(&[u8; KEY_LEN], &[u8; KEY_LEN])> {
	match blob.as_chunks::<KEY_LEN>() {
		([api_key, recovery_key], []) => Some((api_key, recovery_key)),
		_ => None,
	}
}
