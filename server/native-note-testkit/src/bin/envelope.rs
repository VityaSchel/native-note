use native_note_testkit::client;
use ring::rand::{SecureRandom, SystemRandom};
use std::io::{self, Read, Write};
use std::path::Path;
use std::{env, fs};

const USAGE: &str = "development only: envelope seal <api-key file> < inner > body
                  envelope open <api-key file> <body file> < reply > inner";

fn envelope_key(path: &str) -> [u8; 32] {
	client::envelope_key(&client::read_api_key(Path::new(path)))
}

fn main() {
	let args: Vec<String> = env::args().skip(1).collect();
	let mut input = Vec::new();
	io::stdin().read_to_end(&mut input).expect("reads stdin");
	let output = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
		["seal", key] => {
			let mut nonce = [0; 12];
			SystemRandom::new().fill(&mut nonce).expect("draws a nonce");
			client::seal_request(&envelope_key(key), nonce, &input)
		}
		["open", key, body] => {
			let body = fs::read(body).expect("reads the request body");
			let nonce = body.first_chunk().expect("a sealed body");
			client::open_response(&envelope_key(key), nonce, &input).expect("the reply opens")
		}
		_ => {
			eprintln!("{USAGE}");
			std::process::exit(2);
		}
	};
	io::stdout().write_all(&output).expect("writes stdout");
}
