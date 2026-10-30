/// JSON for `-betterC`, which has no Phobos. A document is a flat array of `Node`s in preorder over the bytes they were read from, so finding a member or an element allocates nothing: `parse` reads one from text, a `Writer` builds one value by value, and `stringify` writes either back out as text.
///
/// Examples:
/// ---
/// static import fp.string;
/// Writer w;
/// scope(exit) free(w);
/// beginObject(w);
/// key(w, "id"); number(w, 1);
/// key(w, "ok"); boolean(w, true);
/// endObject(w);
/// assert(!w.refused && integer(w.document, member(w.document, 0, "id")) == 1);
/// char* text = stringify(w.document);
/// scope(exit) fp.string.free(text);
/// assert(fp.string.slice(text) == `{"id":1,"ok":true}`);
///
/// Document d;
/// scope(exit) free(d);
/// assert(parse(fp.string.slice(text), d) == Parsed.ok);
/// assert(boolean(d, member(d, 0, "ok")));
/// ---
module bc.json;

static import core.stdc.stdlib;
static import fp.dynarray;
static import fp.string;

@nogc nothrow:


// --- documents ---------------------------------------------------------------

/// What a `Node` is.
enum Kind : ubyte { object, array, string_, number, true_, false_, null_ }

/// One value of a document, in preorder: its kind, its bytes in the document's `text`, and the index past its last descendant, so its next sibling is `nodes[i].skip`. An object's members are a key `string_` node followed by its value. A leaf's bytes are its JSON spelling, a string's quotes and escapes included.
struct Node {
	Kind kind; /// What it is.
	uint start; /// Its first byte.
	uint end; /// Past its last byte.
	uint skip; /// The node after its descendants.
}

/// A document: the bytes its nodes refer to and its values in preorder, the first the whole document. Plain data, released by `free`.
///
/// A parsed document's `text` is what was parsed, which must outlive it, and a container's bytes are its JSON text. A built document owns its `text`, which holds its leaves' spellings one after another, so a container's bytes there are not JSON: `stringify` it instead.
struct Document {
	const(char)[] text; /// The bytes the nodes refer to.
	Node* nodes = null; /// An fp dynarray.
	char* owned = null; /// For a built document, the fp string `text` is; null for a parsed one.
}

/// No node: what `member` and `element` give for one that is not there.
enum uint none = uint.max;

/// Releases `d`'s nodes, and its text if it owns it, leaving it empty.
///
/// Examples:
/// ---
/// Document d;
/// cast(void) parse("[1]", d);
/// free(d);
/// assert(d.nodes is null);
/// ---
void free(ref Document d) {
	fp.dynarray.free(d.nodes);
	fp.string.free(d.owned);
	d = Document.init;
}


// --- reading -----------------------------------------------------------------

/// How `parse` went.
enum Parsed : ubyte {
	ok, /// The document is ready.
	malformed, /// The text is not one JSON value.
	refused, /// An allocation was refused.
}

private struct Parse {
	const(char)[] text;
	size_t at;
	Node** nodes;
	bool refused;
	uint depth;
}

private void space(ref Parse p) {
	while (p.at < p.text.length && (p.text[p.at] == ' ' || p.text[p.at] == '\t' || p.text[p.at] == '\n' || p.text[p.at] == '\r')) ++p.at;
}

private bool literal(ref Parse p, const(char)[] word) {
	if (p.text.length - p.at < word.length || p.text[p.at .. p.at + word.length] != word) return false;
	p.at += word.length;
	return true;
}

private bool stringEnd(ref Parse p) {
	++p.at;
	while (p.at < p.text.length) {
		immutable c = p.text[p.at];
		if (c == '"') {
			++p.at;
			return true;
		}
		if (c < 0x20) return false;
		p.at += c == '\\' ? 2 : 1;
	}
	return false;
}

private bool numberEnd(ref Parse p) {
	immutable start = p.at;
	if (p.at < p.text.length && p.text[p.at] == '-') ++p.at;
	immutable digits = p.at;
	while (p.at < p.text.length && ((p.text[p.at] >= '0' && p.text[p.at] <= '9') || p.text[p.at] == '.' || p.text[p.at] == 'e' || p.text[p.at] == 'E' || p.text[p.at] == '+' || p.text[p.at] == '-')) ++p.at;
	return p.at > digits && p.at > start;
}

// One value at `p.at`, appended with its descendants. False if malformed or refused.
private bool value(ref Parse p) {
	space(p);
	if (p.at >= p.text.length || p.depth > 512) return false;
	immutable index = fp.dynarray.length(*p.nodes);
	if (!fp.dynarray.pushBack(*p.nodes, Node(Kind.null_, cast(uint) p.at))) {
		p.refused = true;
		return false;
	}
	immutable c = p.text[p.at];
	Kind kind;
	if (c == '{' || c == '[') {
		kind = c == '{' ? Kind.object : Kind.array;
		++p.at;
		++p.depth;
		scope(exit) --p.depth;
		space(p);
		immutable close = c == '{' ? '}' : ']';
		if (p.at < p.text.length && p.text[p.at] == close) ++p.at;
		else for (;;) {
			if (kind == Kind.object) {
				space(p);
				if (p.at >= p.text.length || p.text[p.at] != '"' || !value(p)) return false;
				space(p);
				if (p.at >= p.text.length || p.text[p.at] != ':') return false;
				++p.at;
			}
			if (!value(p)) return false;
			space(p);
			if (p.at >= p.text.length) return false;
			if (p.text[p.at] == ',') { ++p.at; continue; }
			if (p.text[p.at] != close) return false;
			++p.at;
			break;
		}
	} else if (c == '"') {
		kind = Kind.string_;
		if (!stringEnd(p)) return false;
	} else if (literal(p, "true")) kind = Kind.true_;
	else if (literal(p, "false")) kind = Kind.false_;
	else if (literal(p, "null")) kind = Kind.null_;
	else if (numberEnd(p)) kind = Kind.number;
	else return false;
	auto node = &(*p.nodes)[index];
	node.kind = kind;
	node.end = cast(uint) p.at;
	node.skip = cast(uint) fp.dynarray.length(*p.nodes);
	return true;
}

/// Parses `text`, one JSON value with whitespace around it, into `out_`, which must be empty and must not outlive `text`.
///
/// Returns `Parsed.ok`, or `Parsed.malformed` or `Parsed.refused` having left `out_` empty.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`{"a":[1,2,{"b":null}]}`, d) == Parsed.ok);
/// assert(length(d, member(d, 0, "a")) == 3);
/// Document bad;
/// assert(parse(`{"a":}`, bad) == Parsed.malformed);
/// ---
Parsed parse(const(char)[] text, ref Document out_) {
	assert(out_.nodes is null && text.length < uint.max);
	Parse p = Parse(text, 0, &out_.nodes);
	immutable ok = value(p);
	space(p);
	if (ok && p.at == text.length) {
		out_.text = text;
		return Parsed.ok;
	}
	free(out_);
	return p.refused ? Parsed.refused : Parsed.malformed;
}

/// The value of member `name` of object node `object`, or `none` if it has none or is not an object. Keys are compared as written, escapes and all.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`{"a":1,"b":2}`, d) == Parsed.ok);
/// assert(integer(d, member(d, 0, "b")) == 2 && member(d, 0, "c") == none);
/// ---
uint member(ref const Document d, uint object, const(char)[] name) {
	if (object == none || d.nodes[object].kind != Kind.object) return none;
	for (uint k = object + 1; k < d.nodes[object].skip; k = d.nodes[d.nodes[k].skip].skip) {
		immutable key = d.nodes[k];
		if (d.text[key.start + 1 .. key.end - 1] == name) return key.skip;
	}
	return none;
}

/// Element `i` of array node `array`, or `none` past its end or if it is not an array.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`[10,20]`, d) == Parsed.ok);
/// assert(integer(d, element(d, 0, 1)) == 20 && element(d, 0, 2) == none);
/// ---
uint element(ref const Document d, uint array, size_t i) {
	if (array == none || d.nodes[array].kind != Kind.array) return none;
	uint e = array + 1;
	foreach (_; 0 .. i) {
		if (e >= d.nodes[array].skip) return none;
		e = d.nodes[e].skip;
	}
	return e < d.nodes[array].skip ? e : none;
}

/// The number of elements of array node `array`; 0 if it is not one.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`[[],{}]`, d) == Parsed.ok);
/// assert(length(d, 0) == 2 && length(d, 1) == 0);
/// ---
size_t length(ref const Document d, uint array) {
	if (array == none || d.nodes[array].kind != Kind.array) return 0;
	size_t n = 0;
	for (uint e = array + 1; e < d.nodes[array].skip; e = d.nodes[e].skip) ++n;
	return n;
}

/// The text of node `n` as written: what `raw` writes back.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`{"id": "x"}`, d) == Parsed.ok);
/// assert(text(d, member(d, 0, "id")) == `"x"`);
/// ---
const(char)[] text(ref const Document d, uint n) {
	return n == none ? null : d.text[d.nodes[n].start .. d.nodes[n].end];
}

/// Node `n`'s value as an integer, or `fallback` if it is not a number or does not fit.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`[-7, "x"]`, d) == Parsed.ok);
/// assert(integer(d, element(d, 0, 0)) == -7 && integer(d, element(d, 0, 1), 3) == 3);
/// ---
long integer(ref const Document d, uint n, long fallback = 0) {
	if (n == none || d.nodes[n].kind != Kind.number) return fallback;
	auto s = text(d, n);
	immutable negative = s.length && s[0] == '-';
	ulong v = 0;
	foreach (c; s[negative .. $]) {
		if (c < '0' || c > '9' || v > long.max / 10) return fallback;
		v = v * 10 + (c - '0');
	}
	return negative ? -cast(long) v : cast(long) v;
}

/// Whether node `n` is `true`.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`[true,1]`, d) == Parsed.ok);
/// assert(boolean(d, element(d, 0, 0)) && !boolean(d, element(d, 0, 1)));
/// ---
bool boolean(ref const Document d, uint n) {
	return n != none && d.nodes[n].kind == Kind.true_;
}

private uint hexDigits(const(char)[] s, size_t at) {
	uint v = 0;
	foreach (c; s[at .. at + 4]) {
		v <<= 4;
		if (c >= '0' && c <= '9') v |= c - '0';
		else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
		else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
		else return uint.max;
	}
	return v;
}

/// String node `n`'s value with its escapes decoded, `\u` surrogate pairs included, as a new fp string the caller frees; an empty string is null. Anything not a string is empty too.
///
/// Returns null as well if allocation is refused; `refused` says which.
///
/// Examples:
/// ---
/// static import fp.string;
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`"a\nbé😀"`, d) == Parsed.ok);
/// bool refused;
/// auto s = string_(d, 0, refused);
/// scope(exit) fp.string.free(s);
/// assert(fp.string.slice(s) == "a\nbé\U0001F600");
/// ---
char* string_(ref const Document d, uint n, out bool refused) {
	if (n == none || d.nodes[n].kind != Kind.string_) return null;
	auto s = d.text[d.nodes[n].start + 1 .. d.nodes[n].end - 1];
	char* out_ = null;
	bool add(const(char)[] piece) {
		if (piece.length == 0 || fp.string.concatenate(out_, piece) !is null) return true;
		refused = true;
		fp.string.free(out_);
		return false;
	}
	size_t from = 0, i = 0;
	while (i < s.length) {
		if (s[i] != '\\') { ++i; continue; }
		if (!add(s[from .. i])) return null;
		immutable c = i + 1 < s.length ? s[i + 1] : '\\';
		char[4] encoded;
		const(char)[] piece;
		i += 2;
		switch (c) {
			case 'n': piece = "\n"; break;
			case 'r': piece = "\r"; break;
			case 't': piece = "\t"; break;
			case 'b': piece = "\b"; break;
			case 'f': piece = "\f"; break;
			case 'u':
				uint code = i + 4 <= s.length ? hexDigits(s, i) : uint.max;
				if (code != uint.max) i += 4;
				else code = 0xFFFD;
				if (code >= 0xD800 && code < 0xDC00 && i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u') {
					immutable low = hexDigits(s, i + 2);
					if (low >= 0xDC00 && low < 0xE000) {
						code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
						i += 6;
					}
				}
				if (code >= 0xD800 && code < 0xE000) code = 0xFFFD;
				piece = encoded[0 .. fp.string.encodeUtf8(code, encoded.ptr)];
				break;
			default:
				encoded[0] = c;
				piece = encoded[0 .. 1];
		}
		if (!add(piece)) return null;
		from = i;
	}
	if (!add(s[from .. $])) return null;
	return out_;
}

// --- building ----------------------------------------------------------------

private enum size_t maxDepth = 64;

/// A document being built, one value at a time, in the order its text would spell them: open a container, write its values, a key before each of an object's, and close it. A refused allocation sets `refused` and every later call does nothing, so a caller checks once at the end. Plain data, released by `free`.
struct Writer {
	Document document; /// What is built so far; complete once every container is closed.
	bool refused; /// Whether an allocation was refused.
	private uint[maxDepth] open; // the node of each container still open
	private size_t depth;
	private bool afterKey;
}

/// Releases `w`'s document, leaving it empty.
///
/// Examples:
/// ---
/// Writer w;
/// boolean(w, false);
/// free(w);
/// assert(w.document.nodes is null);
/// ---
void free(ref Writer w) {
	free(w.document);
	w = Writer.init;
}

// Checks where a value may go: after its key in an object, anywhere else in an array, or as the whole document.
private void placeValue(ref Writer w) {
	// Once refused, open containers may have no node to check against.
	if (w.refused) return;
	if (w.depth && w.document.nodes[w.open[w.depth - 1]].kind == Kind.object) assert(w.afterKey, "bc.json: an object's value needs a key first");
	else assert(w.depth || fp.dynarray.length(w.document.nodes) == 0, "bc.json: a document holds one value");
	w.afterKey = false;
}

// Appends a node of `kind` whose bytes are `pieces` run together; its `skip` is set by `close` for a container. False once refused.
private bool add(ref Writer w, Kind kind, const(char)[][] pieces...) @trusted {
	if (w.refused) return false;
	immutable start = fp.string.length(w.document.owned);
	foreach (piece; pieces)
		if (piece.length && fp.string.concatenate(w.document.owned, piece) is null) {
			w.refused = true;
			return false;
		}
	immutable end = fp.string.length(w.document.owned);
	assert(end < uint.max, "bc.json: document too large");
	immutable index = cast(uint) fp.dynarray.length(w.document.nodes);
	if (!fp.dynarray.pushBack(w.document.nodes, Node(kind, cast(uint) start, cast(uint) end, index + 1))) {
		w.refused = true;
		return false;
	}
	w.document.text = fp.string.slice(w.document.owned);
	return true;
}

private void open(ref Writer w, Kind kind) {
	placeValue(w);
	assert(w.depth < maxDepth, "bc.json: nested too deeply");
	immutable index = cast(uint) fp.dynarray.length(w.document.nodes);
	if (add(w, kind)) w.open[w.depth] = index;
	++w.depth;
}

private void close(ref Writer w, Kind kind) {
	assert(w.depth, "bc.json: nothing open to close");
	--w.depth;
	if (w.refused) return;
	assert(!w.afterKey, "bc.json: a key has no value");
	auto node = &w.document.nodes[w.open[w.depth]];
	assert(node.kind == kind, "bc.json: closed the wrong kind of container");
	node.end = cast(uint) fp.string.length(w.document.owned);
	node.skip = cast(uint) fp.dynarray.length(w.document.nodes);
}

/// Opens an object; close it with `endObject`.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// beginObject(w);
/// endObject(w);
/// assert(w.document.nodes[0].kind == Kind.object);
/// ---
void beginObject(ref Writer w) { open(w, Kind.object); }

/// Closes the object `beginObject` opened.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// beginObject(w);
/// endObject(w);
/// assert(!w.refused);
/// ---
void endObject(ref Writer w) { close(w, Kind.object); }

/// Opens an array; close it with `endArray`.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// beginArray(w);
/// number(w, 1);
/// number(w, 2);
/// endArray(w);
/// assert(length(w.document, 0) == 2);
/// ---
void beginArray(ref Writer w) { open(w, Kind.array); }

/// Closes the array `beginArray` opened.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// beginArray(w);
/// endArray(w);
/// assert(length(w.document, 0) == 0);
/// ---
void endArray(ref Writer w) { close(w, Kind.array); }

// Adds `s` as a string node, quoted and escaped.
private void quoted(ref Writer w, const(char)[] s) {
	if (!add(w, Kind.string_, "\"")) return;
	size_t from = 0;
	bool put(const(char)[] piece) {
		if (piece.length == 0 || fp.string.concatenate(w.document.owned, piece) !is null) return true;
		w.refused = true;
		return false;
	}
	foreach (i, c; s) {
		const(char)[] escape;
		char[6] unicode;
		switch (c) {
			case '"': escape = "\\\""; break;
			case '\\': escape = "\\\\"; break;
			case '\n': escape = "\\n"; break;
			case '\r': escape = "\\r"; break;
			case '\t': escape = "\\t"; break;
			default:
				if (c >= 0x20) continue;
				static immutable hex = "0123456789abcdef";
				unicode = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]];
				escape = unicode[];
		}
		if (!put(s[from .. i]) || !put(escape)) return;
		from = i + 1;
	}
	if (!put(s[from .. $]) || !put("\"")) return;
	immutable end = fp.string.length(w.document.owned);
	assert(end < uint.max, "bc.json: document too large");
	w.document.nodes[fp.dynarray.length(w.document.nodes) - 1].end = cast(uint) end;
	w.document.text = fp.string.slice(w.document.owned);
}

/// Writes an object member's key; its value follows.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// beginObject(w);
/// key(w, "a"); null_(w);
/// endObject(w);
/// assert(member(w.document, 0, "a") == 2);
/// ---
void key(ref Writer w, const(char)[] name) {
	if (w.refused) return;
	assert(w.depth && w.document.nodes[w.open[w.depth - 1]].kind == Kind.object && !w.afterKey, "bc.json: a key goes only before an object's value");
	quoted(w, name);
	w.afterKey = true;
}

/// Writes `s` as a string, escaped.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// string_(w, "a\"b\n");
/// assert(text(w.document, 0) == `"a\"b\n"`);
/// ---
void string_(ref Writer w, const(char)[] s) {
	placeValue(w);
	quoted(w, s);
}

/// Writes an integer.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// number(w, -42);
/// assert(integer(w.document, 0) == -42);
/// ---
void number(ref Writer w, long n) {
	placeValue(w);
	char[24] buffer;
	size_t at = buffer.length;
	immutable negative = n < 0;
	ulong v = negative ? -cast(ulong) n : n;
	do {
		buffer[--at] = cast(char) ('0' + v % 10);
		v /= 10;
	} while (v);
	if (negative) buffer[--at] = '-';
	cast(void) add(w, Kind.number, buffer[at .. $]);
}

/// Writes `true` or `false`.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// boolean(w, true);
/// assert(boolean(w.document, 0));
/// ---
void boolean(ref Writer w, bool b) {
	placeValue(w);
	cast(void) add(w, b ? Kind.true_ : Kind.false_, b ? "true" : "false");
}

/// Writes `null`.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// null_(w);
/// assert(w.document.nodes[0].kind == Kind.null_);
/// ---
void null_(ref Writer w) {
	placeValue(w);
	cast(void) add(w, Kind.null_, "null");
}

/// Writes a copy of node `n` of `from`, with its descendants: part of a request echoed in its response.
///
/// Examples:
/// ---
/// Document request;
/// scope(exit) free(request);
/// assert(parse(`{"id": [1, "x"]}`, request) == Parsed.ok);
/// Writer w;
/// scope(exit) free(w);
/// copy(w, request, member(request, 0, "id"));
/// assert(length(w.document, 0) == 2 && text(w.document, 2) == `"x"`);
/// ---
void copy(ref Writer w, ref const Document from, uint n) {
	assert(n != none && n < fp.dynarray.length(from.nodes), "bc.json: no such node to copy");
	placeValue(w);
	immutable first = cast(uint) fp.dynarray.length(w.document.nodes);
	foreach (k; n .. from.nodes[n].skip) {
		immutable node = from.nodes[k];
		immutable container = node.kind == Kind.object || node.kind == Kind.array;
		if (!add(w, node.kind, container ? null : from.text[node.start .. node.end])) return;
		w.document.nodes[first + k - n].skip = first + node.skip - n;
	}
	// A container's bytes end where its last descendant's do, as a built one's do; descendants come later, so go backwards.
	foreach_reverse (k; first .. fp.dynarray.length(w.document.nodes)) {
		auto node = &w.document.nodes[k];
		if ((node.kind == Kind.object || node.kind == Kind.array) && node.skip > k + 1) node.end = w.document.nodes[node.skip - 1].end;
	}
}

/// Writes `json`, which must be one JSON value: `copy` from text rather than from a document.
///
/// Examples:
/// ---
/// Writer w;
/// scope(exit) free(w);
/// raw(w, `"req-1"`);
/// assert(text(w.document, 0) == `"req-1"`);
/// ---
void raw(ref Writer w, const(char)[] json) {
	if (w.refused) return;
	Document d;
	scope(exit) free(d);
	immutable parsed = parse(json, d);
	assert(parsed != Parsed.malformed, "bc.json: raw text is not one JSON value");
	if (parsed == Parsed.refused) {
		w.refused = true;
		return;
	}
	copy(w, d, 0);
}


// --- printing ----------------------------------------------------------------

// Appends node `n` of `d` and its descendants as compact JSON. False if refused.
private bool print(ref const Document d, uint n, ref char* out_) {
	immutable node = d.nodes[n];
	if (node.kind != Kind.object && node.kind != Kind.array) return fp.string.concatenate(out_, d.text[node.start .. node.end]) !is null;
	immutable object = node.kind == Kind.object;
	if (fp.string.append(out_, object ? '{' : '[') is null) return false;
	for (uint k = n + 1; k < node.skip; k = d.nodes[k].skip) {
		if (k > n + 1 && fp.string.append(out_, ',') is null) return false;
		if (object) {
			if (!print(d, k, out_) || fp.string.append(out_, ':') is null) return false;
			k = d.nodes[k].skip;
		}
		if (!print(d, k, out_)) return false;
	}
	return fp.string.append(out_, object ? '}' : ']') !is null;
}

/// `d` as compact JSON text, a new fp string the caller frees: what a `Writer` built, or what `parse` read without its whitespace.
///
/// Returns null if an allocation is refused or `d` is empty.
///
/// Examples:
/// ---
/// static import fp.string;
/// Document d;
/// scope(exit) free(d);
/// assert(parse(`{ "a" : [1, 2], "b": "x" }`, d) == Parsed.ok);
/// char* text = stringify(d);
/// scope(exit) fp.string.free(text);
/// assert(fp.string.slice(text) == `{"a":[1,2],"b":"x"}`);
/// ---
char* stringify(ref const Document d) {
	if (fp.dynarray.length(d.nodes) == 0) return null;
	char* out_ = null;
	if (print(d, 0, out_)) return out_;
	fp.string.free(out_);
	return null;
}


unittest { // a built document reads as a parsed one does, nests and escapes, and prints as JSON that parses back to the same values
	Writer w;
	scope(exit) free(w);
	beginObject(w);
	key(w, "list"); beginArray(w); number(w, 0); string_(w, "\x01\"\\\n\r\t"); beginObject(w); endObject(w); endArray(w);
	key(w, "n"); null_(w);
	key(w, "b"); boolean(w, false);
	key(w, "copied"); raw(w, `{"x": [true, false], "y": {}}`);
	endObject(w);
	assert(!w.refused);
	immutable list = member(w.document, 0, "list");
	assert(length(w.document, list) == 3 && w.document.nodes[element(w.document, list, 2)].kind == Kind.object);
	assert(member(w.document, 0, "n") != none && member(w.document, 0, "missing") == none);
	assert(w.document.nodes[member(w.document, 0, "b")].kind == Kind.false_);
	bool refused;
	auto s = string_(w.document, element(w.document, list, 1), refused);
	scope(exit) fp.string.free(s);
	assert(fp.string.slice(s) == "\x01\"\\\n\r\t" && !refused);
	immutable copied = member(w.document, 0, "copied");
	assert(boolean(w.document, element(w.document, member(w.document, copied, "x"), 0)) && member(w.document, copied, "y") != none);
	char* printed = stringify(w.document);
	scope(exit) fp.string.free(printed);
	assert(fp.string.slice(printed) == `{"list":[0,"\u0001\"\\\n\r\t",{}],"n":null,"b":false,"copied":{"x":[true,false],"y":{}}}`);

	Document d;
	scope(exit) free(d);
	assert(parse(fp.string.slice(printed), d) == Parsed.ok);
	assert(fp.dynarray.length(d.nodes) == fp.dynarray.length(w.document.nodes));
	foreach (i; 0 .. fp.dynarray.length(d.nodes)) {
		assert(d.nodes[i].kind == w.document.nodes[i].kind && d.nodes[i].skip == w.document.nodes[i].skip);
		if (d.nodes[i].kind != Kind.object && d.nodes[i].kind != Kind.array) assert(text(d, cast(uint) i) == text(w.document, cast(uint) i));
	}

	foreach (bad; [`{`, `[1,]`, `{"a" 1}`, `"open`, `tru`, `1 2`, ``, `{"a":1,}`]) {
		Document b;
		assert(parse(bad, b) == Parsed.malformed && b.nodes is null);
	}

	// A refusal at any step sets `refused` and builds nothing further.
	static import fp.testing;
	for (size_t budget = 0;; ++budget) {
		Writer r;
		auto previous = fp.testing.beginRationedAllocator(budget);
		beginObject(r); key(r, "k"); string_(r, "a\tbcdefghijklmnopqrstuvwxyz"); key(r, "r"); raw(r, `[1]`); endObject(r);
		char* result = r.refused ? null : stringify(r.document);
		fp.testing.endRationedAllocator(previous);
		free(r);
		if (result is null) continue;
		assert(fp.string.slice(result) == `{"k":"a\tbcdefghijklmnopqrstuvwxyz","r":[1]}`);
		fp.string.free(result);
		break;
	}

	// Integers that are not numbers, have fractions, or do not fit give the fallback.
	Document numbers;
	scope(exit) free(numbers);
	assert(parse(`[12, -7, 1.5, 99999999999999999999, "x"]`, numbers) == Parsed.ok);
	assert(integer(numbers, element(numbers, 0, 0)) == 12 && integer(numbers, element(numbers, 0, 1)) == -7);
	foreach (i; 2 .. 6) assert(integer(numbers, element(numbers, 0, i), 3) == 3);

	// Escapes decode, a surrogate pair to one character, and a broken `\u` or lone surrogate to U+FFFD.
	Document escaped;
	scope(exit) free(escaped);
	assert(parse(`"\u00e9\u00C9\uZZZZ\ud83d\ude00\ud83d\u0041\ude00\/\"\\\n\r\t\b\f"`, escaped) == Parsed.ok);
	auto decoded = string_(escaped, 0, refused);
	scope(exit) fp.string.free(decoded);
	assert(!refused && fp.string.slice(decoded) == "éÉ\uFFFDZZZZ\U0001F600\uFFFDA\uFFFD/\"\\\n\r\t\b\f");
	auto previous = fp.testing.beginRationedAllocator(0);
	assert(string_(escaped, 0, refused) is null && refused);
	fp.testing.endRationedAllocator(previous);
}
