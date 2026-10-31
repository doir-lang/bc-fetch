#!/usr/bin/env python3
"""Builds the unittests for wasm32-wasi, and a reactor module for the main-thread check, and runs them under Node or serves them to a browser, against routes this script serves.

The build links against a wasi-sdk sysroot and compiler-rt builtins, downloaded once into bin/wasi-sdk unless WASI_SYSROOT and WASI_BUILTINS name local copies. It links with `wasm-ld` from PATH (or WASM_LD), falling back to LDC's internal linker.

Usage:
  tools/wasi.py            build bin/wasi/bc-fetch-tests.wasm, bin/wasi/bc-fetch-reactor.wasm and the scripts that run them
  tools/wasi.py --node     ... then run them under Node, exiting with the tests' status
  tools/wasi.py --serve    ... then serve them on http://localhost:8000 to open in a browser
  tools/wasi.py --browser  ... then run them in headless Firefox (or the browser named), exiting with their status
"""
import argparse, glob, http.server, json, os, shutil, subprocess, sys, tarfile, tempfile, threading, time, urllib.parse, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'wasi')
sdk = os.path.join(root, 'bin', 'wasi-sdk')
compiler = os.environ.get('DC', 'ldc2')
tests = os.path.join(out, 'bc-fetch-tests.wasm')
reactor = os.path.join(out, 'bc-fetch-reactor.wasm')

sdkVersion = '34'
release = f'https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{sdkVersion}/'
target = 'wasm32-wasip1'
packages = ['@bjorn3/browser_wasi_shim@0.4.2']


def fetch(name):
	"""Downloads and unpacks a wasi-sdk release archive into bin/wasi-sdk, unless already there, and returns where it unpacked."""
	dest = os.path.join(sdk, name)
	if not os.path.isdir(dest):
		os.makedirs(sdk, exist_ok=True)
		archive = dest + '.tar.gz'
		print(f'downloading {name}', file=sys.stderr)
		urllib.request.urlretrieve(release + name + '.tar.gz', archive)
		with tarfile.open(archive) as tar:
			tar.extractall(sdk, filter='data')
		os.remove(archive)
	return dest


def importPaths():
	result = subprocess.run(['dub', 'describe', '--import-paths', '--compiler=' + compiler], cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(result.stdout + result.stderr)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def link(name, wasm, sources, flags, startup, exports, paths, libs, builtins):
	"""Compiles `sources` with `flags` into one object and links it with the startup file `startup`, exporting `exports`."""
	compile = [compiler, '-mtriple=wasm32-unknown-wasi', '-betterC', '-checkaction=C', *flags, *('-I' + p for p in paths), '-od=' + out, *sources]
	# The long-double archive replaces libc's printf, so it must come first; D's `real` is a 128-bit long double here.
	linkArgs = [os.path.join(libs, startup), '-L' + libs, '-lc-printscan-long-double', '-lc', builtins, *('--export=' + e for e in exports)]
	# A reactor has no `_start`: the host calls `_initialize`, then its exports.
	if '_initialize' in exports:
		linkArgs.append('--no-entry')
	linker = os.environ.get('WASM_LD') or shutil.which('wasm-ld')
	if linker:
		obj = os.path.join(out, name + '.o')
		subprocess.run([*compile, '-c', '-of=' + obj], cwd=root, check=True)
		subprocess.run([linker, '-o', wasm, *linkArgs, obj], cwd=root, check=True)
	else:
		subprocess.run([*compile, '--link-internally', '-of=' + wasm, *('-L' + a for a in linkArgs)], cwd=root, check=True)


def build():
	sysroot = os.environ.get('WASI_SYSROOT') or fetch(f'wasi-sysroot-{sdkVersion}.0')
	builtins = os.environ.get('WASI_BUILTINS') or os.path.join(
		fetch(f'libclang_rt-{sdkVersion}.0'), 'wasm32-unknown-wasip1', 'libclang_rt.builtins.a')
	libs = os.path.join(sysroot, 'lib', target)

	paths = importPaths()
	sources = sorted(glob.glob(os.path.join(root, 'source', 'bc', '**', '*.d'), recursive=True))
	# Import paths outside the root are libfp's, whose modules must be compiled in too, or they would not link.
	dependencies = sorted(f for p in paths if os.path.commonpath([root, os.path.abspath(p)]) != root
		for f in glob.glob(os.path.join(p, '**', '*.d'), recursive=True))
	os.makedirs(out, exist_ok=True)
	link('bc-fetch-tests', tests, [*sources, *dependencies, os.path.join(root, 'tests', 'runner.d')], ['-unittest', '-I' + os.path.join(root, 'tests')],
		'crt1-command.o', ['bc_http_wake'], paths, libs, builtins)
	link('bc-fetch-reactor', reactor, [*sources, *dependencies, os.path.join(root, 'tests', 'wasi', 'reactor.d')], [],
		'crt1-reactor.o', ['_initialize', 'bc_http_wake', 'urlBuffer', 'begin', 'step', 'wakes'], paths, libs, builtins)

	for directory in (os.path.join(root, 'tests', 'wasi'), os.path.join(root, 'js')):
		for f in os.listdir(directory):
			if not f.endswith('.d'):
				shutil.copy(os.path.join(directory, f), out)
	if not all(os.path.isdir(os.path.join(out, 'node_modules', *p.rpartition('@')[0].split('/'))) for p in packages):
		subprocess.run(['npm', 'install', '--no-save', '--no-package-lock', '--prefix', out, *packages], check=True, shell=os.name == 'nt')


stopping = threading.Event()
big = bytes(97 + i % 26 for i in range(3 << 20))
# What the page posts to /result once the tests have run: their status and the lines they wrote.
result = {}
reported = threading.Event()


class Handler(http.server.SimpleHTTPRequestHandler):
	"""Serves bin/wasi cross-origin isolated, without which a browser offers no shared memory, and the routes the tests fetch."""

	def __init__(self, *args, **kwargs):
		super().__init__(*args, directory=out, **kwargs)

	def end_headers(self):
		self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
		self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
		super().end_headers()

	def log_message(self, *args):
		pass

	def respond(self, status, body=b'', headers=()):
		self.send_response(status)
		for name, value in headers:
			self.send_header(name, value)
		self.send_header('Content-Length', str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def route(self):
		"""Answers a test route, or returns False for anything else."""
		path = urllib.parse.urlsplit(self.path).path
		body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
		if path == '/hello':
			self.respond(200, b'hello', [('Content-Type', 'text/plain')])
		elif path == '/echo':
			self.respond(200, self.command.encode() + b' ' + body, [('X-Accept', self.headers.get('Accept', ''))])
		elif path == '/chunks':
			# HTTP/1.0, so the body ends when the connection does, after arriving in two parts.
			self.send_response(200)
			self.end_headers()
			self.wfile.write(b'abc')
			self.wfile.flush()
			time.sleep(0.02)
			self.wfile.write(b'defg')
		elif path == '/big':
			self.respond(200, big)
		elif path == '/redirect':
			self.respond(302, headers=[('Location', '/hello')])
		elif path == '/never':
			stopping.wait()
		elif path == '/result':
			result.update(json.loads(body))
			self.respond(204)
			reported.set()
		else:
			return False
		return True

	def do_GET(self):
		if not self.route():
			super().do_GET()

	def do_POST(self):
		if not self.route():
			self.respond(404)


def serve(port):
	"""Starts serving on a thread and returns the server."""
	server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
	server.daemon_threads = True
	threading.Thread(target=server.serve_forever, daemon=True).start()
	return server


def main():
	parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	mode = parser.add_mutually_exclusive_group()
	mode.add_argument('--node', action='store_true', help='run the tests under Node')
	mode.add_argument('--serve', nargs='?', const=8000, type=int, metavar='PORT', help='serve the test page for a browser')
	mode.add_argument('--browser', nargs='?', const='firefox', metavar='COMMAND', help='run the test page in a headless browser')
	args = parser.parse_args()

	build()
	if args.node:
		server = serve(0)
		url = f'http://127.0.0.1:{server.server_address[1]}'
		code = subprocess.run(['node', os.path.join(out, 'node.mjs'), tests, reactor, url]).returncode
		stopping.set()
		server.shutdown()
		sys.exit(code)
	if args.browser:
		server = serve(0)
		url = f'http://localhost:{server.server_address[1]}/'
		with tempfile.TemporaryDirectory() as profile:
			browser = subprocess.Popen([args.browser, '--headless', '--no-remote', '--profile', profile, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
			finished = reported.wait(300)
			browser.terminate()
			browser.wait()
		stopping.set()
		server.shutdown()
		for line in result.get('lines', []):
			print(line)
		if not finished:
			sys.exit('the page reported no result')
		sys.exit(result['code'])
	if args.serve:
		server = serve(args.serve)
		print(f'open http://localhost:{args.serve}/ to run the tests (Ctrl+C stops the server)', file=sys.stderr)
		try:
			threading.Event().wait()
		except KeyboardInterrupt:
			stopping.set()
			server.shutdown()


if __name__ == '__main__':
	main()
