use serde_json::{Value, json};

use super::content::{CREATED_AT, UPDATED_AT};
use super::{file, parse_uuid, uuid_bytes};
use crate::hex::encode as hx;
use crate::markdown;

fn case(name: &str, uuid: [u8; 16], created_at: i64, updated_at: i64, v: u32, body: &str) -> Value {
	json!({
		"name": name,
		"uuid": hx(&uuid),
		"createdAt": created_at,
		"updatedAt": updated_at,
		"v": v,
		"body": body,
		"markdown": markdown::render(&uuid, created_at, updated_at, v, body),
	})
}

pub fn markdown() -> Value {
	file(
		"One exported note file per case: front matter id, created, updated and v with LF line endings, then the body byte for byte. Rendering the fields gives markdown, and parsing markdown gives the fields.",
		vec![
			case(
				"note",
				uuid_bytes(),
				CREATED_AT,
				UPDATED_AT,
				3,
				"Groceries\nmilk\nbread",
			),
			case(
				"beforeEpoch",
				parse_uuid("00000000-0000-4000-8000-000000000000"),
				-1,
				0,
				1,
				"",
			),
			case(
				"yearsOutsideFourDigits",
				parse_uuid("ffffffff-ffff-4fff-bfff-ffffffffffff"),
				-62_167_219_200_001,
				253_402_300_800_000,
				u32::MAX,
				"Ünïcode — 日本語 🔐\n\n---\nv: 0\n",
			),
			case(
				"yearsBeyondSixDigits",
				parse_uuid("7c1e9a42-5b3d-4f60-9e8a-0d2c4b6f8a1e"),
				-31_619_119_219_200_000,
				31_494_816_403_199_000,
				2,
				"Far off",
			),
			case(
				"bodyWithCarriageReturns",
				uuid_bytes(),
				CREATED_AT,
				UPDATED_AT,
				1,
				"Pasted\r\nfrom elsewhere\r\n\rend",
			),
		],
	)
}
