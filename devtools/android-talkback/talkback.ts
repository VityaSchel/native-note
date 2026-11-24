import { $, sleep } from "bun"
import { connect, type Socket } from "node:net"
import { homedir } from "node:os"

const sdk = process.env.ANDROID_HOME ?? `${homedir()}/Library/Android/sdk`
const TALKBACK = "com.google.android.marvin.talkback"
const SPEECH = "dev.hloth.devtools.speech"
const QUIET_MILLIS = 1_200
const FIRST_WORD_MILLIS = 4_000
const BACK_TO_TOUCH_MODE = "input tap 540 20"

const SETTINGS = {
	"global hide_error_dialogs": "1",
	"secure show_ime_with_hard_keyboard": "0",
	"secure tts_default_synth": SPEECH,
	"secure enabled_accessibility_services": `${TALKBACK}/${TALKBACK}.TalkBackService`,
	"secure accessibility_enabled": "1",
}

export class TalkBack {
	private readonly adb = `${sdk}/platform-tools/adb`
	private console!: Socket
	private transcript: string[] = []
	private marked = 0
	private lastSpoke = 0
	private log?: Bun.Subprocess<"ignore", "pipe", "ignore">
	private before: Record<string, string> = {}

	constructor(readonly serial: string) {
		if (!/^emulator-\d+$/.test(serial)) throw new Error("this changes accessibility settings, so it only runs on an emulator")
	}

	get heard(): string[] {
		return this.transcript.slice(this.marked)
	}

	mark() {
		this.marked = this.transcript.length
	}

	async shell(command: string): Promise<string> {
		return (await $`${this.adb} -s ${this.serial} shell ${command}`.nothrow().quiet().text()).trim()
	}

	async start() {
		await this.connectConsole()
		this.log = Bun.spawn([this.adb, "-s", this.serial, "logcat", "-v", "raw", "-T", "1", "-s", "SpeechLog:I"], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
		void this.listen(this.log.stdout)
		await this.shell(`pm grant ${TALKBACK} android.permission.POST_NOTIFICATIONS; input keyevent KEYCODE_HOME`)
		for (const [name, value] of Object.entries(SETTINGS)) {
			this.before[name] = await this.shell(`settings get ${name}`)
			await this.shell(`settings put ${name} '${value}'`)
		}
		for (let attempt = 0; attempt < 30; attempt++) {
			if ((await this.shell("dumpsys accessibility | grep -o -m1 'touchExplorationEnabled=true'")) !== "") break
			await sleep(500)
		}
		await this.settle()
	}

	async stop() {
		for (const [name, value] of Object.entries(this.before).reverse()) {
			await this.shell(value === "null" ? `settings delete ${name}` : `settings put ${name} '${value}'`)
		}
		this.before = {}
		this.log?.kill()
		this.console?.destroy()
	}

	async next(): Promise<string[]> {
		return this.perform(() => this.swipe(300, 900, 1_300))
	}

	async activate(): Promise<string[]> {
		return this.perform(async () => {
			for (let tap = 0; tap < 2; tap++) {
				this.touch(540, 1_300, true)
				await sleep(40)
				this.touch(540, 1_300, false)
				await sleep(100)
			}
		})
	}

	async find(wanted: RegExp, limit = 30): Promise<string[]> {
		const seen: string[] = []
		for (let step = 0; step < limit; step++) {
			const said = await this.next()
			if (said.some(phrase => wanted.test(phrase))) return said
			seen.push(said.join(" | "))
		}
		throw new Error(`no ${wanted} in ${limit} steps; heard:\n  ${seen.join("\n  ")}`)
	}

	async walk(limit: number): Promise<string[]> {
		const lines: string[] = []
		for (let step = 0; step < limit; step++) {
			const line = (await this.next()).join(" | ")
			if (line === "" || line === lines.at(-1)) break
			lines.push(line)
		}
		return lines
	}

	async type(text: string): Promise<string[]> {
		const said = await this.perform(() => this.shell(`input text '${text.replaceAll(" ", "%s")}'`))
		await this.shell(BACK_TO_TOUCH_MODE)
		return said
	}

	async hideKeyboard() {
		if (!(await this.waitForKeyboard(true, 1_500))) return
		await this.shell("input keyevent KEYCODE_BACK")
		await this.waitForKeyboard(false)
		await this.settle()
	}

	async waitForKeyboard(shown: boolean, limit = 5_000): Promise<boolean> {
		const deadline = Date.now() + limit
		while (Date.now() < deadline) {
			if ((await this.shell("dumpsys input_method")).includes(`mInputShown=${shown}`)) return true
			await sleep(250)
		}
		return false
	}

	async key(name: string): Promise<string[]> {
		return this.perform(() => this.shell(`input keyevent ${name}; ${BACK_TO_TOUCH_MODE}`))
	}

	async perform(action: () => Promise<unknown>): Promise<string[]> {
		const from = this.transcript.length
		this.lastSpoke = 0
		await action()
		await this.settle()
		return this.transcript.slice(from)
	}

	private async settle() {
		const started = Date.now()
		while (Date.now() - started < 20_000) {
			const quietSince = Math.max(this.lastSpoke, started)
			if (Date.now() - quietSince >= (this.lastSpoke >= started ? QUIET_MILLIS : FIRST_WORD_MILLIS)) return
			await sleep(100)
		}
	}

	private touch(x: number, y: number, down: boolean) {
		this.console.write(`event mouse ${Math.round(x)} ${Math.round(y)} 0 ${down ? 1 : 0}\n`)
	}

	private async swipe(from: number, to: number, y: number) {
		const steps = 8
		for (let step = 0; step <= steps; step++) {
			this.touch(from + ((to - from) * step) / steps, y, true)
			await sleep(12)
		}
		this.touch(to, y, false)
	}

	private async connectConsole() {
		const token = (await Bun.file(`${homedir()}/.emulator_console_auth_token`).text()).trim()
		this.console = connect(Number(this.serial.split("-")[1]), "127.0.0.1")
		this.console.on("data", () => {})
		await new Promise<void>((resolve, reject) => {
			this.console.once("connect", () => resolve())
			this.console.once("error", reject)
		})
		this.console.write(`auth ${token}\n`)
		await sleep(300)
	}

	private async listen(stream: ReadableStream<Uint8Array>) {
		let rest = ""
		for await (const chunk of stream.pipeThrough(new TextDecoderStream())) {
			const lines = (rest + chunk).split("\n")
			rest = lines.pop()!
			for (const line of lines) {
				const match = /^(SAY|CUT) (.*)$/.exec(line.trim())
				if (!match || match[2].trim() === "") continue
				const phrase = match[2].replace(/\. (?=[A-Z0-9])/g, ", ")
				this.transcript.push(match[1] === "CUT" ? `[cut] ${phrase}` : phrase)
				this.lastSpoke = Date.now()
			}
		}
	}
}
