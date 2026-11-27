import { sleep } from "bun"
import { TalkBack } from "./talkback"

const APP = "dev.hloth.nativenote.debug"
const PASSWORD = "correct horse"
const PATIENCE_MILLIS = 15_000
const [serial, server, apiKey] = process.argv.slice(2)
if (!serial || !server || !apiKey) throw new Error("usage: run.ts <emulator serial> <server address> <api key>")

const NEVER = [/Radio button/, /Secondary pane|Primary pane/, /Invalid input/, /Password, Password/, /Search, Search/]
const talkBack = new TalkBack(serial)
const results: { name: string; heard: string[]; ok: boolean }[] = []

process.on("SIGINT", async () => {
	await talkBack.stop()
	process.exit(130)
})

async function check(name: string, action: () => Promise<unknown>, wanted: RegExp[] = [], unwanted: RegExp[] = []) {
	talkBack.mark()
	let lost: Error | undefined
	try {
		await action()
	} catch (error) {
		lost = error as Error
	}
	const missing = () => wanted.filter(want => !want.test(talkBack.heard.join(" | "))).map(String)
	const deadline = Date.now() + (lost ? 0 : PATIENCE_MILLIS)
	while (missing().length > 0 && Date.now() < deadline) await sleep(250)
	const heard = lost ? [`(${lost.message})`] : talkBack.heard
	const wrong = unwanted.filter(line => line.test(heard.join(" | "))).map(String)
	const ok = !lost && missing().length === 0 && wrong.length === 0
	results.push({ name, heard, ok })
	console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `\n     missing: ${missing().join(", ")}\n     unwanted: ${wrong.join(", ")}\n     heard: ${heard.join(" | ")}`}`)
	if (lost) throw new Error(`"${name}" never got there`)
}

async function tap(label: RegExp, limit = 30) {
	await talkBack.find(label, limit)
	talkBack.mark()
	await talkBack.activate()
}

async function edit(label: string) {
	await talkBack.find(new RegExp(`Edit box.*${label}`))
	for (let attempt = 0; attempt < 3; attempt++) {
		await talkBack.activate()
		if (await talkBack.waitForKeyboard(true)) return
	}
	throw new Error(`"${label}" did not take focus`)
}

async function type(text: string) {
	await talkBack.type(text)
	await talkBack.hideKeyboard()
}

async function fill(label: string, text: string) {
	await edit(label)
	await type(text)
}

async function erase(characters: number) {
	await talkBack.key("KEYCODE_MOVE_END")
	for (let count = 0; count < characters; count++) await talkBack.shell("input keyevent KEYCODE_DEL")
}

async function scenario() {
	await talkBack.shell(`am force-stop ${APP}; pm clear ${APP}`)
	await talkBack.perform(() => talkBack.shell(`am start -W -n ${APP}/dev.hloth.nativenote.MainActivity`))

	await check("welcome is a heading", () => talkBack.find(/Welcome to Native Note/, 6), [/Welcome to Native Note.*Heading/])
	await check("the password step is announced", () => tap(/^Next, Button/), [/Password/, /Set an unlock password.*Heading/])
	await fill("Password", PASSWORD)
	await fill("Confirm password", "correct hose")
	await check("a mismatch is spoken", () => tap(/^Next, Button/), [/The passwords do not match\./])
	await talkBack.hideKeyboard()
	await edit("Confirm password")
	await erase(2)
	await type("rse")
	await check("setting up is busy, then offers sync", () => tap(/^Next, Button/), [/In progress/, /Sync your notes.*Heading/])
	await check("declining sync opens the list", () => tap(/^Not now/), [/Notes/])
	await check("New note comes before the list and opens the editor", () => tap(/^New note, Button/, 12), [/Note/, /Edit box, Note/])
	await type("Groceries")
	await check("leaving the note lands on the list", () => talkBack.key("KEYCODE_BACK"), [/Notes|Native Note, Heading/])
	await check("a note is a plain row with its date", () => talkBack.find(/Groceries/), [/Groceries.*No additional text.*\d/], [/double-tap to toggle/i])
	await check("opening a note says so", () => talkBack.activate(), [/Note/])
	await check("deleting offers Undo", () => tap(/^Delete, Button/), [/Note deleted/])
	await check("Undo can be reached and used", () => tap(/^Undo, Button/), [/Note/])
	await talkBack.hideKeyboard()
	await talkBack.key("KEYCODE_BACK")
	await check("search opens on its field", () => tap(/^Search, Button/), [/Edit box, Search/])
	await check("no results are announced", () => type("zzz"), [/No results/])
	await check("clearing the search works", () => tap(/Clear search/))
	await talkBack.hideKeyboard()
	await check("Back leaves the search", () => talkBack.key("KEYCODE_BACK"), [/Native Note, Heading|Search, Button|New note, Button/])

	await check("deleting another note offers Undo", async () => {
		await tap(/^New note, Button/)
		await talkBack.type("Short lived")
		await talkBack.hideKeyboard()
		await tap(/^Delete, Button/)
	}, [/Note deleted/])
	await check("the snackbar is not read again after another note", async () => {
		await tap(/Groceries/)
		talkBack.mark()
		await tap(/^Back, Button/)
	}, [/Notes|Native Note, Heading/], [/Note deleted/])

	await check("Settings is announced", () => tap(/^Settings, Button/), [/Settings/])
	await check("settings are grouped under headings", () => talkBack.walk(16), [/Unlock, Heading/, /Sync, Heading/, /Notes, Heading/, /About, Heading/])
	await check("changing the password opens on its first field", () => tap(/^Change password/), [/Change password/, /Edit box.*Current password/])
	await type("wrong")
	await fill("New password", "another one")
	await fill("Verify", "another one")
	await check("a wrong current password is spoken", () => tap(/^Change password, Button/), [/Wrong password/])
	await talkBack.hideKeyboard()
	await check("canceling returns to Settings", () => tap(/^Cancel, Button/))
	await check("the export dialog opens on its passphrase", () => tap(/^Export notes/), [/Export notes/, /Edit box.*Passphrase/])
	await talkBack.hideKeyboard()
	await check("the encryption row is a named checkbox", () => talkBack.find(/Encrypt with a passphrase/), [/(?:^|\| )checked, Encrypt with a passphrase, Check box/i])
	await talkBack.activate()
	await check("turning encryption off keeps the focus on the checkbox, which then reads Not checked", async () => {
		await talkBack.find(/^Cancel, Button/, 1)
		await talkBack.find(/Encrypt with a passphrase/)
	}, [/not checked, Encrypt with a passphrase, Check box/i])
	await check("the export dialog closes", () => tap(/^Cancel, Button/))

	await check("sync setup is announced on its first field", () => tap(/^Sync with a server/), [/Set up sync/, /Edit box.*Server/])
	await type(server.replace(/\/$/, ""))
	await fill("API key", "not a key")
	await check("a setup error interrupts", () => tap(/^Continue, Button/), [/64-character API key/])
	await talkBack.hideKeyboard()
	await edit("API key")
	await erase(10)
	await type(apiKey)
	await check("the words step is announced", () => tap(/^Continue, Button/), [/Write down your recovery phrase/])
	await check("revealing lands on the first word", () => tap(/^Reveal, Button/), [/1\. [a-z]+/])
	await check("the words run in order", () => talkBack.walk(23), [/2\. [a-z]+.*3\. [a-z]+.*12\. [a-z]+.*13\. [a-z]+.*24\. [a-z]+/])
	await check("the confirm step is announced on its first word", () => tap(/^Continue, Button/), [/Confirm/, /Edit box.*Word \d+/])
	const asked = /Edit box.*?Word (\d+)/.exec(talkBack.heard.join(" | "))
	await type("zzzz")
	await check("a word that is not in the list is named", async () => {
		await talkBack.find(new RegExp(`Word ${asked?.[1]}\\b`))
	}, [/Error: Word \d+ is not in the recovery word list/])
	await check("Back returns to the words", () => talkBack.key("KEYCODE_BACK"), [/Write down your recovery phrase/])
	await talkBack.key("KEYCODE_BACK")
	await talkBack.hideKeyboard()
	for (let press = 0; press < 2; press++) await talkBack.key("KEYCODE_BACK")
	await check("locking lands on the password", () => tap(/^Lock, Button/), [/Unlock/, /Edit box.*Password/])
	await type("nope")
	await check("a wrong unlock password is spoken", () => tap(/^Unlock, Button/), [/Error: Wrong password/])
	await talkBack.hideKeyboard()
}

let stopped = ""
await talkBack.start()
try {
	await scenario()
} catch (error) {
	stopped = (error as Error).message
	console.log(`FAIL the run stopped: ${stopped}`)
} finally {
	await talkBack.stop()
}

const misread = [...new Set(results.flatMap(result => result.heard).filter(line => NEVER.some(pattern => pattern.test(line))))]
console.log(misread.length === 0 ? "ok   nothing was misread" : `FAIL misread:\n     ${misread.join("\n     ")}`)
const failed = results.filter(result => !result.ok).length + (misread.length > 0 ? 1 : 0) + (stopped === "" ? 0 : 1)
console.log(failed === 0 ? `all ${results.length + 1} checks passed` : `${failed} failed`)
await Bun.write(process.env.REPORT ?? "report.txt", results.map(result => `${result.ok ? "ok" : "FAIL"} ${result.name}\n${result.heard.map(line => `  ${line}`).join("\n")}`).join("\n\n"))
process.exit(failed === 0 ? 0 : 1)
