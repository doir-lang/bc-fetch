// Runs the wasm32-wasi tests under Node: `node node.mjs TESTS.wasm REACTOR.wasm URL`, with tools/wasi.py serving the routes at URL.
import { readFile } from "node:fs/promises";
import { runMainThread, runTests } from "./run.mjs";

const [tests, reactor, url] = process.argv.slice(2);
const code = await runTests(await readFile(tests), url, console.log, console.error)
	|| await runMainThread(await readFile(reactor), url, console.log, console.error);
process.exit(code);
