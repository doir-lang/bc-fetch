# bc-fetch

JSON and JSON-RPC for `-betterC` D, which has no Phobos, on [libfp](https://github.com/doir-lang/libfp).

- `bc.json` — a `Writer` that appends a JSON document to an fp string, and `parse`, which reads one into a flat array of nodes in preorder, so finding a member or an element allocates nothing.
- `bc.jsonrpc` — JSON-RPC messages framed by `Content-Length` headers over file descriptors, as Language Server Protocol clients speak over a server's stdin and stdout.

Call these modules' functions fully qualified, as in `bc.json.parse(text, d)` or `bc.jsonrpc.send(fd, body)`: both define `free`.
They share package `bc` with [bc-threads](https://github.com/doir-lang/bc-threads).

## Building

```sh
dub build --config=library --compiler=ldc2   # static library
dub test --compiler=ldc2                     # build and run the unittests
python3 tools/doctest.py                     # compile and run every DDoc example
```

LDC only: libfp, which this depends on, refuses DMD at compile time, so `dub.json` declares DMD unsupported.

## Testing

`-betterC` has no unittest runner of its own, so [tests/runner.d](tests/runner.d) walks each `bc` module with `__traits(getUnitTests)` and calls the tests itself, reporting each module and test index to `stderr` as it goes.
