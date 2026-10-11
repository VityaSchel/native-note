use super::Secret;

const API_KEY: [u8; 32] = [
	0x3f, 0x91, 0x0c, 0xe7, 0x52, 0xb8, 0x14, 0x6d, 0xa9, 0x27, 0xf0, 0x83, 0x5e, 0xc1, 0x38, 0x9b,
	0x07, 0x64, 0xdd, 0x1a, 0x8f, 0x46, 0xb3, 0x29, 0x70, 0xce, 0x95, 0x02, 0x6b, 0xe4, 0x11, 0xfa,
];

#[derive(Debug)]
struct ServerKeys {
	data_directory: &'static str,
	api_key: Secret<[u8; 32]>,
}

struct Opaque;

#[test]
fn debug_prints_redacted_in_every_form() {
	let key = Secret::new(API_KEY);
	assert_eq!(format!("{key:?}"), "[redacted]");
	assert_eq!(format!("{key:#?}"), "[redacted]");
	assert_eq!(format!("{key:x?}"), "[redacted]");
	assert_eq!(format!("{key:#X?}"), "[redacted]");
	assert_eq!(format!("{:?}", Secret::new(Opaque)), "[redacted]");
}

#[test]
fn a_derived_debug_shows_no_key_byte_yet_the_key_is_held() {
	let keys = ServerKeys {
		data_directory: "/var/lib/native-note-server",
		api_key: Secret::new(API_KEY),
	};
	let compact =
		"ServerKeys { data_directory: \"/var/lib/native-note-server\", api_key: [redacted] }";
	assert_eq!(format!("{keys:?}"), compact);
	assert_eq!(format!("{keys:x?}"), compact);
	assert_eq!(
		format!("{keys:#X?}"),
		"ServerKeys {\n    data_directory: \"/var/lib/native-note-server\",\n    api_key: [redacted],\n}"
	);
	for output in [format!("{keys:?}"), format!("{keys:#x?}")] {
		assert!(!output.bytes().any(|b| b.is_ascii_digit()), "{output}");
		for byte in API_KEY {
			assert!(!output.contains(&format!("{byte:02x}")), "{output}");
		}
	}
	let ServerKeys {
		data_directory,
		api_key,
	} = keys;
	assert_eq!(data_directory, "/var/lib/native-note-server");
	assert_eq!(api_key.expose(), &API_KEY);
}
