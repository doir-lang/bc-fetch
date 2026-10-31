# bc-fetch

HTTP, JSON and JSON-RPC for `-betterC` D, which has no Phobos, on [libfp](https://github.com/doir-lang/libfp), for native targets and `wasm32-wasi` alike.

- `bc.json` — editable documents: minified JSON text with an index of its values, so finding a member or an element allocates nothing. `parse` reads one, `set`, `append`, `insert`, `replace` and `remove` edit it in place, `json` gives its text and `pretty` lays it out; a `Value` names one value, `v["key"][0]`, and stays valid across edits.
- `bc.jsonrpc` — JSON-RPC messages framed by `Content-Length` headers over file descriptors, as Language Server Protocol clients speak over a server's stdin and stdout.
- `bc.http` — an HTTP client shaped like fetch: `start` a `Request` without blocking, then `poll` and `readBody` as the response arrives, or block with `fetch` and `readAll`. Natively it speaks HTTP/1.1 over sockets, with OpenSSL for `https` and host names resolved on a thread; on `wasm32-wasi` it calls the host's fetch through [js/bc-fetch.mjs](js/bc-fetch.mjs).
- `bc.http.message` — HTTP/1.1 without I/O: parse URLs, write request heads, and read response heads and bodies, `chunked` included, from bytes already received.

Call these modules' functions fully qualified, as in `bc.json.parse(text)` or `bc.http.free(f)`: several define `free`.
They share package `bc` with [bc-threads](https://github.com/doir-lang/bc-threads).

## Building

```sh
dub build --config=library --compiler=ldc2   # static library
dub test --compiler=ldc2                     # build and run the unittests
python3 tools/doctest.py                     # compile and run every DDoc example
python3 tools/wasi.py --node                 # build the unittests for wasm32-wasi and run them under Node
python3 tools/wasi.py --browser              # ... or in headless Firefox; --serve serves them to open in any browser
```

Native builds link OpenSSL 3 (`libssl` and `libcrypto`), as `dub.json` declares, and start the threads that resolve host names with `bc.thread` from [bc-threads](https://github.com/doir-lang/bc-threads).
On macOS, install OpenSSL with Homebrew and point the linker at it, for instance with `"lflags-osx": ["-L/opt/homebrew/opt/openssl/lib"]` in your own `dub.json`.

LDC only: libfp, which this depends on, refuses DMD at compile time, so `dub.json` declares DMD unsupported.

## Testing

`-betterC` has no unittest runner of its own, so [tests/runner.d](tests/runner.d) walks each `bc` module with `__traits(getUnitTests)` and calls the tests itself, reporting each module and test index to `stderr` as it goes.

## WebAssembly

On `wasm32-wasi`, `bc.http` imports the `bc_http` functions that [js/bc-fetch.mjs](js/bc-fetch.mjs) makes, and the module must export `bc_http_wake` (link with `--export=bc_http_wake`).
Copy `js/bc-fetch.mjs` and `js/bc-fetch-fetcher.mjs` beside your host script, then:

```js
import { createBcHttp } from "./bc-fetch.mjs";
const bcHttp = await createBcHttp();
const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport, ...bcHttp.imports });
bcHttp.attach(instance);
```

Where the module's thread may block, as on a worker or under Node, each fetch runs on a helper worker, so `bc.http.wait`, `fetch` and `readAll` work as they do natively; a browser needs cross-origin isolation for the shared memory this takes.
On a browser's main thread they cannot block: poll from a `bc.http.setWake` hook instead.

A browser hides some of what native builds and Node report: a `Redirect.manual` response has status 0 and no fields, and too many redirects fail as `Failure.network`.

[tools/wasi.py](tools/wasi.py) builds the unittests against a [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) sysroot, which it downloads into `bin/wasi-sdk` on first use, and runs them against routes it serves itself: under Node with `--node`, in headless Firefox with `--browser`, or in any browser you open with `--serve`.
Each mode also checks, on the main thread, that a fetch completes driven only by `setWake`.
