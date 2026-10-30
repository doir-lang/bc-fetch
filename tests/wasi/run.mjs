// Runs the wasm32-wasi tests, shared by the browser page and Node: the unittests on a worker, since they block, then the main-thread check.
import { ConsoleStdout, WASI } from "./node_modules/@bjorn3/browser_wasi_shim/dist/index.js";
import { createBcHttp, onWorkerMessage, spawn } from "./bc-http.mjs";

/// Runs the unittest module's bytes `wasm` against the test server at `url`, passing each line it writes to `stdout` or `stderr`. Resolves to its exit status, 134 when an assertion trapped.
export function runTests(wasm, url, stdout, stderr) {
	return new Promise((resolve) => {
		const worker = spawn(new URL("./main.mjs", import.meta.url));
		onWorkerMessage(worker, (message) => {
			if ("line" in message) (message.stream === "stdout" ? stdout : stderr)(message.line);
			else {
				if ("error" in message) stderr(`could not run: ${message.error}`);
				worker.terminate();
				resolve("error" in message ? 1 : message.exit);
			}
		});
		worker.postMessage({ wasm, url });
	});
}

/// Runs the reactor module's bytes `wasm` on this thread with the non-blocking imports, as a browser's main thread must: it fetches `url`/hello, reading the body only from the `setWake` hook's wakes. Resolves to an exit status.
export async function runMainThread(wasm, url, stdout, stderr) {
	let woken = null;
	const bcHttp = await createBcHttp({ blocking: false, onWake: () => woken?.() });
	const wasi = new WASI(["bc-http-reactor"], [], [null, ConsoleStdout.lineBuffered(stdout), ConsoleStdout.lineBuffered(stderr)], { debug: false });
	const instance = await WebAssembly.instantiate(await WebAssembly.compile(wasm), { wasi_snapshot_preview1: wasi.wasiImport, ...bcHttp.imports });
	bcHttp.attach(instance);
	wasi.initialize(instance);
	const e = instance.exports;
	const text = new TextEncoder().encode(`${url}/hello`);
	new Uint8Array(e.memory.buffer, e.urlBuffer(), text.length).set(text);
	if (!e.begin(text.length)) {
		stderr("main thread: begin failed");
		return 1;
	}
	const result = await new Promise((resolve) => {
		const timer = setTimeout(() => resolve("timed out"), 5000);
		woken = () => {
			const state = e.step();
			if (state === 0) return;
			clearTimeout(timer);
			resolve(state === 1 ? "ok" : "failed");
		};
	});
	const wakes = e.wakes();
	if (result !== "ok" || wakes === 0) {
		stderr(`main thread: ${result}, ${wakes} wakes`);
		return 1;
	}
	stdout(`main thread: fetched by ${wakes} wakes`);
	return 0;
}
