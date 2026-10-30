// The browser page: runs the tests against the server that serves it, showing each line and the result.
import { runMainThread, runTests } from "./run.mjs";

const output = document.getElementById("output");
const lines = [];
const show = (line) => {
	lines.push(line);
	output.append(line + "\n");
};
const bytes = async (name) => (await fetch(name)).arrayBuffer();

if (!crossOriginIsolated) show("not cross-origin isolated: serve this page with tools/wasi.py --serve");
const code = await runTests(await bytes("bc-http-tests.wasm"), location.origin, show, show)
	|| await runMainThread(await bytes("bc-http-reactor.wasm"), location.origin, show, show);
show(code === 0 ? "passed" : `failed with status ${code}`);
document.title = code === 0 ? "bc-http tests passed" : "bc-http tests failed";
// tools/wasi.py --browser waits for this to learn how the tests went.
await fetch("/result", { method: "POST", body: JSON.stringify({ code, lines }) });
