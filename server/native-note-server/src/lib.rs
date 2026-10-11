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

mod key;
mod log;
mod serve;
mod store;

pub use log::{Cause, Event, Failure, Log, Stage, Stderr};
pub use serve::{Runtime, Server, Timing};
pub use store::Store;

use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

const USAGE_EXIT: u8 = 2;

pub fn run(args: impl IntoIterator<Item = OsString>, runtime: Runtime) -> ExitCode {
	let log = Arc::clone(&runtime.log);
	let Some((address, data)) = arguments(args) else {
		log.record(Event::Usage);
		return ExitCode::from(USAGE_EXIT);
	};
	let server = match Server::open(address, &data, runtime) {
		Ok(server) => server,
		Err((stage, cause)) => {
			log.record(Event::StartupFailed { stage, cause });
			return ExitCode::FAILURE;
		}
	};
	log.record(Event::Listening {
		address: server.address(),
	});
	let cause = server.serve();
	log.record(Event::StartupFailed {
		stage: Stage::Workers,
		cause,
	});
	ExitCode::FAILURE
}

fn arguments(args: impl IntoIterator<Item = OsString>) -> Option<(SocketAddr, PathBuf)> {
	let mut args = args.into_iter();
	let (Some(address), Some(data), None) = (args.next(), args.next(), args.next()) else {
		return None;
	};
	let address = address.to_str()?.parse().ok()?;
	Some((address, PathBuf::from(data)))
}
