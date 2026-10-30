// The helper worker bc-http.mjs starts where the module's thread may block: it runs each request's fetch, since a thread blocked in Atomics.wait cannot.
import { onMessage, postToParent, pump, sharedSpace } from "./bc-http.mjs";

let control = null;
const controllers = new Map();

const notify = () => {
	Atomics.add(control, 0, 1);
	Atomics.notify(control, 0);
};

onMessage((message) => {
	if (message.control) {
		control = new Int32Array(message.control);
		postToParent({ ready: true });
	} else if ("abort" in message) {
		controllers.get(message.abort)?.abort();
		controllers.delete(message.abort);
	} else {
		const controller = new AbortController();
		controllers.set(message.id, controller);
		pump(message.request, message.buffer, controller.signal, notify, sharedSpace).finally(() => controllers.delete(message.id));
	}
});
