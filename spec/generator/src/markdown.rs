use crate::hex;

const MS_PER_DAY: i64 = 86_400_000;
const DAYS_PER_ERA: i64 = 146_097;
const DAYS_FROM_ERA_START_TO_EPOCH: i64 = 719_468;

pub fn uuid_text(uuid: &[u8; 16]) -> String {
	let mut text = hex::encode(uuid);
	for at in [20, 16, 12, 8] {
		text.insert(at, '-');
	}
	text
}

fn civil_date(days: i64) -> (i64, i64, i64) {
	let shifted = days + DAYS_FROM_ERA_START_TO_EPOCH;
	let era = shifted.div_euclid(DAYS_PER_ERA);
	let day_of_era = shifted.rem_euclid(DAYS_PER_ERA);
	let year_of_era =
		(day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
	let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
	let march_month = (5 * day_of_year + 2) / 153;
	let day = day_of_year - (153 * march_month + 2) / 5 + 1;
	let month = if march_month < 10 {
		march_month + 3
	} else {
		march_month - 9
	};
	(year_of_era + era * 400 + i64::from(month <= 2), month, day)
}

pub fn timestamp(ms: i64) -> String {
	let (year, month, day) = civil_date(ms.div_euclid(MS_PER_DAY));
	let time = ms.rem_euclid(MS_PER_DAY);
	let year = if (0..=9999).contains(&year) {
		format!("{year:04}")
	} else {
		format!("{year:+07}")
	};
	format!(
		"{year}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
		time / 3_600_000,
		time / 60_000 % 60,
		time / 1000 % 60,
		time % 1000
	)
}

pub fn render(uuid: &[u8; 16], created_at: i64, updated_at: i64, v: u32, body: &str) -> String {
	format!(
		"---\nid: {}\ncreated: {}\nupdated: {}\nv: {v}\n---\n{body}",
		uuid_text(uuid),
		timestamp(created_at),
		timestamp(updated_at)
	)
}
