use native_note_server::{Runtime, run};
use std::env;
use std::process::ExitCode;

fn main() -> ExitCode {
	run(env::args_os().skip(1), Runtime::server())
}
