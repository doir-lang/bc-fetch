// The test worker, in a browser or under Node: runs the unittests with the bc_http imports, posting each line they write, then their status.
import { ConsoleStdout, File, OpenFile, PreopenDirectory, WASI } from "./node_modules/@bjorn3/browser_wasi_shim/dist/index.js";
import { createBcHttp, onMessage, postToParent } from "./bc-http.mjs";

onMessage(async ({ wasm, url }) => {
	const say = (stream) => (line) => postToParent({ stream, line });
	try {
		const module = await WebAssembly.compile(wasm);
		const wasi = new WASI(["bc-http-tests"], [`BC_HTTP_TEST_URL=${url}`],
			[new OpenFile(new File([])), ConsoleStdout.lineBuffered(say("stdout")), ConsoleStdout.lineBuffered(say("stderr")), new PreopenDirectory("/tmp", new Map())], { debug: false });
		const bcHttp = await createBcHttp();
		const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport, ...bcHttp.imports });
		bcHttp.attach(instance);
		let code;
		try {
			code = wasi.start(instance);
		} catch (e) {
			// wasi-libc's `abort` is a trap, which WASI does not turn into an exit status.
			if (!(e instanceof WebAssembly.RuntimeError)) throw e;
			say("stderr")(`trapped: ${e.message}`);
			code = 134;
		}
		bcHttp.close();
		postToParent({ exit: code });
	} catch (e) {
		postToParent({ error: String(e?.stack ?? e) });
	}
});
