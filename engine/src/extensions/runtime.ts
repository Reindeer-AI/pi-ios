/**
 * A module system for extension code, like the jiti loader pi uses on Node: each file is transpiled by esbuild
 * (WebAssembly; TypeScript, JSX, ES modules) and runs with its own `require`, `module`, `__filename`, and `__dirname`.
 * Specifiers resolve as in Node (relative files, `node_modules`, package.json `exports`), except pi's own packages,
 * which are the engine's (`hostModules`), and Node's built-ins, which are shims over native services (`node.ts`).
 *
 * Files run as CommonJS, so `require` works everywhere and every module shares one registry. A file with top-level
 * `await` (which CommonJS cannot express) runs as a native ES module instead: from a blob URL, with its imports
 * pointing at blob URLs too, either other such modules or facades that re-export a CommonJS module's exports.
 * `import()` goes through the module system in both kinds, so it loads either kind and, as in Node, rejects (rather
 * than failing the whole file) when a module is missing.
 *
 * `require` is synchronous and esbuild in WebKit is not, so `prepare()` first walks the module graph from an entry
 * (transpiling each file and following its literal `require`s and imports); `load()` then runs it. A file only
 * reached at run time loads as plain JavaScript through `require`, or is transpiled first through `import()`.
 *
 * Transpiled files are kept between launches (`setTranspileCache`), by a hash of their source: starting esbuild's
 * WebAssembly and transpiling every file took most of a second of each launch.
 */
import { Buffer } from "./buffer-base64url.ts";
import * as esbuild from "esbuild-wasm";
import { init as initializeLexer, parse as parseImports } from "es-module-lexer";
import { syncRequest } from "../sync.ts";
import { builtinModuleNames, type NodeContext, nodeModules } from "./node.ts";

type Module = { exports: unknown; loaded: boolean; id: string; filename: string; children: Module[]; paths: string[] };
type FileInfo = { kind: "file" | "directory" | "symlink"; path: string };
type PackageJson = { name?: string; main?: string; module?: string; exports?: unknown; type?: string };
type Format = "cjs" | "esm";
type Namespace = Record<string, unknown>;

const CODE_EXTENSIONS = [".ts", ".tsx", ".mts", ".cts", ".js", ".mjs", ".cjs", ".jsx"];
const CONDITIONS = ["node", "require", "import", "default"];
/** A literal `require("x")`, including esbuild's `(0, scope.require)("x")` in ES modules. */
const REQUIRE = /\brequire\)?\(\s*(["'`])([^"'`]+)\1\s*\)/g;
const IDENTIFIER = /^[A-Za-z_$][\w$]*$/;

let lexerReady: Promise<unknown> | undefined;
let esbuildReady: Promise<unknown> | undefined;

function initialize(): Promise<unknown> {
	lexerReady ??= initializeLexer();
	return lexerReady;
}

/** esbuild starts only when a file isn't in the transpile cache. */
function initializeEsbuild(): Promise<unknown> {
	esbuildReady ??= esbuild.initialize({ wasmURL: "pi://app/esbuild.wasm", worker: false });
	return esbuildReady;
}

let cacheDirectory: string | undefined;

/** Keeps transpiled files in `directory` between launches. */
export function setTranspileCache(directory: string): void {
	try {
		syncRequest("fs", "mkdir", { path: directory, recursive: true });
		cacheDirectory = directory;
	} catch (error) {
		console.warn(`transpile cache: ${error}`);
	}
}

/** What a file whose CommonJS transpile failed on top-level await keeps in the cache, so it goes straight to ESM. */
const TOP_LEVEL_AWAIT = "/* pi: top-level await */";

/** A file's place in the cache: a hash of its source, with what else decides its output. */
function cachePath(source: string, loader: string, format: Format): string | undefined {
	if (!cacheDirectory) return undefined;
	// cyrb53: a fast 53-bit string hash.
	let h1 = 0xdeadbeef ^ source.length;
	let h2 = 0x41c6ce57 ^ source.length;
	for (let index = 0; index < source.length; index++) {
		const code = source.charCodeAt(index);
		h1 = Math.imul(h1 ^ code, 2654435761);
		h2 = Math.imul(h2 ^ code, 1597334677);
	}
	h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
	h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
	const hash = (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
	return `${cacheDirectory}/${hash}-${source.length.toString(36)}-${loader}-${format}-${esbuild.version}.js`;
}

function readCache(path: string | undefined): string | undefined {
	if (!path) return undefined;
	try {
		return syncRequest<string>("fs", "readText", { path });
	} catch {
		return undefined;
	}
}

function writeCache(path: string | undefined, text: string): void {
	if (!path) return;
	try {
		syncRequest("fs", "write", { path, text });
	} catch (error) {
		console.warn(`transpile cache: ${error}`);
	}
}

/** What blob-URL modules read their `require`, `import()`, and Node globals from; each entry is taken once, by the
 * module's first statement. */
const scopes = new Map<number, unknown>();
let nextScope = 0;
(globalThis as { __piModuleScope?: unknown }).__piModuleScope = (id: number) => {
	const scope = scopes.get(id);
	scopes.delete(id);
	return scope;
};

function scopeExpression(scope: object): string {
	const id = nextScope++;
	scopes.set(id, scope);
	return `globalThis.__piModuleScope(${id})`;
}

export class ModuleRuntime {
	private readonly cache = new Map<string, Module>();
	private readonly prepared = new Map<string, string>();
	private readonly graph = new Set<string>();
	/** Each prepared module's static dependencies (files). */
	private readonly dependencies = new Map<string, Set<string>>();
	/** Files that run as ES modules (they use top-level await). */
	private readonly esm = new Set<string>();
	/** ES modules being or already evaluated, and the exports of those that finished. */
	private readonly evaluations = new Map<string, Promise<Namespace>>();
	private readonly esmExports = new Map<string, Namespace>();
	/** Blob URLs of ES modules (by file) and of facades (by module and the names imported). */
	private readonly urls = new Map<string, string>();
	private readonly stats = new Map<string, FileInfo | null>();
	private readonly packages = new Map<string, PackageJson | null>();
	private readonly builtins: Map<string, unknown>;

	constructor(
		readonly context: NodeContext,
		private readonly hostModules: Record<string, unknown>,
	) {
		this.builtins = nodeModules(context, (from) => this.createRequire(from));
	}

	/** Transpiles the module graph reachable from `entry` (an absolute path) so that `load()` can run it. */
	async prepare(entry: string): Promise<void> {
		await initialize();
		const pending = [entry];
		while (pending.length > 0) {
			const filename = pending.pop()!;
			this.graph.add(filename);
			if (this.prepared.has(filename) || /\.(json|node)$/.test(filename)) continue;
			try {
				pending.push(...this.include(filename, await transpile(readText(filename), filename, "cjs"), "cjs"));
			} catch (error) {
				if (!(error instanceof TranspileError && error.topLevelAwait)) throw error;
				pending.push(...this.include(filename, await transpile(readText(filename), filename, "esm"), "esm"));
			}
		}
		// A module that imports one with top-level await waits for it, so it is asynchronous too: an ES module.
		for (let changed = true; changed; ) {
			changed = false;
			for (const [filename, dependencies] of this.dependencies) {
				if (this.esm.has(filename) || ![...dependencies].some((dependency) => this.esm.has(dependency))) continue;
				this.include(filename, await transpile(readText(filename), filename, "esm"), "esm");
				changed = true;
			}
		}
	}

	/** Keeps a transpiled module and returns the files it refers to (static imports and requires, then import()s). */
	private include(filename: string, code: string, format: Format): string[] {
		const [imports] = parseImports(code, filename);
		if (format === "esm") this.esm.add(filename);
		this.prepared.set(filename, rewriteDynamicImports(code, imports));
		const statics = [...code.matchAll(REQUIRE)].map((match) => match[2]!);
		const dynamics: string[] = [];
		for (const item of imports) {
			if (item.type === "static" || item.type === "reexport-star") statics.push(item.specifier);
			else if (item.type === "dynamic" && item.specifier !== undefined && !item.glob) dynamics.push(item.specifier);
		}
		const files = (specifiers: string[]) =>
			specifiers.flatMap((specifier) => (this.hostValue(specifier) === undefined ? (this.tryResolve(filename, specifier) ?? []) : []));
		const dependencies = files(statics);
		this.dependencies.set(filename, new Set(dependencies));
		return [...dependencies, ...files(dynamics)];
	}

	/** The files `prepare()` reached. */
	get files(): string[] {
		return [...this.graph];
	}

	/** Runs a prepared module and returns its exports (for an ES module, its namespace marked `__esModule`). */
	async load(filename: string): Promise<unknown> {
		return this.esm.has(filename) ? this.importModule(filename) : this.loadFile(filename);
	}

	createRequire(from: string) {
		const require = (specifier: string) => this.requireFrom(from, specifier);
		require.resolve = (specifier: string) => (this.isBuiltin(specifier) ? specifier : this.resolve(from, specifier));
		require.cache = Object.fromEntries([...this.cache].map(([id, module]) => [id, module]));
		require.main = undefined;
		return require;
	}

	/** `import(specifier)` in the module `from`. */
	async import(from: string, specifier: string): Promise<Namespace> {
		const host = this.hostValue(specifier);
		if (host !== undefined) return namespaceOf(host);
		const filename = this.resolve(from, specifier);
		if (!this.prepared.has(filename)) await this.prepare(filename);
		return this.esm.has(filename) ? this.importModule(filename) : namespaceOf(this.loadFile(filename));
	}

	private isBuiltin(specifier: string): boolean {
		return this.builtins.has(specifier.replace(/^node:/, ""));
	}

	/** A Node built-in or one of pi's packages, which are not files. */
	private hostValue(specifier: string): unknown {
		const builtin = this.builtins.get(specifier.replace(/^node:/, ""));
		if (builtin !== undefined) return builtin;
		return Object.hasOwn(this.hostModules, specifier) ? this.hostModules[specifier] : undefined;
	}

	private requireFrom(from: string, specifier: string): unknown {
		const host = this.hostValue(specifier);
		if (host !== undefined) return host;
		return this.loadFile(this.resolve(from, specifier));
	}

	private loadFile(filename: string): unknown {
		if (this.esm.has(filename)) {
			// As in Node: a module with top-level await cannot be required until it has been imported.
			const exports = this.esmExports.get(filename);
			if (exports) return exports;
			const error = new Error(`require() cannot load ${filename}: it uses top-level await, so load it with import()`) as Error & { code: string };
			error.code = "ERR_REQUIRE_ASYNC_MODULE";
			throw error;
		}
		const cached = this.cache.get(filename);
		if (cached) return cached.exports;
		const module: Module = { exports: {}, loaded: false, id: filename, filename, children: [], paths: [] };
		this.cache.set(filename, module);
		try {
			this.evaluate(module);
		} catch (error) {
			this.cache.delete(filename);
			throw error;
		}
		module.loaded = true;
		return module.exports;
	}

	private evaluate(module: Module): void {
		const { filename } = module;
		if (filename.endsWith(".json")) {
			module.exports = JSON.parse(readText(filename));
			return;
		}
		if (filename.endsWith(".node")) throw new Error(`${filename}: native Node addons cannot run in pi on iOS`);
		const code = this.prepared.get(filename) ?? withoutHashbang(readText(filename));
		const globals = this.globals(filename);
		// The block lets the module declare its own `__dirname` (or `require`) with const or let, as ES modules do.
		const strict = /^\s*["']use strict["']/.test(code) ? '"use strict";' : "";
		const run = new Function(
			"exports",
			"require",
			"module",
			"__filename",
			"__dirname",
			"__importMeta",
			"__piImport",
			"process",
			"Buffer",
			"global",
			"setImmediate",
			"clearImmediate",
			"fetch",
			`${strict}{${code}\n}\n//# sourceURL=extension://${filename}`,
		);
		run.call(
			module.exports,
			module.exports,
			this.createRequire(filename),
			module,
			filename,
			globals.__dirname,
			globals.meta,
			globals.import,
			globals.process,
			Buffer,
			globalThis,
			globals.setImmediate,
			globals.clearImmediate,
			globals.fetch,
		);
	}

	/** What a module at `filename` sees as Node's module-scope globals, `import.meta`, and `import()`. */
	private globals(filename: string) {
		const dirname = filename.slice(0, filename.lastIndexOf("/")) || "/";
		return {
			require: this.createRequire(filename),
			import: (specifier: unknown) => this.import(filename, String(specifier)),
			meta: {
				url: `file://${filename}`,
				filename,
				dirname,
				resolve: (specifier: string) => (this.isBuiltin(specifier) ? specifier : `file://${this.resolve(filename, specifier)}`),
			},
			__filename: filename,
			__dirname: dirname,
			process: this.builtins.get("process"),
			Buffer,
			setImmediate: (callback: (...args: unknown[]) => void, ...args: unknown[]) => setTimeout(callback, 0, ...args),
			clearImmediate: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle),
			// The extension's own (it knows `clientKey`, net.ts).
			fetch: this.context.fetch ?? ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init)),
		};
	}

	// ---- ES modules ----

	/** Evaluates an ES module (once) and returns its exports. */
	private importModule(filename: string): Promise<Namespace> {
		let evaluation = this.evaluations.get(filename);
		if (!evaluation) {
			evaluation = (async () => {
				const namespace = (await import(/* @vite-ignore */ this.moduleUrl(filename, []))) as Namespace;
				const exports = { __esModule: true, ...namespace };
				this.esmExports.set(filename, exports);
				return exports;
			})();
			evaluation.catch(() => this.evaluations.delete(filename));
			this.evaluations.set(filename, evaluation);
		}
		return evaluation;
	}

	/** A blob URL for an ES module, its static imports rewritten to the blob URLs of what they resolve to. */
	private moduleUrl(filename: string, stack: string[]): string {
		const known = this.urls.get(filename);
		if (known) return known;
		if (stack.includes(filename)) throw new Error(`circular imports between modules with top-level await: ${[...stack, filename].join(" → ")}`);
		const code = this.prepared.get(filename);
		if (code === undefined) throw new Error(`${filename} was not prepared`);
		let output = "";
		let last = 0;
		for (const item of parseImports(code, filename)[0]) {
			if (item.type !== "static" && item.type !== "reexport-star") continue;
			const names = importedNames(code.slice(item.importStart, item.importEnd));
			output += code.slice(last, item.start) + this.dependencyUrl(filename, item.specifier, names, [...stack, filename]);
			last = item.end;
		}
		output += code.slice(last);
		// One line, so that line numbers in errors match the transpiled module.
		const scope = scopeExpression(this.globals(filename));
		const url = blobUrl(`const __piScope = ${scope}, __piImport = __piScope.import, __importMeta = __piScope.meta;${output}\n//# sourceURL=extension://${filename}`);
		this.urls.set(filename, url);
		return url;
	}

	private dependencyUrl(from: string, specifier: string, names: string[], stack: string[]): string {
		const host = this.hostValue(specifier);
		if (host !== undefined) return this.facadeUrl(`host:${specifier}`, host, names);
		const filename = this.resolve(from, specifier);
		if (this.esm.has(filename)) return this.moduleUrl(filename, stack);
		return this.facadeUrl(filename, this.loadFile(filename), names);
	}

	/** An ES module re-exporting a CommonJS module's exports: its keys, and the names an importer asks for. */
	private facadeUrl(key: string, value: unknown, names: string[]): string {
		const namespace = namespaceOf(value);
		const exported = [...new Set([...Object.keys(namespace), ...names])].filter((name) => name !== "default" && name !== "__esModule" && IDENTIFIER.test(name));
		const cacheKey = `${key}\0${exported.join(",")}`;
		const known = this.urls.get(cacheKey);
		if (known) return known;
		let code = `const __piScope = ${scopeExpression({ namespace })}, __piNamespace = __piScope.namespace;\nexport default __piNamespace.default;\n`;
		if (exported.length > 0) {
			code += `const ${exported.map((name, index) => `__e${index} = __piNamespace[${JSON.stringify(name)}]`).join(", ")};\n`;
			code += `export { ${exported.map((name, index) => `__e${index} as ${name}`).join(", ")} };\n`;
		}
		const url = blobUrl(code);
		this.urls.set(cacheKey, url);
		return url;
	}

	// ---- resolution ----

	private tryResolve(from: string, specifier: string): string | undefined {
		try {
			return this.resolve(from, specifier);
		} catch {
			return undefined;
		}
	}

	resolve(from: string, specifier: string): string {
		const base = from.slice(0, from.lastIndexOf("/")) || "/";
		let resolved: string | undefined;
		if (specifier.startsWith("./") || specifier.startsWith("../") || specifier === "." || specifier === "..") {
			resolved = this.resolvePath(join(base, specifier));
		} else if (specifier.startsWith("/")) {
			resolved = this.resolvePath(normalize(specifier));
		} else if (specifier.startsWith("file://")) {
			resolved = this.resolvePath(decodeURIComponent(new URL(specifier).pathname));
		} else {
			resolved = this.resolvePackage(base, specifier);
		}
		if (!resolved) {
			const error = new Error(`Cannot find module '${specifier}' from '${from}'`) as Error & { code: string };
			error.code = "MODULE_NOT_FOUND";
			throw error;
		}
		return resolved;
	}

	private resolvePath(path: string): string | undefined {
		return this.resolveFile(path) ?? this.resolveDirectory(path);
	}

	private resolveFile(path: string): string | undefined {
		if (this.isFile(path)) return path;
		// TypeScript ES modules import "./x.js" for "./x.ts".
		const typescript = path.replace(/\.(m|c)?js$/, (_, kind) => `.${kind ?? ""}ts`);
		if (typescript !== path && this.isFile(typescript)) return typescript;
		for (const extension of [...CODE_EXTENSIONS, ".json", ".node"]) {
			if (this.isFile(path + extension)) return path + extension;
		}
		return undefined;
	}

	private resolveDirectory(path: string): string | undefined {
		const manifest = this.packageJson(path);
		if (manifest) {
			const main = manifest.main ?? manifest.module;
			if (main) {
				const resolved = this.resolveFile(join(path, main)) ?? this.resolveIndex(join(path, main));
				if (resolved) return resolved;
			}
		}
		return this.resolveIndex(path);
	}

	private resolveIndex(path: string): string | undefined {
		for (const extension of [...CODE_EXTENSIONS, ".json"]) {
			if (this.isFile(`${path}/index${extension}`)) return `${path}/index${extension}`;
		}
		return undefined;
	}

	private resolvePackage(base: string, specifier: string): string | undefined {
		const parts = specifier.split("/");
		const name = specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0]!;
		const subpath = parts.slice(specifier.startsWith("@") ? 2 : 1).join("/");
		for (let directory = base; ; directory = directory.slice(0, directory.lastIndexOf("/")) || "/") {
			const packageDirectory = `${directory === "/" ? "" : directory}/node_modules/${name}`;
			if (this.isDirectory(packageDirectory)) {
				const manifest = this.packageJson(packageDirectory);
				if (manifest?.exports !== undefined) {
					const target = exportTarget(manifest.exports, subpath ? `./${subpath}` : ".");
					if (target) return this.resolveFile(join(packageDirectory, target));
				}
				return subpath ? this.resolvePath(join(packageDirectory, subpath)) : this.resolveDirectory(packageDirectory);
			}
			if (directory === "/") return undefined;
		}
	}

	private packageJson(directory: string): PackageJson | null {
		if (!this.packages.has(directory)) {
			const path = `${directory}/package.json`;
			this.packages.set(directory, this.isFile(path) ? (JSON.parse(readText(path)) as PackageJson) : null);
		}
		return this.packages.get(directory)!;
	}

	private info(path: string): FileInfo | null {
		if (!this.stats.has(path)) {
			let info: FileInfo | null = null;
			try {
				info = syncRequest<FileInfo>("fs", "stat", { path });
				if (info.kind === "symlink") {
					info = syncRequest<FileInfo>("fs", "stat", { path: syncRequest<string>("fs", "realpath", { path }) });
				}
			} catch {
				info = null;
			}
			this.stats.set(path, info);
		}
		return this.stats.get(path)!;
	}

	private isFile(path: string): boolean {
		return this.info(path)?.kind === "file";
	}

	private isDirectory(path: string): boolean {
		return this.info(path)?.kind === "directory";
	}
}

/** The file a package.json `exports` field maps `subpath` (".", "./x") to, for Node's conditions. */
function exportTarget(exports: unknown, subpath: string): string | undefined {
	const conditional = (value: unknown): string | undefined => {
		if (typeof value === "string") return value;
		if (Array.isArray(value)) {
			for (const each of value) {
				const target = conditional(each);
				if (target) return target;
			}
			return undefined;
		}
		if (value && typeof value === "object") {
			for (const [condition, target] of Object.entries(value)) {
				if (CONDITIONS.includes(condition)) {
					const resolved = conditional(target);
					if (resolved) return resolved;
				}
			}
		}
		return undefined;
	};
	if (typeof exports === "string" || Array.isArray(exports)) return subpath === "." ? conditional(exports) : undefined;
	if (!exports || typeof exports !== "object") return undefined;
	const entries = Object.entries(exports);
	if (!entries.some(([key]) => key.startsWith("."))) return subpath === "." ? conditional(exports) : undefined;
	const exact = (exports as Record<string, unknown>)[subpath];
	if (exact !== undefined) return conditional(exact);
	for (const [key, target] of entries) {
		const star = key.indexOf("*");
		if (star < 0) continue;
		const [prefix, suffix] = [key.slice(0, star), key.slice(star + 1)];
		if (subpath.startsWith(prefix) && subpath.endsWith(suffix) && subpath.length >= prefix.length + suffix.length) {
			const match = subpath.slice(prefix.length, subpath.length - suffix.length);
			return conditional(target)?.replaceAll("*", match);
		}
	}
	return undefined;
}

class TranspileError extends Error {
	constructor(
		message: string,
		readonly topLevelAwait: boolean,
	) {
		super(message);
	}
}

async function transpile(source: string, filename: string, format: Format): Promise<string> {
	const extension = /\.[^./]+$/.exec(filename)?.[0] ?? ".js";
	const loader = extension === ".ts" || extension === ".mts" || extension === ".cts" ? "ts" : extension === ".tsx" ? "tsx" : extension === ".jsx" ? "jsx" : "js";
	const cached = cachePath(source, loader, format);
	const hit = readCache(cached);
	if (hit === TOP_LEVEL_AWAIT) throw new TranspileError(`${filename}: top-level await`, true);
	if (hit !== undefined) return hit;
	await initializeEsbuild();
	// An ES module's Node globals come from its scope (see moduleUrl); esbuild only replaces free references, so the
	// module can still declare its own `__dirname` or `require`.
	const scoped: Record<string, string> =
		format === "esm"
			? { require: "__piScope.require", __filename: "__piScope.__filename", __dirname: "__piScope.__dirname", process: "__piScope.process", Buffer: "__piScope.Buffer", global: "globalThis", setImmediate: "__piScope.setImmediate", clearImmediate: "__piScope.clearImmediate", fetch: "__piScope.fetch" }
			: {};
	try {
		const result = await esbuild.transform(source, {
			loader,
			format,
			platform: "node",
			target: "es2022",
			sourcefile: filename,
			define: { "import.meta": "__importMeta", ...scoped },
			logLevel: "silent",
		});
		const code = withoutHashbang(result.code);
		writeCache(cached, code);
		return code;
	} catch (error) {
		const failure = error as { errors?: { text: string; location?: { line: number; column: number } }[] };
		const first = failure.errors?.[0];
		const topLevelAwait = first?.text.startsWith("Top-level await") === true;
		if (topLevelAwait) writeCache(cached, TOP_LEVEL_AWAIT);
		throw new TranspileError(
			first ? `${filename}:${first.location?.line ?? 0}:${first.location?.column ?? 0}: ${first.text}` : String(error),
			topLevelAwait,
		);
	}
}

/**
 * A script's `#!` line (esbuild keeps it) is only valid at the very start of what runs, and modules run wrapped. As in
 * Node, it may follow a byte order mark. The line stays (empty), so line numbers in errors still match the file.
 */
function withoutHashbang(code: string): string {
	return code.replace(/^﻿?#!.*/, "");
}

/** `import(x)` becomes `__piImport(x)`, the module system's import (WebKit's would resolve against the page). */
function rewriteDynamicImports(code: string, imports: ReturnType<typeof parseImports>[0]): string {
	let output = code;
	for (const item of [...imports].reverse()) {
		if (item.type !== "dynamic") continue;
		if (output.slice(item.importStart, item.importStart + 6) !== "import") throw new Error(`unexpected dynamic import at ${item.importStart}`);
		output = `${output.slice(0, item.importStart)}__piImport${output.slice(item.importStart + 6)}`;
	}
	return output;
}

/** What `import` gives for a CommonJS module: its exports as named exports, and as `default` (or, for an ES module
 * esbuild turned into CommonJS, which is marked `__esModule`, its own `default`). */
function namespaceOf(value: unknown): Namespace {
	if ((typeof value === "object" && value !== null) || typeof value === "function") {
		if ((value as { __esModule?: unknown }).__esModule) return value as Namespace;
		return { ...(value as object), default: value };
	}
	return { default: value };
}

/** The names an `import { a, b as c } from` or `export { a } from` statement takes from its module. */
function importedNames(statement: string): string[] {
	const clause = /^(?:import|export)\s*(?:[\w$]+\s*,\s*)?\{([^}]*)\}/.exec(statement)?.[1];
	if (!clause) return [];
	return clause
		.split(",")
		.map((part) => part.trim().split(/\s+as\s+/)[0]!.trim())
		.filter((name) => IDENTIFIER.test(name));
}

function blobUrl(code: string): string {
	return URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
}

function readText(path: string): string {
	return syncRequest<string>("fs", "readText", { path });
}

function normalize(path: string): string {
	const parts: string[] = [];
	for (const part of path.split("/")) {
		if (part === "" || part === ".") continue;
		if (part === "..") parts.pop();
		else parts.push(part);
	}
	return `/${parts.join("/")}`;
}

function join(base: string, path: string): string {
	return normalize(path.startsWith("/") ? path : `${base}/${path}`);
}

export { builtinModuleNames };
