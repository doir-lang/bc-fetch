// The host side of bc.http on wasm32-wasi: the `bc_http` imports, which run each request with fetch and buffer its head and body for the module.

export const isNode = typeof process === "object" && typeof process.versions?.node === "string";
const workerThreads = isNode ? await import("node:worker_threads") : null;

// What the `state` import reports; bc.http's HostState matches.
const PENDING = 0, HEAD = 1, DONE = 2, FAILED = 3;

// bc.http.Failure's values.
const Failure = { invalidUrl: 2, unsupported: 3, network: 4, tooManyRedirects: 6, redirectRefused: 7, aborted: 8 };

// A request's buffer: these 32-bit counters, then its head as text, then a ring of body bytes.
const STATE = 0, FAILURE = 1, STATUS = 2, HEAD_LENGTH = 3, WRITTEN = 4, READ = 5;
const metaBytes = 32;
const headCapacity = 1 << 16;
// A power of two, so a position is a running count masked, even after the count wraps.
const ringCapacity = 1 << 20;

function views(buffer) {
	return {
		meta: new Int32Array(buffer, 0, metaBytes / 4),
		head: new Uint8Array(buffer, metaBytes, headCapacity),
		ring: new Uint8Array(buffer, metaBytes + headCapacity, ringCapacity),
	};
}

function failureOf(error) {
	// Node says why in the cause; a browser says only that fetch failed.
	const why = String(error?.cause?.message ?? error?.message ?? "");
	if (/unexpected redirect/i.test(why)) return Failure.redirectRefused;
	if (/redirect count exceeded/i.test(why)) return Failure.tooManyRedirects;
	return Failure.network;
}

/// Runs `request` with fetch, writing its head and then its body into `buffer` as they arrive, and calling `notify` after each change. When the ring is full it waits on `space(meta, read, signal)`, which resolves once the module has read some or `signal` aborts.
export async function pump(request, buffer, signal, notify, space) {
	const { meta, head, ring } = views(buffer);
	const fail = (failure) => {
		if (Atomics.load(meta, STATE) >= DONE) return;
		Atomics.store(meta, FAILURE, failure);
		Atomics.store(meta, STATE, FAILED);
		notify();
	};
	// A browser refusing a redirect says only that fetch failed, so a refusal is found from a manual redirect's response instead.
	const refuse = request.redirect === "error";
	let response;
	try {
		response = await fetch(request.url, { method: request.method, headers: request.headers, body: request.body, redirect: refuse ? "manual" : request.redirect, signal });
	} catch (e) {
		return fail(signal.aborted ? Failure.aborted : failureOf(e));
	}
	if (refuse && (response.type === "opaqueredirect" || ([301, 302, 303, 307, 308].includes(response.status) && response.headers.has("location")))) {
		response.body?.cancel().catch(() => {});
		return fail(Failure.redirectRefused);
	}
	let text = `${response.url || request.url}\r\n`;
	for (const [name, value] of response.headers) text += `${name}: ${value}\r\n`;
	const encoded = new TextEncoder().encode(text);
	if (encoded.length > headCapacity) return fail(Failure.network);
	head.set(encoded);
	Atomics.store(meta, HEAD_LENGTH, encoded.length);
	Atomics.store(meta, STATUS, response.status);
	Atomics.store(meta, STATE, HEAD);
	notify();
	try {
		const reader = response.body?.getReader();
		for (;;) {
			const { done, value } = reader ? await reader.read() : { done: true };
			if (done) break;
			for (let at = 0; at < value.length;) {
				const written = Atomics.load(meta, WRITTEN), read = Atomics.load(meta, READ);
				const room = ringCapacity - ((written - read) | 0);
				if (room === 0) {
					await space(meta, read, signal);
					if (signal.aborted) throw signal.reason;
					continue;
				}
				const n = Math.min(room, value.length - at), start = written & (ringCapacity - 1), first = Math.min(n, ringCapacity - start);
				ring.set(value.subarray(at, at + first), start);
				ring.set(value.subarray(at + first, at + n), 0);
				Atomics.store(meta, WRITTEN, (written + n) | 0);
				at += n;
				notify();
			}
		}
	} catch (e) {
		return fail(signal.aborted ? Failure.aborted : Failure.network);
	}
	Atomics.store(meta, STATE, DONE);
	notify();
}

/// How the helper worker waits for the module to read from a full ring.
export async function sharedSpace(meta, read, signal) {
	while (Atomics.load(meta, READ) === read && !signal.aborted) {
		const result = Atomics.waitAsync(meta, READ, read, 100);
		if (result.async) await result.value;
	}
}

/// Starts the module script `url` on a new worker.
export function spawn(url) {
	return isNode ? new workerThreads.Worker(url) : new Worker(url, { type: "module" });
}

/// Calls `handle` with each message the worker's creator posts it.
export function onMessage(handle) {
	if (isNode) workerThreads.parentPort.on("message", handle);
	else self.onmessage = (e) => handle(e.data);
}

/// Posts `message` from this worker to its creator.
export function postToParent(message) {
	if (isNode) workerThreads.parentPort.postMessage(message);
	else self.postMessage(message);
}

/// Calls `handle` with each message `worker` posts.
export function onWorkerMessage(worker, handle) {
	if (isNode) worker.on("message", handle);
	else worker.onmessage = (e) => handle(e.data);
}

// Whether this thread may block in Atomics.wait, which a browser's main thread may not, and has shared memory, which needs cross-origin isolation in a browser.
function canBlock() {
	if (typeof SharedArrayBuffer !== "function") return false;
	try {
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 1, 0);
		return true;
	} catch {
		return false;
	}
}

/// Makes the `bc_http` imports for one module instance. Pass `imports` to `WebAssembly.instantiate` beside WASI's, then `attach` the instance before running it, and `close` when done to stop the helper worker. `fetcherUrl` locates bc-http-fetcher.mjs, beside this script by default. `blocking` forces the mode below, and `onWake` is called after the module's `bc_http_wake` in the non-blocking one, for a host that drives the module from JS.
///
/// Where this thread may block, as on a worker or under Node, fetch runs on a helper worker and each request's buffer is shared, so the module's `wait` sleeps until the worker writes. On a browser's main thread, or without cross-origin isolation, fetch runs on this thread instead: `wait` may not block, and the module's exported `bc_http_wake` is called after each change.
export async function createBcHttp({ fetcherUrl = new URL("./bc-http-fetcher.mjs", import.meta.url), blocking = canBlock(), onWake = null } = {}) {
	const control = new Int32Array(blocking ? new SharedArrayBuffer(4) : new ArrayBuffer(4));
	const slots = new Map();
	let nextId = 1, memory = null, exports = null, worker = null;

	if (blocking) {
		worker = spawn(fetcherUrl);
		await new Promise((resolve) => {
			onWorkerMessage(worker, resolve);
			worker.postMessage({ control: control.buffer });
		});
	}

	const notify = () => {
		Atomics.add(control, 0, 1);
		exports?.bc_http_wake?.();
		onWake?.();
	};
	const bytes = (pointer, length) => new Uint8Array(memory.buffer, pointer >>> 0, length >>> 0);
	const slot = (id) => slots.get(id);

	const imports = {
		start(pointer, length) {
			const data = bytes(pointer, length).slice();
			const view = new DataView(data.buffer);
			const decoder = new TextDecoder();
			let at = 0;
			const part = () => {
				const n = view.getUint32(at, true);
				at += 4 + n;
				return data.subarray(at - n, at);
			};
			const method = decoder.decode(part()), url = decoder.decode(part()), redirect = ["follow", "error", "manual"][data[at++]];
			const headers = [];
			for (const line of decoder.decode(part()).split("\r\n")) {
				const colon = line.indexOf(":");
				if (colon > 0) headers.push([line.slice(0, colon), line.slice(colon + 2)]);
			}
			const body = part();

			const id = nextId++;
			const buffer = blocking ? new SharedArrayBuffer(metaBytes + headCapacity + ringCapacity) : new ArrayBuffer(metaBytes + headCapacity + ringCapacity);
			const s = { ...views(buffer), controller: null, onRead: null };
			slots.set(id, s);
			let parsed = null;
			try {
				parsed = new URL(url, globalThis.location?.href);
			} catch {}
			const failure = !parsed || parsed.username || parsed.password ? Failure.invalidUrl
				: !["http:", "https:", "data:", "blob:"].includes(parsed.protocol) ? Failure.unsupported : 0;
			if (failure) {
				s.meta[FAILURE] = failure;
				s.meta[STATE] = FAILED;
				return id;
			}
			const request = { method, url: parsed.href, headers, body: body.length ? body : undefined, redirect };
			if (worker) worker.postMessage({ id, request, buffer });
			else {
				s.controller = new AbortController();
				const space = (meta, read, signal) => new Promise((resolve) => {
					s.onRead = resolve;
					signal.addEventListener("abort", resolve);
				});
				pump(request, buffer, s.controller.signal, notify, space);
			}
			return id;
		},
		state: (id) => (slot(id) ? Atomics.load(slot(id).meta, STATE) : FAILED),
		failure: (id) => (slot(id) ? Atomics.load(slot(id).meta, FAILURE) : Failure.aborted),
		status: (id) => Atomics.load(slot(id).meta, STATUS),
		headLength: (id) => Atomics.load(slot(id).meta, HEAD_LENGTH),
		copyHead(id, pointer) {
			const s = slot(id), n = Atomics.load(s.meta, HEAD_LENGTH);
			bytes(pointer, n).set(s.head.subarray(0, n));
		},
		buffered(id) {
			const s = slot(id);
			return s ? (Atomics.load(s.meta, WRITTEN) - Atomics.load(s.meta, READ)) | 0 : 0;
		},
		read(id, pointer, length) {
			const s = slot(id);
			if (!s) return 0;
			const read = Atomics.load(s.meta, READ);
			const n = Math.min(length >>> 0, (Atomics.load(s.meta, WRITTEN) - read) | 0), start = read & (ringCapacity - 1), first = Math.min(n, ringCapacity - start);
			const into = bytes(pointer, n);
			into.set(s.ring.subarray(start, start + first));
			into.set(s.ring.subarray(0, n - first), first);
			Atomics.store(s.meta, READ, (read + n) | 0);
			if (blocking) Atomics.notify(s.meta, READ);
			else s.onRead?.();
			return n;
		},
		close(id) {
			const s = slot(id);
			if (!s) return;
			slots.delete(id);
			if (worker) worker.postMessage({ abort: id });
			else s.controller.abort();
		},
		generation: () => Atomics.load(control, 0),
		wait(generation, timeoutMs) {
			if (Atomics.load(control, 0) !== generation) return 1;
			if (!blocking) {
				if (timeoutMs === 0) return 0;
				throw new Error("bc.http: wait cannot block on this thread; poll from the setWake hook instead");
			}
			return Atomics.wait(control, 0, generation, timeoutMs < 0 ? Infinity : timeoutMs) === "timed-out" ? 0 : 1;
		},
		now: () => performance.now(),
	};

	return {
		imports: { bc_http: imports },
		attach(instance) {
			exports = instance.exports;
			memory = exports.memory;
		},
		close() {
			worker?.terminate();
		},
	};
}
