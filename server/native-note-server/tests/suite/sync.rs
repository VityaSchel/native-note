use crate::support::{Client, runtime, serve_at, start};
use native_note_testkit::corpus::SplitMix64;
use native_note_testkit::scenario::{shuffled, three_devices};
use native_note_testkit::session::{Device, Exchange, Replays, Session};

#[test]
fn three_devices_sync_two_thousand_notes_over_http_and_replaying_every_request_changes_nothing() {
	let running = start("sync");
	let mut session = Session::new(running.client(1));
	three_devices(&mut session);

	let mut rng = SplitMix64::new(0x7265_706c_6179);
	let mut replays = Replays::default();
	let count = session.captured.len();
	for index in (0..count).chain(shuffled(count, &mut rng)) {
		let body = session.captured[index].body.clone();
		let inner = session.server.post(&body);
		session.check_replay(index, &inner, &mut replays);
	}
	assert_eq!(
		replays,
		Replays {
			conflicts: 2 * 2_301,
			too_large: 2,
			gets: 2 * 4,
			puts: 2 * 4,
		}
	);

	let reopened = serve_at(running.data.path(), runtime(&running.log));
	let mut fresh = Session {
		server: Client::new(reopened, running.key, 2),
		model: session.model,
		captured: Vec::new(),
	};
	let mut device = Device::default();
	fresh.sync(&mut device, &[]);
	assert_eq!(device.view(), &fresh.model.view());
	assert_eq!(device.since(), fresh.model.latest());
	assert_eq!(running.log.lines(), Vec::<String>::new());
}
