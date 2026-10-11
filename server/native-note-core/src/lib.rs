#![forbid(unsafe_code)]
#![cfg_attr(
	not(test),
	forbid(
		clippy::arithmetic_side_effects,
		clippy::as_conversions,
		clippy::disallowed_macros,
		clippy::disallowed_methods,
		clippy::exit,
		clippy::expect_used,
		clippy::indexing_slicing,
		clippy::let_underscore_must_use,
		clippy::panic,
		clippy::panic_in_result_fn,
		clippy::print_stderr,
		clippy::print_stdout,
		clippy::dbg_macro,
		clippy::todo,
		clippy::unimplemented,
		clippy::unreachable,
		clippy::unwrap_in_result,
		clippy::unwrap_used,
	)
)]

mod codec;
mod envelope;
mod frame;
pub mod http;
mod padding;
mod process;
mod reply;
mod secret;
mod storage;
mod types;
mod version;

#[cfg(test)]
mod tests;

pub use envelope::{Envelope, EnvelopeKey, Opened, Rejection, admit};
pub use frame::{DecodeError, Request};
pub use process::process;
pub use reply::{Fault, Reply};
pub use secret::Secret;
pub use storage::Storage;
pub use types::{BlindedNoteId, Record, Seq, Version};
