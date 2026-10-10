const LOCAL_HEADER: u32 = 0x0403_4b50;
const CENTRAL_HEADER: u32 = 0x0201_4b50;
const END_OF_DIRECTORY: u32 = 0x0605_4b50;
const VERSION: u16 = 20;
const UTF8_NAMES: u16 = 0x0800;
const STORED: u16 = 0;
const MIDNIGHT: u16 = 0;
const JANUARY_1_1980: u16 = 0x0021;

pub fn crc32(data: &[u8]) -> u32 {
	!data.iter().fold(!0, |crc, &byte| {
		(0..8).fold(crc ^ u32::from(byte), |crc, _| {
			if crc & 1 == 1 {
				0xedb8_8320 ^ (crc >> 1)
			} else {
				crc >> 1
			}
		})
	})
}

fn shared_fields(name: &str, data: &[u8]) -> Vec<u8> {
	let size = u32::try_from(data.len()).expect("entries stay under 4 GiB");
	let name_len = u16::try_from(name.len()).expect("names stay under 64 KiB");
	[
		VERSION.to_le_bytes().as_slice(),
		&UTF8_NAMES.to_le_bytes(),
		&STORED.to_le_bytes(),
		&MIDNIGHT.to_le_bytes(),
		&JANUARY_1_1980.to_le_bytes(),
		&crc32(data).to_le_bytes(),
		&size.to_le_bytes(),
		&size.to_le_bytes(),
		&name_len.to_le_bytes(),
		&0u16.to_le_bytes(),
	]
	.concat()
}

pub fn stored(entries: &[(&str, &[u8])]) -> Vec<u8> {
	let mut archive = Vec::new();
	let mut directory = Vec::new();
	for (name, data) in entries {
		let offset = u32::try_from(archive.len()).expect("archives stay under 4 GiB");
		let fields = shared_fields(name, data);
		archive.extend_from_slice(&LOCAL_HEADER.to_le_bytes());
		archive.extend_from_slice(&fields);
		archive.extend_from_slice(name.as_bytes());
		archive.extend_from_slice(data);

		directory.extend_from_slice(&CENTRAL_HEADER.to_le_bytes());
		directory.extend_from_slice(&VERSION.to_le_bytes());
		directory.extend_from_slice(&fields);
		directory.extend_from_slice(&[0; 10]);
		directory.extend_from_slice(&offset.to_le_bytes());
		directory.extend_from_slice(name.as_bytes());
	}

	let count = u16::try_from(entries.len()).expect("fewer than 65,535 entries");
	let directory_offset = u32::try_from(archive.len()).expect("archives stay under 4 GiB");
	let directory_size = u32::try_from(directory.len()).expect("archives stay under 4 GiB");
	archive.extend_from_slice(&directory);
	archive.extend_from_slice(&END_OF_DIRECTORY.to_le_bytes());
	archive.extend_from_slice(&[0; 4]);
	archive.extend_from_slice(&count.to_le_bytes());
	archive.extend_from_slice(&count.to_le_bytes());
	archive.extend_from_slice(&directory_size.to_le_bytes());
	archive.extend_from_slice(&directory_offset.to_le_bytes());
	archive.extend_from_slice(&0u16.to_le_bytes());
	archive
}
