import type { Context } from "@earendil-works/chord";
import {
	type BinaryReader,
	type DirReader,
	type ExecutionEnv,
	ExecutionError,
	err,
	FileError,
	type FileErrorCode,
	type FileInfo,
	type FileWatcher,
	type LineScan,
	ok,
	type Result,
	type ShellExecOptions,
	type ShellExecResult,
	type TextLine,
	type TextLineReader,
	type WatchChange,
	type WatchTarget,
} from "@earendil-works/pi-durable/env";
import { onCommand, request } from "./bridge.ts";

/**
 * pi-durable `ExecutionEnv` on the app's native `fs` and `shell` services (`FileService.swift`, `ShellService.swift`).
 * Behavior follows pi-durable's `NodeExecutionEnv`: paths resolve against `cwd` (`~` is the workspace home), failures
 * are returned as `FileError`/`ExecutionError`, and `exec` streams output, honors timeouts and aborts, and spills
 * large output to a temporary file.
 */

const MAX_TIMEOUT_MS = 2_147_483_647;
const LINE_CHUNK_BYTES = 64 * 1024;

// ---- paths (POSIX) ----

function normalize(path: string): string {
	const parts: string[] = [];
	for (const part of path.split("/")) {
		if (part === "" || part === ".") continue;
		if (part === "..") parts.pop();
		else parts.push(part);
	}
	return `/${parts.join("/")}`;
}

function join(...parts: string[]): string {
	const joined = parts.filter((part) => part !== "").join("/");
	if (joined === "") return ".";
	const normalized = normalize(joined);
	return joined.startsWith("/") ? normalized : normalized.slice(1) || ".";
}

// ---- native bridge ----

const ERRNO_CODES: Record<string, FileErrorCode> = {
	ENOENT: "not_found",
	EACCES: "permission_denied",
	EPERM: "permission_denied",
	ENOTDIR: "not_directory",
	EISDIR: "is_directory",
	EINVAL: "invalid",
};

/** Native fs failures arrive as `"<ERRNO>: <message>"`. */
function toFileError(error: unknown, path?: string): FileError {
	const message = error instanceof Error ? error.message : String(error);
	const errno = /^(E[A-Z]+): /.exec(message)?.[1];
	return new FileError((errno && ERRNO_CODES[errno]) || "unknown", message, path);
}

async function fs<T>(method: string, params: Record<string, unknown>, path?: string): Promise<Result<T, FileError>> {
	try {
		return ok(await request<T>("fs", method, params));
	} catch (error) {
		return err(toFileError(error, path));
	}
}

function aborted(context: Context, path?: string): Result<never, FileError> | undefined {
	return context.abortSignal?.aborted ? err(new FileError("aborted", "aborted", path)) : undefined;
}

function toBase64(bytes: Uint8Array): string {
	let binary = "";
	for (let index = 0; index < bytes.length; index += 0x8000) {
		binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
	}
	return btoa(binary);
}

function fromBase64(encoded: string): Uint8Array {
	return Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
}

function content(data: string | Uint8Array): Record<string, string> {
	return typeof data === "string" ? { text: data } : { data: toBase64(data) };
}

// ---- shell output routing ----

const outputListeners = new Map<string, (bytes: Uint8Array) => void>();

onCommand("shell.output", ({ id, data }: { id: string; data: string }) => {
	outputListeners.get(id)?.(fromBase64(data));
});

let nextExecId = 0;

class NativeTextLineReader implements TextLineReader {
	private readonly decoder = new TextDecoder();
	private offset = 0;
	private buffered = "";
	private ended = false;
	private closed = false;

	constructor(private readonly path: string) {}

	async readLine(context: Context): Promise<Result<TextLine | undefined, FileError>> {
		const abort = aborted(context, this.path);
		if (abort) return abort;
		if (this.closed) return err(new FileError("invalid", "Text line reader is closed", this.path));
		while (true) {
			const newline = this.buffered.indexOf("\n");
			if (newline !== -1) {
				const text = this.buffered.slice(0, newline);
				this.buffered = this.buffered.slice(newline + 1);
				return ok({ text, terminated: true });
			}
			if (this.ended) {
				if (this.buffered.length === 0) return ok(undefined);
				const text = this.buffered;
				this.buffered = "";
				return ok({ text, terminated: false });
			}
			const chunk = await fs<{ data: string; bytesRead: number }>(
				"read",
				{ path: this.path, offset: this.offset, length: LINE_CHUNK_BYTES },
				this.path,
			);
			if (!chunk.ok) return chunk;
			this.offset += chunk.value.bytesRead;
			if (chunk.value.bytesRead === 0) {
				this.buffered += this.decoder.decode();
				this.ended = true;
			} else {
				this.buffered += this.decoder.decode(fromBase64(chunk.value.data), { stream: true });
			}
		}
	}

	async close(_context: Context): Promise<void> {
		this.closed = true;
		this.buffered = "";
	}
}

/** Positional reads from one opened regular file (the native `read`: offset and length), with its metadata as opened. */
class NativeBinaryReader implements BinaryReader {
	constructor(
		private readonly path: string,
		private readonly opened: FileInfo,
	) {}

	async info(context: Context): Promise<Result<FileInfo, FileError>> {
		return aborted(context, this.path) ?? ok(this.opened);
	}

	async read(offset: number, length: number, context: Context): Promise<Result<Uint8Array, FileError>> {
		const abort = aborted(context, this.path);
		if (abort) return abort;
		if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0) {
			return err(new FileError("invalid", "Offset and length must be non-negative safe integers", this.path));
		}
		if (length === 0) return ok(new Uint8Array(0));
		const read = await fs<{ data: string; bytesRead: number }>("read", { path: this.path, offset, length }, this.path);
		return read.ok ? ok(fromBase64(read.value.data).subarray(0, read.value.bytesRead)) : read;
	}

	/** Lines `[startLine, endLine)`, 0-based: line k starts after the k-th newline byte. */
	async scanLines(options: { startLine: number; endLine?: number }, context: Context): Promise<Result<LineScan, FileError>> {
		const abort = aborted(context, this.path);
		if (abort) return abort;
		const whole = await fs<string>("readBinary", { path: this.path }, this.path);
		if (!whole.ok) return whole;
		const bytes = fromBase64(whole.value);
		const newlines: number[] = [];
		for (let index = 0; index < bytes.length; index++) if (bytes[index] === 10) newlines.push(index);
		const lineStart = (line: number) => (line === 0 ? 0 : newlines[line - 1]! + 1);
		const lineEnd = (line: number) => (line < newlines.length ? newlines[line]! : bytes.length);
		// Sizes as the decoded text has them (TextDecoder drops a byte-order mark at the start of the file).
		const decodedBytes = (from: number, to: number) => new TextEncoder().encode(new TextDecoder().decode(bytes.subarray(from, to))).length;
		const startLine = Math.max(0, Math.floor(options.startLine));
		if (startLine > newlines.length) {
			const end = bytes.length;
			return ok({ newlines: newlines.length, start: end, end, firstLineEnd: end, lastLineStart: end, selectedBytes: 0, firstLineBytes: 0 });
		}
		const start = lineStart(startLine);
		const lastLine = (options.endLine === undefined ? newlines.length + 1 : Math.min(Math.floor(options.endLine), newlines.length + 1)) - 1;
		if (lastLine < startLine) {
			return ok({ newlines: newlines.length, start, end: start, firstLineEnd: start, lastLineStart: start, selectedBytes: 0, firstLineBytes: 0 });
		}
		const end = lineEnd(lastLine);
		const firstLineEnd = lineEnd(startLine);
		return ok({
			newlines: newlines.length,
			start,
			end,
			firstLineEnd,
			lastLineStart: lineStart(lastLine),
			selectedBytes: decodedBytes(start, end),
			firstLineBytes: decodedBytes(start, firstLineEnd),
		});
	}

	async close(): Promise<void> {}
}

/** Pages of one directory listing. */
class ListedDirReader implements DirReader {
	private at = 0;

	constructor(private readonly entries: FileInfo[]) {}

	async next(maxEntries: number, context: Context): Promise<Result<{ entries: FileInfo[]; done: boolean }, FileError>> {
		const abort = aborted(context);
		if (abort) return abort;
		const page = this.entries.slice(this.at, this.at + Math.max(0, Math.floor(maxEntries)));
		this.at += page.length;
		return ok({ entries: page, done: this.at >= this.entries.length });
	}

	async close(): Promise<void> {}
}

export class NativeExecutionEnv implements ExecutionEnv {
	/** Every engine environment sees the app's one file namespace. */
	readonly id = "ios:app";
	cwd: string;
	private readonly home: string;
	private readonly environment: Record<string, string>;
	private readonly running = new Set<string>();

	/** `environment`: variables every command of this environment gets (e.g. a session's HOME and Python env). */
	constructor(options: { cwd: string; home: string; environment?: Record<string, string> }) {
		this.cwd = options.cwd;
		this.home = options.home;
		this.environment = options.environment ?? {};
	}

	private resolve(path: string): string {
		let target = path;
		if (target === "~") target = this.home;
		else if (target.startsWith("~/")) target = join(this.home, target.slice(2));
		else if (target.startsWith("file://")) {
			try {
				target = decodeURIComponent(new URL(target).pathname);
			} catch {
				// Malformed URLs stay ordinary paths, keeping the non-throwing contract.
			}
		}
		return target.startsWith("/") ? normalize(target) : normalize(join(this.cwd, target));
	}

	async absolutePath(path: string, _context: Context): Promise<Result<string, FileError>> {
		return ok(this.resolve(path));
	}

	async joinPath(parts: string[], _context: Context): Promise<Result<string, FileError>> {
		return ok(join(...parts));
	}

	async readTextFile(path: string, context: Context): Promise<Result<string, FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<string>("readText", { path: resolved }, resolved));
	}

	async openTextLineReader(path: string, context: Context): Promise<Result<TextLineReader, FileError>> {
		const resolved = this.resolve(path);
		const abort = aborted(context, resolved);
		if (abort) return abort;
		const info = await this.fileInfo(resolved, context);
		if (!info.ok) return info;
		if (info.value.kind === "directory") return err(new FileError("is_directory", "Is a directory", resolved));
		return ok(new NativeTextLineReader(resolved));
	}

	async readTextLines(
		path: string,
		options: { maxLines?: number } | undefined,
		context: Context,
	): Promise<Result<string[], FileError>> {
		if (options?.maxLines !== undefined && options.maxLines <= 0) return ok([]);
		const opened = await this.openTextLineReader(path, context);
		if (!opened.ok) return opened;
		const lines: string[] = [];
		try {
			while (options?.maxLines === undefined || lines.length < options.maxLines) {
				const line = await opened.value.readLine(context);
				if (!line.ok) return line;
				if (line.value === undefined) break;
				lines.push(line.value.text);
			}
			return ok(lines);
		} finally {
			await opened.value.close(context);
		}
	}

	async readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>> {
		const resolved = this.resolve(path);
		const abort = aborted(context, resolved);
		if (abort) return abort;
		const read = await fs<string>("readBinary", { path: resolved }, resolved);
		return read.ok ? ok(fromBase64(read.value)) : read;
	}

	async writeFile(path: string, data: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<void>("write", { path: resolved, ...content(data) }, resolved));
	}

	async appendFile(path: string, data: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		return (
			aborted(context, resolved) ??
			(await fs<void>("write", { path: resolved, append: true, ...content(data) }, resolved))
		);
	}

	async truncateFile(path: string, size: number, context: Context): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		const abort = aborted(context, resolved);
		if (abort) return abort;
		if (!Number.isSafeInteger(size) || size < 0) {
			return err(new FileError("invalid", "File size must be a non-negative safe integer", resolved));
		}
		return fs<void>("truncate", { path: resolved, size }, resolved);
	}

	async flushFile(path: string, context: Context): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<void>("fsync", { path: resolved }, resolved));
	}

	async renameFile(sourcePath: string, destinationPath: string, context: Context): Promise<Result<void, FileError>> {
		const from = this.resolve(sourcePath);
		const to = this.resolve(destinationPath);
		return aborted(context, to) ?? (await fs<void>("rename", { from, to }, from));
	}

	async fileInfo(path: string, context: Context): Promise<Result<FileInfo, FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<FileInfo>("stat", { path: resolved }, resolved));
	}

	async listDir(path: string, context: Context): Promise<Result<FileInfo[], FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<FileInfo[]>("readdir", { path: resolved }, resolved));
	}

	async openDirReader(path: string, context: Context): Promise<Result<DirReader, FileError>> {
		const listed = await this.listDir(path, context);
		return listed.ok ? ok(new ListedDirReader(listed.value)) : listed;
	}

	/** A regular file for positional reads: a symbolic link is followed, unless `noFollow` (then it's invalid). */
	async openBinaryReader(path: string, options: { noFollow?: boolean } | undefined, context: Context): Promise<Result<BinaryReader, FileError>> {
		const resolved = this.resolve(path);
		let info = await this.fileInfo(resolved, context);
		if (!info.ok) return info;
		let target = resolved;
		if (info.value.kind === "symlink") {
			if (options?.noFollow) return err(new FileError("invalid", "Is a symbolic link", resolved));
			const real = await this.canonicalPath(resolved, context);
			if (!real.ok) return real;
			target = real.value;
			info = await this.fileInfo(target, context);
			if (!info.ok) return info;
		}
		if (info.value.kind === "directory") return err(new FileError("is_directory", "Is a directory", resolved));
		if (info.value.kind !== "file") return err(new FileError("invalid", "Not a regular file", resolved));
		return ok(new NativeBinaryReader(target, info.value));
	}

	/** iOS gives apps no file-change notifications for this: hosts that ask go without watching. */
	async watch(_targets: readonly WatchTarget[], _onChange: (change: WatchChange) => void, context: Context): Promise<Result<FileWatcher, FileError>> {
		return aborted(context) ?? err(new FileError("not_supported", "Watching files isn't supported here"));
	}

	async canonicalPath(path: string, context: Context): Promise<Result<string, FileError>> {
		const resolved = this.resolve(path);
		return aborted(context, resolved) ?? (await fs<string>("realpath", { path: resolved }, resolved));
	}

	async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
		const info = await this.fileInfo(path, context);
		if (info.ok) return ok(true);
		return info.error.code === "not_found" ? ok(false) : err(info.error);
	}

	async createDir(
		path: string,
		options: { recursive?: boolean } | undefined,
		context: Context,
	): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		return (
			aborted(context, resolved) ??
			(await fs<void>("mkdir", { path: resolved, recursive: options?.recursive ?? true }, resolved))
		);
	}

	async remove(
		path: string,
		options: { recursive?: boolean; force?: boolean } | undefined,
		context: Context,
	): Promise<Result<void, FileError>> {
		const resolved = this.resolve(path);
		return (
			aborted(context, resolved) ??
			(await fs<void>(
				"rm",
				{ path: resolved, recursive: options?.recursive ?? false, force: options?.force ?? false },
				resolved,
			))
		);
	}

	async createTempDir(prefix: string | undefined, context: Context): Promise<Result<string, FileError>> {
		return aborted(context) ?? (await fs<string>("mkdtemp", { prefix: prefix ?? "tmp-" }));
	}

	async createTempFile(
		options: { prefix?: string; suffix?: string } | undefined,
		context: Context,
	): Promise<Result<string, FileError>> {
		const directory = await this.createTempDir("tmp-", context);
		if (!directory.ok) return directory;
		const path = join(directory.value, `${options?.prefix ?? ""}${crypto.randomUUID()}${options?.suffix ?? ""}`);
		const created = await fs<void>("write", { path, text: "" }, path);
		return created.ok ? ok(path) : created;
	}

	async exec(
		command: string,
		options: ShellExecOptions | undefined,
		context: Context,
	): Promise<Result<ShellExecResult, ExecutionError>> {
		const signal = context.abortSignal;
		if (signal?.aborted) return err(new ExecutionError("aborted", "aborted"));
		let timeoutMs: number | undefined;
		if (options?.timeout !== undefined) {
			if (!Number.isFinite(options.timeout) || options.timeout <= 0) {
				return err(new ExecutionError("timeout", "Invalid timeout: must be a finite number of seconds"));
			}
			timeoutMs = options.timeout * 1000;
			if (timeoutMs > MAX_TIMEOUT_MS) {
				return err(new ExecutionError("timeout", `Invalid timeout: maximum is ${MAX_TIMEOUT_MS / 1000} seconds`));
			}
		}
		const cwd = options?.cwd ? this.resolve(options.cwd) : this.cwd;
		const cwdInfo = await this.fileInfo(cwd, context);
		if (!cwdInfo.ok || cwdInfo.value.kind !== "directory") {
			return err(new ExecutionError("spawn_error", `Working directory does not exist: ${cwd}\nCannot execute bash commands.`));
		}

		const id = `exec-${++nextExecId}`;
		const decoder = new TextDecoder();
		let settled = false;
		let timedOut = false;
		let callbackError: ExecutionError | undefined;
		const kill = () => void request("shell", "kill", { id }).catch(() => {});

		// Spill: output stays in memory until it crosses a threshold, then all of it goes to a temporary file.
		const spill = options?.spill;
		const prefix: Uint8Array[] = [];
		let seenBytes = 0;
		let seenNewlines = 0;
		let spillPath: string | undefined;
		let spillError: ExecutionError | undefined;
		let spillWrites: Promise<void> = Promise.resolve();
		const writeSpill = (bytes: Uint8Array) => {
			spillWrites = spillWrites.then(async () => {
				if (spillError) return;
				if (spillPath === undefined) {
					const created = await this.createTempFile({ prefix: "pi-output-", suffix: ".log" }, context);
					if (!created.ok) throw created.error;
					spillPath = created.value;
				}
				const appended = await fs<void>("write", { path: spillPath, append: true, data: toBase64(bytes) }, spillPath);
				if (!appended.ok) throw appended.error;
			}).catch((error: unknown) => {
				spillError ??= new ExecutionError("unknown", `Failed to preserve complete shell output: ${String(error)}`);
				kill();
			});
		};

		const emit = (text: string) => {
			if (settled || text === "" || options?.onOutput === undefined || callbackError !== undefined) return;
			try {
				// The shell's output arrives as one stream (stderr with stdout).
				options.onOutput(text, context, { stream: "stdout" });
			} catch (error) {
				callbackError = new ExecutionError("callback_error", String(error));
				kill();
			}
		};

		let spilling = false;
		outputListeners.set(id, (bytes) => {
			emit(decoder.decode(bytes, { stream: true }));
			if (spill === undefined || bytes.length === 0) return;
			if (spilling) {
				writeSpill(bytes);
				return;
			}
			seenBytes += bytes.length;
			for (const byte of bytes) if (byte === 0x0a) seenNewlines++;
			const lines = seenNewlines + (bytes[bytes.length - 1] === 0x0a ? 0 : 1);
			if (seenBytes <= spill.afterBytes && lines <= spill.afterLines) {
				prefix.push(bytes);
				return;
			}
			spilling = true;
			for (const chunk of prefix) writeSpill(chunk);
			prefix.length = 0;
			writeSpill(bytes);
		});

		const timer = timeoutMs === undefined ? undefined : setTimeout(() => ((timedOut = true), kill()), timeoutMs);
		const onAbort = () => kill();
		signal?.addEventListener("abort", onAbort, { once: true });
		this.running.add(id);
		try {
			const { exitCode } = await request<{ exitCode: number }>("shell", "exec", {
				id,
				command,
				cwd,
				env: { ...this.environment, ...options?.env },
			});
			await spillWrites;
			emit(decoder.decode());
			if (callbackError) return err(callbackError);
			const interrupted = timedOut
				? new ExecutionError("timeout", `timeout:${options?.timeout}`)
				: signal?.aborted
					? new ExecutionError("aborted", "aborted")
					: undefined;
			if (interrupted) {
				if (spillPath !== undefined) interrupted.spillPath = spillPath;
				return err(interrupted);
			}
			if (spillError) return err(spillError);
			return ok({ exitCode, ...(spillPath === undefined ? {} : { spillPath }) });
		} catch (error) {
			return err(new ExecutionError("spawn_error", String(error)));
		} finally {
			settled = true;
			if (timer) clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
			outputListeners.delete(id);
			this.running.delete(id);
		}
	}

	async cleanup(_context: Context): Promise<void> {
		for (const id of this.running) void request("shell", "kill", { id }).catch(() => {});
		this.running.clear();
	}
}

