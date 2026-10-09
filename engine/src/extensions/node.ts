/**
 * Node's built-in modules for extension code, over the app's native services: `fs` (synchronous calls through
 * `syncRequest`, the asynchronous forms on top of them), `child_process` (the session's shell), `path`, `os`,
 * `process`, `crypto`, `events`, `util`, `url`, `buffer`, and smaller ones. Modules with nothing to back them on iOS
 * (`http`, `net`, `worker_threads`, ...) load, and fail with a clear message when used, so importing them does not
 * break an extension that never calls them.
 */
import { hmac } from "@noble/hashes/hmac";
import { md5, sha1 } from "@noble/hashes/legacy";
import { sha224, sha256, sha384, sha512 } from "@noble/hashes/sha2";
import { Buffer } from "./buffer-base64url.ts";
import EventEmitter from "events";
import browserPath from "path-browserify";
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import { NativeExecutionEnv } from "../env.ts";
import { syncRequest } from "../sync.ts";

/** Where the code runs: the session's working directory (process.cwd()) and environment. */
export type NodeContext = {
	cwd: string;
	home: string;
	env: Record<string, string>;
	/** The extension's `fetch` (with `clientKey`, net.ts); the engine's when absent. */
	fetch?: typeof fetch;
};

type FileInfo = { name: string; path: string; kind: "file" | "directory" | "symlink"; size: number; mtimeMs: number };
type Require = (specifier: string) => unknown;

export const builtinModuleNames = [
	"assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram",
	"diagnostics_channel", "dns", "events", "fs", "fs/promises", "http", "http2", "https", "inspector", "module", "net",
	"os", "path", "path/posix", "perf_hooks", "process", "querystring", "readline", "readline/promises", "sqlite",
	"stream", "stream/promises", "string_decoder", "timers", "timers/promises", "tls", "tty", "url", "util",
	"util/types", "v8", "vm", "worker_threads", "zlib",
];

export function nodeModules(context: NodeContext, createRequire: (from: string) => Require): Map<string, unknown> {
	const path = pathModule(context);
	const process = processModule(context);
	const fs = fsModule(context, path);
	const modules: Record<string, unknown> = {
		assert: assertModule(),
		async_hooks: asyncHooksModule(),
		buffer: { Buffer, constants: { MAX_LENGTH: 2 ** 31 - 1 }, kMaxLength: 2 ** 31 - 1 },
		child_process: childProcessModule(context),
		console,
		crypto: cryptoModule(),
		events: Object.assign(EventEmitter, { EventEmitter, default: EventEmitter }),
		fs,
		"fs/promises": fs.promises,
		module: {
			createRequire: (from: string | URL) => createRequire(String(from).startsWith("file://") ? decodeURIComponent(new URL(String(from)).pathname) : String(from)),
			builtinModules: builtinModuleNames,
			isBuiltin: (name: string) => builtinModuleNames.includes(name.replace(/^node:/, "")),
		},
		os: osModule(context),
		path,
		"path/posix": path,
		perf_hooks: { performance },
		process,
		querystring: {
			parse: (text: string) => Object.fromEntries(new URLSearchParams(text)),
			stringify: (object: Record<string, string>) => new URLSearchParams(object).toString(),
			escape: encodeURIComponent,
			unescape: decodeURIComponent,
		},
		string_decoder: { StringDecoder },
		timers: { setTimeout, clearTimeout, setInterval, clearInterval, setImmediate: (fn: () => void) => setTimeout(fn, 0), clearImmediate: clearTimeout },
		"timers/promises": {
			setTimeout: (ms: number, value?: unknown) => new Promise((resolve) => setTimeout(() => resolve(value), ms)),
			setImmediate: (value?: unknown) => new Promise((resolve) => setTimeout(() => resolve(value), 0)),
		},
		tty: { isatty: () => false },
		url: urlModule(path),
		util: utilModule(),
		"util/types": utilModule().types,
	};
	for (const name of ["cluster", "dgram", "diagnostics_channel", "dns", "http", "http2", "https", "inspector", "net",
		"readline", "readline/promises", "sqlite", "stream", "stream/promises", "tls", "v8", "vm", "worker_threads", "zlib", "constants"]) {
		modules[name] ??= unavailable(name);
	}
	return new Map(Object.entries(modules));
}

/** A module whose members load but throw when called or constructed. */
function unavailable(name: string): unknown {
	const fail = (member: string) => () => {
		throw new Error(`node:${name} (${member}) is not available in pi on iOS`);
	};
	return new Proxy({}, {
		get: (_, member) => {
			if (member === "__esModule") return false;
			if (typeof member === "symbol") return undefined;
			return new Proxy(fail(member), { construct: () => fail(member)() as never });
		},
	});
}

// ---- path, process, os ----

type PathModule = Omit<typeof browserPath, "posix" | "win32"> & { posix: PathModule; win32: PathModule; default: PathModule; toNamespacedPath: (value: string) => string };

function pathModule(context: NodeContext): PathModule {
	const { posix: _posix, win32: _win32, ...base } = browserPath as typeof browserPath & { posix?: unknown; win32?: unknown };
	const path = {
		...base,
		resolve: (...parts: string[]) => browserPath.resolve(context.cwd, ...parts),
		relative: (from: string, to: string) => browserPath.relative(browserPath.resolve(context.cwd, from), browserPath.resolve(context.cwd, to)),
		toNamespacedPath: (value: string) => value,
	} as PathModule;
	path.posix = path;
	path.win32 = path;
	path.default = path;
	return path;
}

function processModule(context: NodeContext) {
	const process = new EventEmitter() as EventEmitter & Record<string, unknown>;
	const started = performance.now();
	const hrtime = (previous?: [number, number]) => {
		const now = performance.now() * 1e6;
		const seconds = Math.floor(now / 1e9);
		const nanoseconds = Math.floor(now % 1e9);
		if (!previous) return [seconds, nanoseconds];
		const delta = (seconds - previous[0]) * 1e9 + nanoseconds - previous[1];
		return [Math.floor(delta / 1e9), delta % 1e9];
	};
	const stream = (write: (text: string) => void) => ({
		write: (chunk: unknown) => (write(String(chunk)), true),
		isTTY: false,
		columns: 100,
		rows: 40,
		on: () => {},
		once: () => {},
		end: () => {},
	});
	return Object.assign(process, {
		env: context.env,
		argv: ["node", "pi-extension"],
		argv0: "node",
		execArgv: [],
		execPath: "/usr/local/bin/node",
		platform: "darwin",
		arch: "arm64",
		version: "v22.12.0",
		versions: { node: "22.12.0" },
		release: { name: "node" },
		pid: 1,
		ppid: 0,
		title: "pi",
		exitCode: undefined,
		features: {},
		config: { variables: {} },
		cwd: () => context.cwd,
		chdir: (directory: string) => {
			context.cwd = browserPath.resolve(context.cwd, directory);
		},
		exit: (code?: number) => {
			throw new Error(`process.exit(${code ?? 0}) is not available to an extension`);
		},
		kill: () => {
			throw new Error("process.kill is not available in pi on iOS");
		},
		nextTick: (callback: (...args: unknown[]) => void, ...args: unknown[]) => queueMicrotask(() => callback(...args)),
		hrtime: Object.assign(hrtime, { bigint: () => BigInt(Math.round(performance.now() * 1e6)) }),
		uptime: () => (performance.now() - started) / 1000,
		memoryUsage: () => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }),
		cpuUsage: () => ({ user: 0, system: 0 }),
		umask: () => 0o022,
		getuid: () => 501,
		getgid: () => 501,
		geteuid: () => 501,
		emitWarning: (warning: unknown) => console.warn(String(warning)),
		stdout: stream((text) => console.log(text.replace(/\n$/, ""))),
		stderr: stream((text) => console.warn(text.replace(/\n$/, ""))),
		stdin: { isTTY: false, on: () => {}, once: () => {}, resume: () => {}, pause: () => {}, setEncoding: () => {} },
	});
}

function osModule(context: NodeContext) {
	return {
		platform: () => "darwin",
		type: () => "Darwin",
		release: () => "25.0.0",
		version: () => "Darwin Kernel",
		arch: () => "arm64",
		machine: () => "arm64",
		homedir: () => context.home,
		tmpdir: () => context.env.TMPDIR ?? "/tmp",
		hostname: () => "iphone",
		EOL: "\n",
		devNull: "/dev/null",
		endianness: () => "LE",
		cpus: () => [{ model: "Apple", speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } }],
		availableParallelism: () => 1,
		totalmem: () => 4 * 2 ** 30,
		freemem: () => 2 ** 30,
		loadavg: () => [0, 0, 0],
		uptime: () => performance.now() / 1000,
		networkInterfaces: () => ({}),
		userInfo: () => ({ username: "mobile", uid: 501, gid: 501, shell: "/bin/sh", homedir: context.home }),
		constants: { signals: {}, errno: {} },
	};
}

// ---- fs ----

class Stats {
	readonly dev = 1;
	readonly ino = 0;
	readonly mode: number;
	readonly nlink = 1;
	readonly uid = 501;
	readonly gid = 501;
	readonly size: number;
	readonly blksize = 4096;
	readonly blocks: number;
	readonly atimeMs: number;
	readonly mtimeMs: number;
	readonly ctimeMs: number;
	readonly birthtimeMs: number;
	readonly atime: Date;
	readonly mtime: Date;
	readonly ctime: Date;
	readonly birthtime: Date;

	constructor(private readonly info: FileInfo) {
		this.size = info.size;
		this.blocks = Math.ceil(info.size / 512);
		this.mode = info.kind === "directory" ? 0o40755 : info.kind === "symlink" ? 0o120777 : 0o100644;
		this.atimeMs = this.mtimeMs = this.ctimeMs = this.birthtimeMs = info.mtimeMs;
		this.atime = this.mtime = this.ctime = this.birthtime = new Date(info.mtimeMs);
	}

	isFile() { return this.info.kind === "file"; }
	isDirectory() { return this.info.kind === "directory"; }
	isSymbolicLink() { return this.info.kind === "symlink"; }
	isFIFO() { return false; }
	isSocket() { return false; }
	isBlockDevice() { return false; }
	isCharacterDevice() { return false; }
}

class Dirent {
	constructor(readonly name: string, readonly parentPath: string, private readonly kind: string) {}
	get path() { return this.parentPath; }
	isFile() { return this.kind === "file"; }
	isDirectory() { return this.kind === "directory"; }
	isSymbolicLink() { return this.kind === "symlink"; }
	isFIFO() { return false; }
	isSocket() { return false; }
	isBlockDevice() { return false; }
	isCharacterDevice() { return false; }
}

type Encoding = BufferEncoding | null | undefined;
type ReadOptions = Encoding | { encoding?: Encoding; flag?: string };
type WriteOptions = Encoding | { encoding?: Encoding; flag?: string; mode?: number };

function fsModule(context: NodeContext, path: PathModule) {
	const toPath = (value: unknown): string => {
		if (value instanceof URL) return decodeURIComponent(value.pathname);
		const text = Buffer.isBuffer(value) ? value.toString() : String(value);
		return path.resolve(text.startsWith("file://") ? decodeURIComponent(new URL(text).pathname) : text);
	};
	const call = <T>(method: string, params: Record<string, unknown>, syscall: string, target: string): T => {
		try {
			return syncRequest<T>("fs", method, params);
		} catch (error) {
			throw nodeError(error, syscall, target);
		}
	};
	const encodingOf = (options: ReadOptions | WriteOptions): Encoding => (typeof options === "string" || options == null ? (options as Encoding) : options.encoding);

	const statInfo = (target: string, follow: boolean): FileInfo => {
		const info = call<FileInfo>("stat", { path: target }, follow ? "stat" : "lstat", target);
		if (!follow || info.kind !== "symlink") return info;
		return call<FileInfo>("stat", { path: call<string>("realpath", { path: target }, "stat", target) }, "stat", target);
	};

	const sync = {
		existsSync: (value: unknown) => {
			try {
				statInfo(toPath(value), true);
				return true;
			} catch {
				return false;
			}
		},
		statSync: (value: unknown, options?: { throwIfNoEntry?: boolean }) => {
			try {
				return new Stats(statInfo(toPath(value), true));
			} catch (error) {
				if (options?.throwIfNoEntry === false && (error as { code?: string }).code === "ENOENT") return undefined;
				throw error;
			}
		},
		lstatSync: (value: unknown) => new Stats(statInfo(toPath(value), false)),
		accessSync: (value: unknown) => {
			statInfo(toPath(value), true);
		},
		readFileSync: (value: unknown, options?: ReadOptions) => {
			const target = toPath(value);
			const encoding = encodingOf(options ?? null);
			if (encoding === "utf8" || encoding === "utf-8") return call<string>("readText", { path: target }, "open", target);
			const bytes = Buffer.from(call<string>("readBinary", { path: target }, "open", target), "base64");
			return encoding ? bytes.toString(encoding) : bytes;
		},
		writeFileSync: (value: unknown, data: unknown, options?: WriteOptions) => {
			const target = toPath(value);
			const append = typeof options === "object" && options?.flag?.startsWith("a");
			call("write", { path: target, append, ...payload(data, encodingOf(options ?? null)) }, "open", target);
		},
		appendFileSync: (value: unknown, data: unknown, options?: WriteOptions) => {
			const target = toPath(value);
			call("write", { path: target, append: true, ...payload(data, encodingOf(options ?? null)) }, "open", target);
		},
		readdirSync: (value: unknown, options?: Encoding | { withFileTypes?: boolean; recursive?: boolean; encoding?: Encoding }) => {
			const target = toPath(value);
			const withTypes = typeof options === "object" && options?.withFileTypes;
			const recursive = typeof options === "object" && options?.recursive;
			const results: (string | Dirent)[] = [];
			const walk = (directory: string, prefix: string) => {
				for (const entry of call<FileInfo[]>("readdir", { path: directory }, "scandir", directory)) {
					const name = prefix ? `${prefix}/${entry.name}` : entry.name;
					results.push(withTypes ? new Dirent(entry.name, directory, entry.kind) : name);
					if (recursive && entry.kind === "directory") walk(`${directory}/${entry.name}`, name);
				}
			};
			walk(target, "");
			return results;
		},
		mkdirSync: (value: unknown, options?: number | { recursive?: boolean }) => {
			const target = toPath(value);
			const recursive = typeof options === "object" && options?.recursive === true;
			if (!recursive && sync.existsSync(target)) throw nodeError(new Error(`EEXIST: file already exists, mkdir '${target}'`), "mkdir", target);
			call("mkdir", { path: target, recursive: true }, "mkdir", target);
			return recursive ? target : undefined;
		},
		rmSync: (value: unknown, options?: { recursive?: boolean; force?: boolean }) => {
			const target = toPath(value);
			call("rm", { path: target, recursive: options?.recursive ?? false, force: options?.force ?? false }, "rm", target);
		},
		rmdirSync: (value: unknown, options?: { recursive?: boolean }) => {
			const target = toPath(value);
			call("rm", { path: target, recursive: options?.recursive ?? false }, "rmdir", target);
		},
		unlinkSync: (value: unknown) => {
			const target = toPath(value);
			call("rm", { path: target }, "unlink", target);
		},
		renameSync: (from: unknown, to: unknown) => {
			const source = toPath(from);
			call("rename", { from: source, to: toPath(to) }, "rename", source);
		},
		copyFileSync: (from: unknown, to: unknown) => {
			const source = toPath(from);
			const data = call<string>("readBinary", { path: source }, "copyfile", source);
			call("write", { path: toPath(to), data }, "copyfile", source);
		},
		cpSync: (from: unknown, to: unknown, options?: { recursive?: boolean }) => {
			const source = toPath(from);
			const destination = toPath(to);
			if (statInfo(source, true).kind === "directory") {
				if (!options?.recursive) throw nodeError(new Error(`EISDIR: is a directory, cp '${source}'`), "cp", source);
				sync.mkdirSync(destination, { recursive: true });
				for (const name of sync.readdirSync(source) as string[]) sync.cpSync(`${source}/${name}`, `${destination}/${name}`, options);
			} else {
				sync.copyFileSync(source, destination);
			}
		},
		realpathSync: Object.assign((value: unknown) => {
			const target = toPath(value);
			return call<string>("realpath", { path: target }, "realpath", target);
		}, { native: (value: unknown) => sync.realpathSync(value) }),
		mkdtempSync: (prefix: string) => call<string>("mkdtemp", { prefix: browserPath.basename(prefix) }, "mkdtemp", prefix),
		chmodSync: () => {},
		chownSync: () => {},
		utimesSync: () => {},
		symlinkSync: (_: unknown, target: unknown) => {
			throw nodeError(new Error(`EPERM: operation not permitted, symlink '${toPath(target)}'`), "symlink", toPath(target));
		},
		...fileDescriptors(context, (value) => toPath(value), (method, params, syscall, target) => call(method, params, syscall, target)),
	};

	// Callback and promise forms run the synchronous calls (native file operations take microseconds).
	const callbacks: Record<string, unknown> = {};
	const promises: Record<string, unknown> = {};
	for (const [name, fn] of Object.entries(sync)) {
		if (!name.endsWith("Sync") || name === "existsSync") continue;
		const base = name.slice(0, -4);
		callbacks[base] = (...args: unknown[]) => {
			const callback = typeof args.at(-1) === "function" ? (args.pop() as (error: unknown, value?: unknown) => void) : undefined;
			queueMicrotask(() => {
				let result: unknown;
				try {
					result = (fn as (...a: unknown[]) => unknown)(...args);
				} catch (error) {
					return callback?.(error);
				}
				callback?.(null, result);
			});
		};
		promises[base] = async (...args: unknown[]) => (fn as (...a: unknown[]) => unknown)(...args);
	}
	callbacks.exists = (value: unknown, callback: (exists: boolean) => void) => queueMicrotask(() => callback(sync.existsSync(value)));
	promises.open = async (value: unknown, flags = "r") => {
		const fd = sync.openSync(value, flags);
		return {
			fd,
			readFile: (options?: ReadOptions) => sync.readFileSync(value, options),
			writeFile: (data: unknown, options?: WriteOptions) => sync.writeFileSync(value, data, options),
			write: (data: unknown) => ({ bytesWritten: sync.writeSync(fd, data) }),
			read: (buffer: Uint8Array, offset = 0, length = buffer.length, position: number | null = null) => ({ bytesRead: sync.readSync(fd, buffer, offset, length, position), buffer }),
			stat: () => sync.fstatSync(fd),
			close: async () => sync.closeSync(fd),
		};
	};

	const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 512, O_TRUNC: 1024, O_APPEND: 8, COPYFILE_EXCL: 1 };
	const fs = {
		...sync,
		...callbacks,
		promises: { ...promises, constants },
		constants,
		Stats,
		Dirent,
		watch: () => ({ close: () => {}, on: () => {}, unref: () => {} }),
		watchFile: () => {},
		unwatchFile: () => {},
		createReadStream: (value: unknown, options?: ReadOptions) => readStream(() => sync.readFileSync(value, options) as string | Buffer),
		createWriteStream: (value: unknown, options?: { flags?: string }) => writeStream(toPath(value), options?.flags?.startsWith("a") ?? false, sync),
	};
	return Object.assign(fs, { default: fs });
}

function fileDescriptors(
	_context: NodeContext,
	toPath: (value: unknown) => string,
	call: <T>(method: string, params: Record<string, unknown>, syscall: string, target: string) => T,
) {
	const open = new Map<number, { path: string; position: number; append: boolean }>();
	let next = 100;
	const entry = (fd: number) => {
		const file = open.get(fd);
		if (!file) throw nodeError(new Error(`EBADF: bad file descriptor`), "read", String(fd));
		return file;
	};
	return {
		openSync: (value: unknown, flags: string | number = "r") => {
			const target = toPath(value);
			const mode = String(flags);
			if (mode.startsWith("w")) call("write", { path: target, text: "" }, "open", target);
			else if (mode.startsWith("a")) call("write", { path: target, text: "", append: true }, "open", target);
			else call("stat", { path: target }, "open", target);
			const fd = next++;
			open.set(fd, { path: target, position: 0, append: mode.startsWith("a") });
			return fd;
		},
		closeSync: (fd: number) => {
			open.delete(fd);
		},
		fstatSync: (fd: number) => new Stats(call<FileInfo>("stat", { path: entry(fd).path }, "fstat", String(fd))),
		writeSync: (fd: number, data: unknown) => {
			const file = entry(fd);
			const bytes = typeof data === "string" ? Buffer.from(data) : Buffer.from(data as Uint8Array);
			call("write", { path: file.path, data: bytes.toString("base64"), append: true }, "write", file.path);
			return bytes.length;
		},
		readSync: (fd: number, buffer: Uint8Array, offset = 0, length = buffer.length - offset, position: number | null = null) => {
			const file = entry(fd);
			const start = position ?? file.position;
			const { data, bytesRead } = call<{ data: string; bytesRead: number }>("read", { path: file.path, offset: start, length }, "read", file.path);
			buffer.set(Buffer.from(data, "base64"), offset);
			if (position === null) file.position += bytesRead;
			return bytesRead;
		},
	};
}

function readStream(read: () => string | Buffer) {
	const stream = new EventEmitter() as EventEmitter & Record<string, unknown>;
	queueMicrotask(() => {
		try {
			stream.emit("open");
			stream.emit("data", read());
			stream.emit("end");
			stream.emit("close");
		} catch (error) {
			stream.emit("error", error);
		}
	});
	return Object.assign(stream, {
		pipe: (destination: { write: (chunk: unknown) => void; end: () => void }) => {
			stream.on("data", (chunk) => destination.write(chunk));
			stream.on("end", () => destination.end());
			return destination;
		},
		setEncoding: () => stream,
		destroy: () => {},
	});
}

function writeStream(target: string, append: boolean, sync: { writeFileSync: (p: unknown, d: unknown, o?: WriteOptions) => void }) {
	const stream = new EventEmitter() as EventEmitter & Record<string, unknown>;
	let first = !append;
	const write = (chunk: unknown, encoding?: unknown, callback?: () => void) => {
		sync.writeFileSync(target, chunk, { flag: first ? "w" : "a" });
		first = false;
		(typeof encoding === "function" ? encoding : callback)?.();
		return true;
	};
	return Object.assign(stream, {
		write,
		end: (chunk?: unknown, encoding?: unknown, callback?: () => void) => {
			if (chunk !== undefined && typeof chunk !== "function") write(chunk);
			else if (first) sync.writeFileSync(target, "", { flag: "w" });
			queueMicrotask(() => {
				stream.emit("finish");
				stream.emit("close");
			});
			(typeof chunk === "function" ? chunk : typeof encoding === "function" ? encoding : callback)?.();
		},
		destroy: () => {},
		cork: () => {},
		uncork: () => {},
	});
}

function payload(data: unknown, encoding: Encoding): { text: string } | { data: string } {
	if (typeof data === "string") {
		return !encoding || encoding === "utf8" || encoding === "utf-8" ? { text: data } : { data: Buffer.from(data, encoding).toString("base64") };
	}
	if (data instanceof Uint8Array) return { data: Buffer.from(data).toString("base64") };
	if (ArrayBuffer.isView(data)) return { data: Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("base64") };
	return { text: String(data) };
}

/** A Node-style error (code, syscall, path) from a native "ENOENT: ..." message. */
function nodeError(error: unknown, syscall: string, target: string): Error {
	const message = error instanceof Error ? error.message : String(error);
	const code = /^(E[A-Z]+):/.exec(message)?.[1] ?? "EIO";
	const failure = new Error(message) as Error & { code: string; syscall: string; path: string; errno: number };
	failure.code = code;
	failure.syscall = syscall;
	failure.path = target;
	failure.errno = -({ ENOENT: 2, EEXIST: 17, EISDIR: 21, ENOTDIR: 20, EACCES: 13, EPERM: 1, ENOTEMPTY: 66 } as Record<string, number>)[code]! || -5;
	return failure;
}

// ---- child_process ----

function childProcessModule(context: NodeContext) {
	const quote = (word: string) => (/^[\w@%+=:,./-]+$/.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`);
	type Options = { cwd?: string; env?: Record<string, string>; timeout?: number; shell?: boolean | string; encoding?: string };

	const run = (command: string, options: Options = {}) => {
		const child = new EventEmitter() as EventEmitter & Record<string, unknown>;
		const stdout = new EventEmitter() as EventEmitter & Record<string, unknown>;
		const stderr = new EventEmitter() as EventEmitter & Record<string, unknown>;
		for (const stream of [stdout, stderr]) Object.assign(stream, { setEncoding: () => stream, pipe: (d: unknown) => d, resume: () => stream });
		const abort = new AbortController();
		const env = new NativeExecutionEnv({ cwd: options.cwd ? browserPath.resolve(context.cwd, options.cwd) : context.cwd, home: context.home, environment: { ...context.env, ...options.env } });
		const output: Buffer[] = [];
		let settled = false;
		const finished = env
			.exec(
				command,
				{
					timeout: options.timeout ? options.timeout / 1000 : undefined,
					onOutput: (text: string) => {
						const chunk = Buffer.from(text);
						output.push(chunk);
						stdout.emit("data", options.encoding ? text : chunk);
					},
				},
				withAbortSignal(abort.signal, BACKGROUND_CONTEXT),
			)
			.then((result) => {
				settled = true;
				const code = result.ok ? result.value.exitCode : null;
				const signal = result.ok ? null : "SIGTERM";
				child.exitCode = code;
				stdout.emit("end");
				stderr.emit("end");
				child.emit("exit", code, signal);
				child.emit("close", code, signal);
				return { code, signal, output: Buffer.concat(output), error: result.ok ? undefined : result.error };
			});
		return Object.assign(child, {
			pid: 1000 + Math.floor(Math.random() * 1000),
			stdout,
			stderr,
			stdin: { write: () => true, end: () => {}, on: () => {} },
			exitCode: null as number | null,
			killed: false,
			kill: () => {
				if (settled) return false;
				child.killed = true;
				abort.abort();
				return true;
			},
			finished,
		});
	};

	const callbackFor = (child: ReturnType<typeof run>, command: string, options: Options, callback?: (...args: unknown[]) => void) => {
		void child.finished.then(({ code, output, error }) => {
			const text = options.encoding === "buffer" ? output : output.toString();
			if (code === 0) return callback?.(null, text, "");
			const failure = new Error(error ? `Command failed: ${command}\n${error.message}` : `Command failed: ${command}\n${output}`) as Error & Record<string, unknown>;
			Object.assign(failure, { code, killed: child.killed, cmd: command, stdout: text, stderr: "" });
			callback?.(failure, text, "");
		});
	};

	const exec = (command: string, options?: Options | ((...args: unknown[]) => void), callback?: (...args: unknown[]) => void) => {
		const [opts, done] = typeof options === "function" ? [{}, options] : [options ?? {}, callback];
		const child = run(command, opts);
		callbackFor(child, command, opts, done);
		return child;
	};
	const execFile = (file: string, args?: unknown, options?: unknown, callback?: unknown) => {
		const list = Array.isArray(args) ? (args as string[]) : [];
		const rest = [args, options, callback].filter((value) => !Array.isArray(value));
		const opts = (rest.find((value) => value && typeof value === "object") ?? {}) as Options;
		const done = rest.find((value) => typeof value === "function") as ((...args: unknown[]) => void) | undefined;
		const command = [file, ...list].map(quote).join(" ");
		const child = run(command, opts);
		callbackFor(child, command, opts, done);
		return child;
	};
	const spawn = (command: string, args?: string[] | Options, options?: Options) => {
		const [list, opts] = Array.isArray(args) ? [args, options ?? {}] : [[], args ?? {}];
		return run(opts.shell ? [command, ...list].join(" ") : [command, ...list].map(quote).join(" "), opts);
	};
	const notSynchronous = (name: string) => () => {
		throw new Error(`child_process.${name} is not available in pi on iOS (commands run asynchronously): use exec, execFile, spawn, or pi.exec`);
	};
	const promisified = (command: string, options?: Options) =>
		new Promise((resolve, reject) => exec(command, options ?? {}, (error, stdout, stderr) => (error ? reject(error) : resolve({ stdout, stderr }))));
	return {
		exec: Object.assign(exec, { [Symbol.for("nodejs.util.promisify.custom")]: promisified }),
		execFile,
		spawn,
		fork: notSynchronous("fork"),
		execSync: notSynchronous("execSync"),
		execFileSync: notSynchronous("execFileSync"),
		spawnSync: notSynchronous("spawnSync"),
	};
}

// ---- crypto ----

function cryptoModule() {
	const hashes: Record<string, { create: () => { update(data: Uint8Array): unknown; digest(): Uint8Array } }> = {
		md5, sha1, sha224, sha256, sha384, sha512,
	} as never;
	const bytesOf = (data: unknown, encoding?: BufferEncoding) => (typeof data === "string" ? Buffer.from(data, encoding ?? "utf8") : Buffer.from(data as Uint8Array));
	const output = (bytes: Uint8Array, encoding?: BufferEncoding) => (encoding ? Buffer.from(bytes).toString(encoding) : Buffer.from(bytes));
	const createHash = (algorithm: string) => {
		const hash = hashes[algorithm.toLowerCase().replace("-", "")];
		if (!hash) throw new Error(`crypto.createHash: unsupported algorithm ${algorithm}`);
		const state = hash.create();
		const api = {
			update: (data: unknown, encoding?: BufferEncoding) => (state.update(bytesOf(data, encoding)), api),
			digest: (encoding?: BufferEncoding) => output(state.digest(), encoding),
		};
		return api;
	};
	const createHmac = (algorithm: string, key: unknown) => {
		const hash = hashes[algorithm.toLowerCase().replace("-", "")];
		if (!hash) throw new Error(`crypto.createHmac: unsupported algorithm ${algorithm}`);
		const state = hmac.create(hash as never, bytesOf(key));
		const api = {
			update: (data: unknown, encoding?: BufferEncoding) => (state.update(bytesOf(data, encoding)), api),
			digest: (encoding?: BufferEncoding) => output(state.digest(), encoding),
		};
		return api;
	};
	const randomBytes = (size: number, callback?: (error: null, bytes: Buffer) => void) => {
		const bytes = Buffer.alloc(size);
		for (let offset = 0; offset < size; offset += 65536) crypto.getRandomValues(bytes.subarray(offset, Math.min(size, offset + 65536)));
		if (callback) queueMicrotask(() => callback(null, bytes));
		return bytes;
	};
	return {
		createHash,
		createHmac,
		randomBytes,
		randomFillSync: (buffer: Uint8Array<ArrayBuffer>) => crypto.getRandomValues(buffer),
		randomUUID: () => crypto.randomUUID(),
		randomInt: (min: number, max?: number) => {
			const [low, high] = max === undefined ? [0, min] : [min, max];
			return low + Math.floor((crypto.getRandomValues(new Uint32Array(1))[0]! / 2 ** 32) * (high - low));
		},
		getRandomValues: (array: Uint8Array<ArrayBuffer>) => crypto.getRandomValues(array),
		timingSafeEqual: (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((value, index) => value === b[index]),
		getHashes: () => Object.keys(hashes),
		webcrypto: crypto,
		subtle: crypto.subtle,
	};
}

// ---- small modules ----

function urlModule(path: PathModule) {
	return {
		URL,
		URLSearchParams,
		fileURLToPath: (value: string | URL) => decodeURIComponent(new URL(String(value)).pathname),
		pathToFileURL: (value: string) => new URL(`file://${encodeURI(path.resolve(value))}`),
		format: (value: URL | { href?: string }) => (value instanceof URL ? value.href : value.href ?? ""),
		parse: (value: string) => {
			const url = new URL(value, "http://localhost");
			return { href: url.href, protocol: url.protocol, host: url.host, hostname: url.hostname, port: url.port, pathname: url.pathname, search: url.search, query: url.search.slice(1), hash: url.hash };
		},
	};
}

function utilModule() {
	const custom = Symbol.for("nodejs.util.promisify.custom");
	const promisify = (fn: ((...args: unknown[]) => void) & { [custom]?: unknown }) => {
		if (fn[custom]) return fn[custom];
		return (...args: unknown[]) => new Promise((resolve, reject) => fn(...args, (error: unknown, value: unknown) => (error ? reject(error) : resolve(value))));
	};
	const inspect = (value: unknown, _options?: unknown): string => {
		if (typeof value === "string") return `'${value}'`;
		try {
			return JSON.stringify(value, null, 2) ?? String(value);
		} catch {
			return String(value);
		}
	};
	const format = (template: unknown, ...args: unknown[]) => {
		if (typeof template !== "string") return [template, ...args].map((value) => (typeof value === "string" ? value : inspect(value))).join(" ");
		let index = 0;
		const text = template.replace(/%[sdifjoO%]/g, (token) => {
			if (token === "%%") return "%";
			const value = args[index++];
			if (token === "%d" || token === "%i") return String(Number.parseInt(String(value), 10));
			if (token === "%f") return String(Number(value));
			if (token === "%j" || token === "%o" || token === "%O") return inspect(value);
			return String(value);
		});
		return [text, ...args.slice(index).map((value) => (typeof value === "string" ? value : inspect(value)))].join(" ");
	};
	return {
		promisify: Object.assign(promisify, { custom }),
		callbackify: (fn: (...args: unknown[]) => Promise<unknown>) => (...args: unknown[]) => {
			const callback = args.pop() as (error: unknown, value?: unknown) => void;
			fn(...args).then((value) => callback(null, value), (error) => callback(error));
		},
		inherits: (child: { prototype: object }, parent: { prototype: object }) => Object.setPrototypeOf(child.prototype, parent.prototype),
		inspect: Object.assign(inspect, { custom: Symbol.for("nodejs.util.inspect.custom") }),
		format,
		deprecate: <T>(fn: T) => fn,
		debuglog: () => () => {},
		isDeepStrictEqual: (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b),
		stripVTControlCharacters: (text: string) => text.replace(/\u001b\[[0-9;]*[A-Za-z]/g, ""),
		TextEncoder,
		TextDecoder,
		types: {
			isPromise: (value: unknown) => value instanceof Promise,
			isDate: (value: unknown) => value instanceof Date,
			isRegExp: (value: unknown) => value instanceof RegExp,
			isNativeError: (value: unknown) => value instanceof Error,
			isUint8Array: (value: unknown) => value instanceof Uint8Array,
			isArrayBuffer: (value: unknown) => value instanceof ArrayBuffer,
			isAsyncFunction: (value: unknown) => typeof value === "function" && value.constructor.name === "AsyncFunction",
		},
	};
}

function assertModule() {
	const fail = (message?: string) => {
		const error = new Error(message ?? "Assertion failed") as Error & { code: string };
		error.code = "ERR_ASSERTION";
		throw error;
	};
	const assert = (value: unknown, message?: string) => {
		if (!value) fail(message);
	};
	return Object.assign(assert, {
		ok: assert,
		fail,
		equal: (a: unknown, b: unknown, message?: string) => a == b || fail(message ?? `${a} == ${b}`),
		strictEqual: (a: unknown, b: unknown, message?: string) => a === b || fail(message ?? `${a} === ${b}`),
		notStrictEqual: (a: unknown, b: unknown, message?: string) => a !== b || fail(message),
		deepEqual: (a: unknown, b: unknown, message?: string) => JSON.stringify(a) === JSON.stringify(b) || fail(message),
		deepStrictEqual: (a: unknown, b: unknown, message?: string) => JSON.stringify(a) === JSON.stringify(b) || fail(message),
		throws: (fn: () => void, _expected?: unknown, message?: string) => {
			try {
				fn();
			} catch {
				return;
			}
			fail(message ?? "Missing expected exception");
		},
	});
}

function asyncHooksModule() {
	class AsyncLocalStorage<T> {
		private store: T | undefined;
		getStore() { return this.store; }
		run<R>(store: T, callback: (...args: unknown[]) => R, ...args: unknown[]): R {
			const previous = this.store;
			this.store = store;
			try {
				return callback(...args);
			} finally {
				this.store = previous;
			}
		}
		enterWith(store: T) { this.store = store; }
		disable() { this.store = undefined; }
	}
	return { AsyncLocalStorage, AsyncResource: class {} };
}

class StringDecoder {
	private readonly decoder: TextDecoder;
	constructor(encoding: string = "utf8") {
		this.decoder = new TextDecoder(encoding === "utf8" ? "utf-8" : encoding);
	}
	write(bytes: Uint8Array) { return this.decoder.decode(bytes, { stream: true }); }
	end(bytes?: Uint8Array) { return this.decoder.decode(bytes); }
}
