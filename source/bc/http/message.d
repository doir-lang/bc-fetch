/// HTTP/1.1 messages without I/O: parse a URL, write a request head, and read a response head and body from bytes the caller has already received.
/// Nothing here touches a socket, so a client can drive it from any event loop.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// char* request = null;
/// scope(exit) fp.dynarray.free(request);
/// auto url = parseUrl("http://example.com/a?b").get;
/// assert(writeRequestLine(request, "GET", url.target) && writeField(request, "Host", url.authority) && endHead(request));
/// assert(fp.dynarray.slice(request) == "GET /a?b HTTP/1.1\r\nHost: example.com\r\n\r\n");
///
/// char[40] bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
/// auto head = parseHead(bytes[], "GET");
/// assert(head.progress == Progress.ok && head.status == 200);
/// auto b = bodyOf(head);
/// auto d = decode(b, bytes[head.size .. $]);
/// assert(bytes[head.size .. head.size + d.produced] == "hi" && b.ended);
/// ---
module bc.http.message;

static import core.stdc.string;

static import std.typecons;

static import fp.pointer;
static import fp.string;
static import fp.string.ascii;
static import fp.string.numbers;
static import fp.dynarray;

@nogc nothrow:


// --- names -------------------------------------------------------------------

private bool tokenChar(char c) {
	if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return true;
	foreach (s; "!#$%&'*+-.^_`|~") if (c == s) return true;
	return false;
}

/// Whether `name` can be a header field's name: one or more token characters.
///
/// Examples:
/// ---
/// assert(validName("X-Request-Id") && !validName("") && !validName("Bad Name"));
/// ---
bool validName(const(char)[] name) {
	foreach (c; name) if (!tokenChar(c)) return false;
	return name.length > 0;
}

/// Whether `value` can be a header field's value: no line breaks or other control characters but tab, so it cannot end the field early.
///
/// Examples:
/// ---
/// assert(validValue("text/html; charset=utf-8") && !validValue("a\r\nInjected: 1"));
/// ---
bool validValue(const(char)[] value) {
	foreach (c; value) if ((c < ' ' && c != '\t') || c == 0x7f) return false;
	return true;
}

/// One header field, as views into the text it was read from or will be written to.
struct Header {
	const(char)[] name; /// As given; compare it with `sameName`.
	const(char)[] value; /// Without surrounding spaces.
}


// --- URLs --------------------------------------------------------------------

/// The parts of an absolute URL that a request needs, as views into the URL's text.
struct Url {
	const(char)[] scheme; /// As written, such as `http`.
	const(char)[] host; /// The host name or address, an IPv6 address without its brackets.
	const(char)[] authority; /// The host and any port as written, for the `Host` field.
	ushort port; /// The port given, or the scheme's default: 80 for `http`, 443 for `https`, otherwise 0.
	const(char)[] target; /// The path and query without the fragment; it may be empty or start with `?`, which `writeRequestLine` mends.
}

/// Splits `text`, an absolute URL such as `http://host:8080/path?query`, into its parts.
///
/// Returns an empty `Nullable` if it has no scheme or host, has a malformed port, has a user name or password, which fetch refuses too, or has a space or control character, which would break the request line.
///
/// Examples:
/// ---
/// auto u = parseUrl("http://[::1]:8080/p?q#f").get;
/// assert(u.host == "::1" && u.authority == "[::1]:8080" && u.port == 8080 && u.target == "/p?q");
/// assert(parseUrl("https://example.com").get.port == 443);
/// assert(parseUrl("example.com/p").isNull && parseUrl("http://user@example.com").isNull);
/// ---
std.typecons.Nullable!Url parseUrl(const(char)[] text) {
	typeof(return) none;
	foreach (c; text) if (c <= ' ' || c == 0x7f) return none;
	size_t i = 0;
	while (i < text.length && ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || (i > 0 && ((text[i] >= '0' && text[i] <= '9') || text[i] == '+' || text[i] == '-' || text[i] == '.')))) ++i;
	if (i == 0 || text.length - i < 3 || text[i .. i + 3] != "://") return none;
	Url u;
	u.scheme = text[0 .. i];
	immutable start = i + 3;
	size_t end = start;
	while (end < text.length && text[end] != '/' && text[end] != '?' && text[end] != '#') ++end;
	u.authority = text[start .. end];
	u.target = text[end .. $];
	foreach (j, c; u.target) if (c == '#') {
		u.target = u.target[0 .. j];
		break;
	}
	foreach (c; u.authority) if (c == '@') return none;
	const(char)[] port;
	if (u.authority.length && u.authority[0] == '[') {
		size_t close = 1;
		while (close < u.authority.length && u.authority[close] != ']') ++close;
		if (close == u.authority.length) return none;
		u.host = u.authority[1 .. close];
		auto after = u.authority[close + 1 .. $];
		if (after.length && after[0] != ':') return none;
		if (after.length) port = after[1 .. $];
	} else {
		size_t colon = 0;
		while (colon < u.authority.length && u.authority[colon] != ':') ++colon;
		u.host = u.authority[0 .. colon];
		if (colon < u.authority.length) port = u.authority[colon + 1 .. $];
	}
	if (u.host.length == 0) return none;
	if (port.length) {
		auto n = fp.string.numbers.parseUnsigned(port);
		if (n.isNull || n.get.value > ushort.max) return none;
		u.port = cast(ushort) n.get.value;
	} else u.port = fp.string.ascii.equalIgnoringCase(u.scheme, "http") ? 80 : fp.string.ascii.equalIgnoringCase(u.scheme, "https") ? 443 : 0;
	assert(u.host.length && u.host.length <= u.authority.length, "bc.http.message: a URL's host outside its authority");
	assert(u.target.length == 0 || u.target[0] == '/' || u.target[0] == '?', "bc.http.message: a request target that is neither a path nor a query");
	return typeof(return)(u);
}

/// `text` as a new fp string with each `%` and two hexadecimal digits replaced by the byte they name, as a URL or a `file://` URI writes the characters it reserves; a `%` not followed by two hexadecimal digits is kept as written.
/// An empty `text` gives null.
///
/// Returns an empty `Nullable` if an allocation was refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// auto decoded = percentDecoded("/a%20b%2Fc%2g").get;
/// scope(exit) fp.string.free(decoded);
/// assert(fp.string.slice(decoded) == "/a b/c%2g");
/// ---
std.typecons.Nullable!(char*) percentDecoded(const(char)[] text) {
	char* out_ = null;
	assert(text.ptr !is null || text.length == 0, "bc.http.message: text with a length but no bytes");
	for (size_t i = 0; i < text.length;) {
		char c = text[i];
		size_t step = 1;
		if (c == '%' && i + 2 < text.length && fp.string.ascii.isHexDigit(text[i + 1]) && fp.string.ascii.isHexDigit(text[i + 2])) {
			c = cast(char) (fp.string.numbers.hexDigitValue(text[i + 1]) * 16 + fp.string.numbers.hexDigitValue(text[i + 2]));
			step = 3;
		}
		if (!fp.string.append(out_, c)) {
			fp.string.free(out_);
			return typeof(return).init;
		}
		i += step;
	}
	assert(fp.string.length(out_) <= text.length && fp.string.length(out_) * 3 >= text.length, "bc.http.message.percentDecoded: a length no decoding gives");
	return typeof(return)(out_);
}


// --- writing requests --------------------------------------------------------

// Appends every piece to `out_`, or nothing if it cannot grow.
/// Appends the request line `method target HTTP/1.1` to the fp dynarray `out_`, writing `target` as `/` when it is empty and putting `/` before it when it starts with `?`.
/// It does not check `method` or `target`; `parseUrl` already refuses a target that would break the line.
///
/// Returns false if `out_` could not grow, leaving it as it was.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// char* out_ = null;
/// scope(exit) fp.dynarray.free(out_);
/// assert(writeRequestLine(out_, "POST", "?q"));
/// assert(fp.dynarray.slice(out_) == "POST /?q HTTP/1.1\r\n");
/// ---
bool writeRequestLine(ref char* out_, const(char)[] method, const(char)[] target) {
	assert(validName(method), "bc.http.message.writeRequestLine: a method that is not a token");
	assert(validValue(target), "bc.http.message.writeRequestLine: a target holding control characters would split the request");
	return fp.string.append(out_, method, " ", target.length == 0 || target[0] == '?' ? "/" : "", target, " HTTP/1.1\r\n");
}

// wrapper: names an HTTP head's format, or the struct over its fields
/// Appends the field `name: value` to the fp dynarray `out_`.
/// It does not check them; see `validName` and `validValue`.
///
/// Returns false if `out_` could not grow, leaving it as it was.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// char* out_ = null;
/// scope(exit) fp.dynarray.free(out_);
/// assert(writeField(out_, "Accept", "*/*"));
/// assert(fp.dynarray.slice(out_) == "Accept: */*\r\n");
/// ---
bool writeField(ref char* out_, const(char)[] name, const(char)[] value) {
	assert(validName(name), "bc.http.message.writeField: a field name that is not a token");
	assert(validValue(value), "bc.http.message.writeField: a field value holding a line break would inject a field");
	return fp.string.append(out_, name, ": ", value, "\r\n");
}

// wrapper: names an HTTP head's format, or the struct over its fields
/// Appends the blank line that ends a head to the fp dynarray `out_`; the body, if any, follows it.
///
/// Returns false if `out_` could not grow, leaving it as it was.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// char* out_ = null;
/// scope(exit) fp.dynarray.free(out_);
/// assert(endHead(out_) && fp.dynarray.slice(out_) == "\r\n");
/// ---
bool endHead(ref char* out_) {
	assert(out_ is null || fp.string.endsWith(out_, "\r\n"), "bc.http.message.endHead: ending a head whose last line is unfinished");
	return fp.string.append(out_, "\r\n");
}


// --- reading responses -------------------------------------------------------

/// How far reading got.
enum Progress : ubyte {
	needMore, /// The bytes stop before what is being read does; call again with more.
	ok, /// It was read.
	malformed, /// The bytes are not HTTP/1.1.
}

/// How a response's body ends.
enum Framing : ubyte {
	none, /// It has no body, as with a `HEAD` request or a 1xx, 204 or 304 status.
	length, /// After `Content-Length` bytes.
	chunked, /// After the last chunk of a `chunked` transfer coding, and any trailer fields.
	close, /// When the server closes the connection.
}

/// The longest response head `parseHead` waits for before calling it malformed, so a server cannot make a client buffer without end.
enum size_t maxHeadSize = 1 << 16;

/// A response's status line and fields, and how its body is framed.
struct Head {
	Progress progress; /// Whether the rest was read.
	ushort status; /// Such as 200.
	const(char)[] reason; /// The reason phrase, such as `OK`; it may be empty.
	const(char)[] fields; /// The field lines, each ending in CRLF; walk them with `fieldsOf`.
	size_t size; /// The head's bytes, its blank line included, which the body follows.
	Framing framing; /// How the body ends.
	ulong length; /// The body's length when `framing` is `Framing.length`.
}

// The name and value of the field line `line`, which must hold a colon.
private Header field(const(char)[] line) {
	assert(fp.string.contains(line, ':'), "bc.http.message: a field line without a colon");
	size_t colon = 0;
	while (line[colon] != ':') ++colon;
	auto parsed = Header(line[0 .. colon], fp.string.trim(line[colon + 1 .. $], " \t"));
	assert(parsed.name.length + 1 + parsed.value.length <= line.length, "bc.http.message: a field longer than its line");
	return parsed;
}

/// The field lines of a head, as a range of `Header`s in the order they arrived.
struct Fields {
	private const(char)[] rest;

	/// Whether every field has been visited.
	///
	/// Examples:
	/// ---
	/// assert(fieldsOf(parseHead("HTTP/1.1 200 OK\r\n\r\n", "GET")).empty);
	/// ---
	bool empty() const @nogc nothrow {
		return rest.length == 0;
	}

	/// The field this range is on.
	///
	/// Examples:
	/// ---
	/// assert(fieldsOf(parseHead("HTTP/1.1 200 OK\r\nA: 1\r\n\r\n", "GET")).front == Header("A", "1"));
	/// ---
	Header front() const @nogc nothrow {
		assert(!empty, "bc.http.message: front of finished fields");
		assert(fp.string.contains(rest, "\r\n"), "bc.http.message: a field line without its CRLF");
		size_t end = 0;
		while (rest[end] != '\r') ++end;
		return field(rest[0 .. end]);
	}

	/// Moves to the next field.
	///
	/// Examples:
	/// ---
	/// auto f = fieldsOf(parseHead("HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\n\r\n", "GET"));
	/// f.popFront();
	/// assert(f.front.name == "B");
	/// ---
	void popFront() @nogc nothrow {
		assert(!empty, "bc.http.message: popFront of finished fields");
		immutable before = rest.length;
		size_t end = 0;
		while (rest[end] != '\r') ++end;
		rest = rest[end + 2 .. $];
		assert(rest.length < before, "bc.http.message: a field that did not advance");
	}
}

// wrapper: names an HTTP head's format, or the struct over its fields
/// The fields of `h`, as a range of `Header`s.
///
/// Examples:
/// ---
/// auto h = parseHead("HTTP/1.1 204 No Content\r\nA: 1\r\nB:  2 \r\n\r\n", "GET");
/// auto f = fieldsOf(h);
/// assert(f.front == Header("A", "1"));
/// f.popFront();
/// assert(f.front == Header("B", "2"));
/// f.popFront();
/// assert(f.empty);
/// ---
Fields fieldsOf(const Head h) {
	assert(h.progress == Progress.ok, "bc.http.message: the fields of a head that did not parse");
	assert(h.fields.length == 0 || fp.string.endsWith(h.fields, "\r\n"), "bc.http.message: fields that do not end their last line");
	return Fields(h.fields);
}

/// Reads a response head from the start of `bytes`, the response to a `method` request, and works out how its body is framed.
/// A 1xx status other than 101 is an interim response: skip its `size` bytes and read the next head.
///
/// Its `progress` is `Progress.needMore` until `bytes` holds the whole head, and `Progress.malformed` if the head is not HTTP/1.1, is longer than `maxHeadSize`, or gives a `Content-Length` that is not one number; only with `Progress.ok` are the other members set.
///
/// Examples:
/// ---
/// static immutable text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
/// assert(parseHead(text[0 .. 20], "GET").progress == Progress.needMore);
/// auto h = parseHead(text, "GET");
/// assert(h.progress == Progress.ok && h.reason == "OK" && h.framing == Framing.chunked && h.size == text.length);
/// assert(parseHead(text, "HEAD").framing == Framing.none);
/// assert(parseHead("HTTP/2 200\r\n\r\n", "GET").progress == Progress.malformed);
/// ---
Head parseHead(const(char)[] bytes, const(char)[] method) {
	Head h;
	size_t end = 0;
	while (end + 4 <= bytes.length && bytes[end .. end + 4] != "\r\n\r\n") ++end;
	if (end + 4 > bytes.length) {
		h.progress = bytes.length > maxHeadSize ? Progress.malformed : Progress.needMore;
		return h;
	}
	h.progress = Progress.malformed;
	if (end + 4 > maxHeadSize) return h;
	size_t lineEnd = 0;
	while (bytes[lineEnd] != '\r') ++lineEnd;
	if (bytes[lineEnd + 1] != '\n') return h;
	auto line = bytes[0 .. lineEnd];
	if (line.length < 12 || line[0 .. 7] != "HTTP/1." || line[7] < '0' || line[7] > '9' || line[8] != ' ' || (line.length > 12 && line[12] != ' ')) return h;
	auto parsedStatus = fp.string.numbers.parseUnsigned(line[9 .. 12]);
	if (parsedStatus.isNull) return h;
	assert(parsedStatus.get.value <= 999, "bc.http.message: three digits above 999");
	immutable status = cast(ushort) parsedStatus.get.value;
	h.status = status;
	h.reason = line.length > 12 ? line[13 .. $] : null;
	h.fields = lineEnd == end ? null : bytes[lineEnd + 2 .. end + 2];
	h.size = end + 4;

	bool chunked = false, coded = false, sized = false;
	ulong length = 0;
	for (auto rest = h.fields; rest.length;) {
		size_t stop = 0;
		while (rest[stop] != '\r') ++stop;
		if (rest[stop + 1] != '\n') return h;
		auto text = rest[0 .. stop];
		rest = rest[stop + 2 .. $];
		size_t colon = 0;
		while (colon < text.length && text[colon] != ':') ++colon;
		if (colon == text.length || !validName(text[0 .. colon]) || !validValue(text[colon + 1 .. $])) return h;
		auto f = field(text);
		if (fp.string.ascii.equalIgnoringCase(f.name, "transfer-encoding")) {
			coded = true;
			// The last coding applied decides whether the body is chunked.
			immutable comma = fp.string.findLast(f.value, ',');
			const last = comma == fp.pointer.notFound ? f.value : f.value[comma + 1 .. $];
			chunked = fp.string.ascii.equalIgnoringCase(fp.string.trimStart(last, " \t"), "chunked");
		} else if (fp.string.ascii.equalIgnoringCase(f.name, "content-length")) {
			auto n = fp.string.numbers.parseUnsigned(f.value);
			if (n.isNull || (sized && n.get.value != length)) return h;
			sized = true;
			length = n.get.value;
		}
	}

	if (fp.string.ascii.equalIgnoringCase(method, "HEAD") || (status >= 100 && status < 200) || status == 204 || status == 304) h.framing = Framing.none;
	else if (coded) h.framing = chunked ? Framing.chunked : Framing.close;
	else if (sized) {
		h.framing = Framing.length;
		h.length = length;
	} else h.framing = Framing.close;
	h.progress = Progress.ok;
	assert(h.size <= bytes.length && h.size <= maxHeadSize && h.status <= 999, "bc.http.message: a head larger than what was read, or than the limit");
	return h;
}

/// The longest chunk-size or trailer line `decode` waits for before calling the body malformed.
enum size_t maxLineSize = 1 << 12;

private enum Step : ubyte { size, data, dataEnd, trailer, done }

/// Where `decode` is in a response's body.
/// Plain data; make it with `bodyOf`.
struct Body {
	Framing framing; /// How the body ends.
	ulong remaining; /// Body bytes left: of the whole body for `Framing.length`, or of the current chunk for `Framing.chunked`.
	private Step step;
}

/// Where the body that follows head `h` ends, ready to `decode`.
///
/// Examples:
/// ---
/// auto b = bodyOf(parseHead("HTTP/1.1 204 No Content\r\n\r\n", "GET"));
/// assert(b.ended);
/// ---
Body bodyOf(const Head h) {
	assert(h.progress == Progress.ok, "bc.http.message: the body of a head that did not parse");
	assert(h.framing == Framing.length || h.length == 0, "bc.http.message: a length on a body framed otherwise");
	Body b = Body(h.framing, h.length);
	if (h.framing == Framing.none || (h.framing == Framing.length && h.length == 0)) b.step = Step.done;
	assert(b.step == Step.size || b.step == Step.done, "bc.http.message: a body that starts partway");
	return b;
}

/// Whether all of `b`'s body has been decoded.
/// A body framed by `Framing.close` never ends here: it ends when the connection does.
///
/// Examples:
/// ---
/// Body b = Body(Framing.length, 1);
/// char[1] x = 'x';
/// assert(!b.ended && decode(b, x[]).produced == 1 && b.ended);
/// ---
bool ended(ref const Body b) {
	return b.step == Step.done;
}

/// What `decode` did.
struct Decoded {
	size_t used; /// Bytes of the input consumed; keep the rest, and add more to it, for the next call.
	size_t produced; /// Body bytes now at the start of the input.
	bool malformed; /// The chunked framing was not HTTP/1.1; nothing more can be read.
}

// `decode` for a chunked body: moves each chunk's data down over the framing before it, as far as whole size lines and chunk ends reach.
private Decoded decodeChunked(ref Body b, char[] bytes) @trusted {
	assert(b.framing == Framing.chunked, "bc.http.message: chunked decoding of a body framed otherwise");
	Decoded d;
	immutable saved = b;
	size_t i = 0, o = 0;
	for (;;) {
		final switch (b.step) {
		case Step.done:
			d.used = i;
			d.produced = o;
			return d;
		case Step.size, Step.trailer:
			size_t nl = i;
			while (nl < bytes.length && bytes[nl] != '\n') ++nl;
			if (nl - i > maxLineSize) goto broken;
			if (nl == bytes.length) {
				d.used = i;
				d.produced = o;
				return d;
			}
			auto line = bytes[i .. nl];
			if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
			assert(line.length <= maxLineSize, "bc.http.message: a chunk line past maxLineSize");
			i = nl + 1;
			if (b.step == Step.trailer) {
				if (line.length == 0) b.step = Step.done;
				break;
			}
			size_t digits = 0;
			while (digits < line.length && fp.string.ascii.isHexDigit(line[digits])) ++digits;
			auto size = fp.string.numbers.parseUnsigned(line[0 .. digits], 16);
			if (size.isNull || (digits < line.length && line[digits] != ';' && line[digits] != ' ' && line[digits] != '\t')) goto broken;
			b.remaining = size.get.value;
			b.step = b.remaining ? Step.data : Step.trailer;
			break;
		case Step.data:
			immutable n = b.remaining < bytes.length - i ? cast(size_t) b.remaining : bytes.length - i;
			// The output trails the input, so the move is forward; slice copies refuse overlap.
			assert(o <= i && i + n <= bytes.length);
			core.stdc.string.memmove(bytes.ptr + o, bytes.ptr + i, n);
			i += n;
			o += n;
			b.remaining -= n;
			if (b.remaining) {
				d.used = i;
				d.produced = o;
				return d;
			}
			b.step = Step.dataEnd;
			break;
		case Step.dataEnd:
			if (bytes.length - i < 2) {
				d.used = i;
				d.produced = o;
				return d;
			}
			if (bytes[i .. i + 2] != "\r\n") goto broken;
			i += 2;
			assert(b.remaining == 0, "bc.http.message: a chunk ended with data left");
			b.step = Step.size;
			break;
		}
	}
broken:
	b = saved;
	return Decoded(0, 0, true);
}

/// Decodes `bytes`, the next received bytes of `b`'s body, in place: the body bytes among them are moved to their start, so chunk framing is removed without a second buffer.
/// It stops where the body ends, leaving any bytes after it unused, and before a partial chunk-size line, which needs more bytes.
///
/// Its `malformed` is set if the chunk framing is broken or a chunk-size or trailer line is longer than `maxLineSize`; `b` is then left where it was.
///
/// Examples:
/// ---
/// char[17] bytes = "3\r\nabc\r\n0\r\n\r\nnext";
/// Body b = Body(Framing.chunked);
/// auto d = decode(b, bytes[]);
/// assert(bytes[0 .. d.produced] == "abc" && d.used == 13 && b.ended);
/// ---
Decoded decode(ref Body b, char[] bytes) @trusted {
	Decoded d;
	final switch (b.framing) {
	case Framing.none:
		break;
	case Framing.close:
		d.used = d.produced = bytes.length;
		break;
	case Framing.length:
		immutable n = b.remaining < bytes.length ? cast(size_t) b.remaining : bytes.length;
		b.remaining -= n;
		if (b.remaining == 0) b.step = Step.done;
		d.used = d.produced = n;
		break;
	case Framing.chunked:
		d = decodeChunked(b, bytes);
		break;
	}
	assert(d.produced <= d.used && d.used <= bytes.length, "bc.http.message: decoding claimed bytes it was not given");
	assert(!ended(b) || b.framing != Framing.length || b.remaining == 0);
	return d;
}


version(unittest) {
	private struct Trickled {
		size_t produced;
		bool malformed, ended;
	}

	// Feeds `text` to a fresh body one byte at a time, as a slow connection would, collecting what it produces into `out_`.
	private Trickled trickle(Framing framing, ulong length, const(char)[] text, ref char[64] out_) {
		Trickled t;
		Body b = Body(framing, length);
		char[64] pending;
		size_t held = 0;
		foreach (c; text) {
			pending[held++] = c;
			auto d = decode(b, pending[0 .. held]);
			if (d.malformed) {
				t.malformed = true;
				return t;
			}
			core.stdc.string.memcpy(out_.ptr + t.produced, pending.ptr, d.produced);
			t.produced += d.produced;
			foreach (k; d.used .. held) pending[k - d.used] = pending[k];
			held -= d.used;
			if (b.ended) break;
		}
		t.ended = b.ended;
		return t;
	}
}

unittest { // names and URLs: case-insensitive names, field validity, and every URL part with its defaults and refusals
	assert(fp.string.ascii.equalIgnoringCase("", "") && !fp.string.ascii.equalIgnoringCase("a", "b") && fp.string.ascii.equalIgnoringCase("ETAG", "etag"));
	assert(validName("a") && !validName("a:b") && !validName("é"));
	assert(validValue("") && validValue("a\tb") && !validValue("a\nb") && !validValue("\x7f"));

	auto u = parseUrl("HTTP://Example.com:81").get;
	assert(u.scheme == "HTTP" && u.host == "Example.com" && u.port == 81 && u.target == "");
	u = parseUrl("http://h?x#y").get;
	assert(u.authority == "h" && u.port == 80 && u.target == "?x");
	assert(parseUrl("ws://h/").get.port == 0);
	assert(parseUrl("http://h:/").get.port == 80);
	assert(parseUrl("http://[::1]").get.host == "::1");
	assert(parseUrl("http://").isNull && parseUrl("http://:80/").isNull && parseUrl("http://h:65536").isNull);
	assert(parseUrl("http://h:8x").isNull && parseUrl("http://[::1/").isNull && parseUrl("http://[::1]x").isNull);
	assert(parseUrl("http://h/a b").isNull && parseUrl("http://h/\r\n").isNull && parseUrl("1http://h").isNull && parseUrl("").isNull);

	static import fp.testing;
	static immutable string[2][4] encoded = [["/odd%2g%2", "/odd%2g%2"], ["%41%62%", "Ab%"], ["%e2%82%AC", "€"], ["plain", "plain"]];
	foreach (pair; encoded) {
		auto decoded = percentDecoded(pair[0]).get;
		scope(exit) fp.string.free(decoded);
		assert(fp.string.slice(decoded) == pair[1]);
	}
	assert(!percentDecoded("").isNull && percentDecoded("").get is null);
	auto previous = fp.testing.limitAllocations(0);
	auto refused = percentDecoded("x");
	fp.testing.restoreAllocator(previous);
	assert(refused.isNull);
}

unittest { // writing requests appends whole lines, and leaves the buffer as it was when growth is refused
	static import fp.testing;
	char* out_ = null;
	scope(exit) fp.dynarray.free(out_);
	assert(writeRequestLine(out_, "GET", "") && writeField(out_, "Host", "h") && endHead(out_));
	assert(fp.dynarray.slice(out_) == "GET / HTTP/1.1\r\nHost: h\r\n\r\n");
	immutable before = fp.dynarray.length(out_);
	auto previous = fp.testing.limitAllocations(0);
	assert(!writeField(out_, "Long", "value that cannot fit in what the array has left"));
	fp.testing.restoreAllocator(previous);
	assert(fp.dynarray.length(out_) == before);
}

unittest { // reading heads: status lines, fields, framing by method, status and fields, interim responses, and malformed heads
	auto h = parseHead("HTTP/1.0 404\r\n\r\n", "GET");
	assert(h.progress == Progress.ok && h.status == 404 && h.reason.length == 0 && h.fields.length == 0 && h.framing == Framing.close);
	h = parseHead("HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-length: 5\r\n\r\nhello", "GET");
	assert(h.framing == Framing.length && h.length == 5 && h.size == 57);
	h = parseHead("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n", "GET");
	assert(h.framing == Framing.chunked);
	assert(parseHead("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n", "GET").framing == Framing.close);
	assert(parseHead("HTTP/1.1 304 Not Modified\r\nContent-Length: 9\r\n\r\n", "GET").framing == Framing.none);
	assert(parseHead("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", "head").framing == Framing.none);
	h = parseHead("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n\r\n", "GET");
	assert(h.status == 100 && h.framing == Framing.none && h.size == 25);

	assert(parseHead("", "GET").progress == Progress.needMore);
	assert(parseHead("HTTP/1.1 200 OK\r\n\r", "GET").progress == Progress.needMore);
	foreach (bad; ["HTTP/1.1 20 OK\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n", "HTTP/1.1 200OK\r\n\r\n", "HTTP/1.1  200\r\n\r\n",
			"HTTP/1.1 200 OK\r\nNoColon\r\n\r\n", "HTTP/1.1 200 OK\r\n Folded: x\r\n\r\n", "HTTP/1.1 200 OK\r\nA: \x01\r\n\r\n", "HTTP/1.1 200 OK\r\nA: x\ry\r\n\r\n", "HTTP/1.1 200 OK\rX\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n"])
		assert(parseHead(bad, "GET").progress == Progress.malformed);

	// A head that never ends stops being waited for once it passes the limit.
	static import fp.dynarray;
	char* big = null;
	scope(exit) fp.dynarray.free(big);
	assert(fp.dynarray.growToSize(big, maxHeadSize + 1) !is null);
	core.stdc.string.memset(big, 'a', maxHeadSize + 1);
	assert(parseHead(big[0 .. maxHeadSize], "GET").progress == Progress.needMore);
	assert(parseHead(big[0 .. maxHeadSize + 1], "GET").progress == Progress.malformed);
}

unittest { // decoding bodies: by length, to the connection's close, and chunked, a byte at a time and with extensions and trailers
	char[64] out_;
	auto t = trickle(Framing.length, 3, "abcdef", out_);
	assert(t.ended && out_[0 .. t.produced] == "abc");
	t = trickle(Framing.close, 0, "abc", out_);
	assert(!t.ended && out_[0 .. t.produced] == "abc");
	t = trickle(Framing.chunked, 0, "4;x=y\r\nWiki\r\nA \r\npedia in\r\n\r\n0\r\nT: 1\r\n\r\nafter", out_);
	assert(t.ended && out_[0 .. t.produced] == "Wikipedia in\r\n");
	t = trickle(Framing.chunked, 0, "1\n!\r\n0\n\n", out_);
	assert(t.ended && out_[0 .. t.produced] == "!");
	t = trickle(Framing.chunked, 0, "2\r\nab", out_);
	assert(!t.ended && !t.malformed && out_[0 .. t.produced] == "ab");
	foreach (bad; ["x\r\n", "\r\n", "3\r\nabcXY", "1x\r\n"]) assert(trickle(Framing.chunked, 0, bad, out_).malformed);

	// A broken chunk leaves the body where the call found it.
	char[11] bytes = "2\r\nab\r\nzz\r\n";
	Body b = Body(Framing.chunked);
	auto d = decode(b, bytes[0 .. 7]);
	assert(d.produced == 2 && d.used == 7);
	immutable before = b;
	assert(decode(b, bytes[7 .. 11]).malformed && b == before);

	// A chunk size too big to count is broken, as is a size line longer than the limit.
	char[19] huge = "10000000000000000\r\n";
	b = Body(Framing.chunked);
	assert(decode(b, huge[]).malformed);
	char[maxLineSize + 2] longLine = '0';
	b = Body(Framing.chunked);
	assert(decode(b, longLine[]).malformed);
}

unittest { // seeded: a chunked body decodes the same whole or split at any bytes, and one with a damaged byte ends the same way either way
	static import fp.algorithms;
	enum size_t most = 1 << 13;
	static char[most] body_, wire, whole, pending, split;
	auto random = fp.algorithms.createRandom(1971);

	// Decodes `wire[0 .. length]` fed in pieces of up to `piece` bytes into `split`, as a connection's reads arrive.
	static Decoded feed(ref fp.algorithms.Random random, size_t length, size_t piece, ref bool ended) {
		Body b = Body(Framing.chunked);
		size_t fed = 0, held = 0, produced = 0;
		while (fed < length && !b.ended) {
			immutable more = 1 + fp.algorithms.randomBelow(random, piece);
			immutable taken = more < length - fed ? more : length - fed;
			core.stdc.string.memcpy(pending.ptr + held, wire.ptr + fed, taken);
			fed += taken;
			held += taken;
			auto d = decode(b, pending[0 .. held]);
			if (d.malformed) return d;
			core.stdc.string.memcpy(split.ptr + produced, pending.ptr, d.produced);
			produced += d.produced;
			core.stdc.string.memmove(pending.ptr, pending.ptr + d.used, held - d.used);
			held -= d.used;
		}
		ended = b.ended;
		return Decoded(fed - held, produced, false);
	}

	size_t damaged = 0, malformed = 0;
	foreach (round; 0 .. 400) {
		size_t length = 0, written = 0;
		foreach (chunk; 0 .. fp.algorithms.randomBelow(random, 6)) {
			immutable size = 1 + fp.algorithms.randomBelow(random, round % 9 == 0 ? 700 : 40);
			char* line = fp.string.format("%zx%s\r\n", size, fp.algorithms.randomChance(random, 1, 4) ? ";name=value".ptr : "".ptr).get(null);
			assert(line !is null);
			core.stdc.string.memcpy(wire.ptr + length, line, fp.string.length(line));
			length += fp.string.length(line);
			fp.string.free(line);
			foreach (i; 0 .. size) body_[written + i] = wire[length + i] = cast(char) ('a' + fp.algorithms.randomBelow(random, 26));
			written += size;
			length += size;
			core.stdc.string.memcpy(wire.ptr + length, "\r\n".ptr, 2);
			length += 2;
		}
		const(char)[] tail = fp.algorithms.randomChance(random, 1, 3) ? "0\r\nTrailer: yes\r\n\r\n" : "0\r\n\r\n";
		core.stdc.string.memcpy(wire.ptr + length, tail.ptr, tail.length);
		length += tail.length;
		immutable intact = !fp.algorithms.randomChance(random, 1, 3);
		if (!intact) {
			++damaged;
			wire[fp.algorithms.randomBelow(random, length)] = "\r\n;0gz "[fp.algorithms.randomBelow(random, 7)];
		}

		core.stdc.string.memcpy(whole.ptr, wire.ptr, length);
		Body b = Body(Framing.chunked);
		immutable once = decode(b, whole[0 .. length]);
		assert(!intact || (!once.malformed && b.ended && once.used == length && whole[0 .. once.produced] == body_[0 .. written]));
		malformed += once.malformed;
		static immutable size_t[3] pieces = [1, 7, 300];
		foreach (piece; pieces) {
			bool ended;
			immutable pieced = feed(random, length, piece, ended);
			assert(pieced.malformed == once.malformed);
			if (once.malformed) continue;
			assert(ended == b.ended && pieced.used == once.used && split[0 .. pieced.produced] == whole[0 .. once.produced]);
		}
	}
	assert(damaged > 50 && malformed > 10 && malformed < damaged);
}
