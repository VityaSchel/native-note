use crate::types::{Record, Version};

pub(crate) const NOTE_MAX: usize = 1_048_576;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Status {
	Accepted,
	Conflict,
	TooLarge,
}

impl Version {
	fn follows(self, stored: Version) -> bool {
		stored.0.checked_add(1) == Some(self.0)
	}
}

pub(crate) fn write_status(stored: Version, write: &Record) -> Status {
	if write.payload.len() > NOTE_MAX {
		Status::TooLarge
	} else if write.v.follows(stored) {
		Status::Accepted
	} else {
		Status::Conflict
	}
}

pub(crate) fn put_status(stored: Version, v: Version) -> Status {
	if v.follows(stored) {
		Status::Accepted
	} else {
		Status::Conflict
	}
}

#[cfg(test)]
mod tests;
