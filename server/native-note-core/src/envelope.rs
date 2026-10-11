use crate::frame::{DecodeError, Request};
use crate::padding::{BODY_MAX, unpad};
use crate::reply::Reply;
use crate::secret::Secret;
use ring::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, Salt};

const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const SEALED_MIN: usize = NONCE_LEN + TAG_LEN;
const SEALED_MAX: usize = BODY_MAX + SEALED_MIN;
const ENVELOPE_INFO: &[u8] = b"native-note/envelope/v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
	TooLarge,
	Unopenable,
}

pub fn admit(len: usize) -> Result<(), Rejection> {
	if len > SEALED_MAX {
		Err(Rejection::TooLarge)
	} else if len < SEALED_MIN {
		Err(Rejection::Unopenable)
	} else {
		Ok(())
	}
}

pub struct Envelope {
	nonce: [u8; NONCE_LEN],
	bytes: Vec<u8>,
}

impl Envelope {
	pub fn parse(bytes: Vec<u8>) -> Result<Envelope, Rejection> {
		admit(bytes.len())?;
		let nonce = bytes
			.first_chunk::<NONCE_LEN>()
			.copied()
			.unwrap_or_default();
		Ok(Envelope { nonce, bytes })
	}
}

#[derive(Debug)]
pub struct EnvelopeKey(Secret<LessSafeKey>);

impl EnvelopeKey {
	pub fn derive(api_key: &Secret<[u8; 32]>) -> Option<EnvelopeKey> {
		Salt::new(HKDF_SHA256, &[0; 32])
			.extract(api_key.expose())
			.expand(&[ENVELOPE_INFO], &AES_256_GCM)
			.ok()
			.map(UnboundKey::from)
			.map(LessSafeKey::new)
			.map(Secret::new)
			.map(EnvelopeKey)
	}

	pub fn open(&self, envelope: Envelope) -> Result<Opened, Rejection> {
		let Envelope { nonce, mut bytes } = envelope;
		let len = self
			.0
			.expose()
			.open_within(
				Nonce::assume_unique_for_key(nonce),
				Aad::empty(),
				&mut bytes,
				NONCE_LEN..,
			)
			.ok()
			.ok_or(Rejection::Unopenable)?
			.len();
		bytes.truncate(len);
		Ok(Opened {
			nonce,
			padded: bytes,
		})
	}

	pub fn seal(
		&self,
		reply: Reply,
		request_nonce: &[u8; NONCE_LEN],
		response_nonce: [u8; NONCE_LEN],
	) -> Option<Vec<u8>> {
		if response_nonce == *request_nonce {
			return None;
		}
		let mut sealed = reply.0;
		self.0
			.expose()
			.seal_in_place_append_tag(
				Nonce::assume_unique_for_key(response_nonce),
				Aad::from(request_nonce),
				&mut sealed,
			)
			.ok()
			.map(|()| [response_nonce.as_slice(), &sealed].concat())
	}
}

pub struct Opened {
	nonce: [u8; NONCE_LEN],
	padded: Vec<u8>,
}

impl Opened {
	pub fn nonce(&self) -> [u8; NONCE_LEN] {
		self.nonce
	}

	pub fn request(&self) -> Result<Request, DecodeError> {
		unpad(&self.padded)
			.ok_or(DecodeError::Padding)
			.and_then(Request::decode)
	}
}

#[cfg(test)]
mod tests;
