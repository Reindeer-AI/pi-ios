import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { build } from "esbuild";

const outdir = new URL("./dist/", import.meta.url);
await mkdir(outdir, { recursive: true });

// pi-ai's OAuth flows import node:http (loopback callback server) and node:crypto (random bytes); in WebKit these
// resolve to small shims backed by native services and Web Crypto.
const nodeShims = {
	name: "node-shims",
	setup(build) {
		const shims = { "node:http": "src/shims/node-http.ts", "node:crypto": "src/shims/node-crypto.ts" };
		build.onResolve({ filter: /^node:(http|crypto)$/ }, (args) => ({
			path: new URL(shims[args.path], import.meta.url).pathname,
		}));
	},
};

// pi-ai's OpenAI Codex login loads node:crypto only when it detects Node or Bun. In the engine, node:crypto is the
// shim above, so let that flow load it. Asserted, so an upstream change fails the build instead of the login.
const codexCryptoGate = {
	name: "codex-crypto-gate",
	setup(build) {
		build.onLoad({ filter: /pi-ai\/dist\/auth\/oauth\/openai-codex\.js$/ }, async (args) => {
			const gate = 'typeof process !== "undefined" && (process.versions?.node || process.versions?.bun)';
			const source = await readFile(args.path, "utf8");
			if (source.split(gate).length !== 2) {
				throw new Error(`openai-codex.js: expected one Node/Bun gate for node:crypto (${args.path})`);
			}
			return { contents: source.replace(gate, "true"), loader: "js" };
		});
	},
};

// The OpenAI and Anthropic SDKs say only "Connection error." when fetch fails; the engine's fetch (src/net.ts) knows why
// (a timeout, a lost connection, a refused request), and a run's error should say so. Asserted, like the gate above.
const connectionErrorCause = {
	name: "connection-error-cause",
	setup(build) {
		build.onLoad({ filter: /(openai|@anthropic-ai\/sdk)\/core\/error\.mjs$/ }, async (args) => {
			const plain = "message || 'Connection error.'";
			const source = await readFile(args.path, "utf8");
			if (source.split(plain).length !== 2) throw new Error(`${args.path}: expected one "Connection error." default`);
			return { contents: source.replace(plain, "message || (cause?.message ? `Connection error: ${cause.message}` : 'Connection error.')"), loader: "js" };
		});
	},
};

// Files of pi-coding-agent that run in WebKit unchanged (extensions/coding-agent.ts); its package exports only its entry.
// Its truncation uses Node's global Buffer, which it gets from the buffer package instead.
const codingAgentFiles = {
	name: "coding-agent-files",
	setup(build) {
		build.onResolve({ filter: /^@earendil-works\/pi-coding-agent\/dist\// }, (args) => ({
			path: new URL(`./node_modules/${args.path}`, import.meta.url).pathname,
		}));
		build.onLoad({ filter: /pi-coding-agent\/dist\/core\/tools\/truncate\.js$/ }, async (args) => ({
			contents: `import { Buffer } from "buffer";\n${await readFile(args.path, "utf8")}`,
			loader: "js",
		}));
	},
};

// pi-tui runs in WebKit for extensions (extensions/tui.ts). Its terminal, file, and process parts import Node built-ins;
// those resolve to modules whose functions fail when called, so the components load and only those parts fail.
const piTuiWithoutNode = {
	name: "pi-tui-without-node",
	setup(build) {
		const fromPiTui = (args) => args.importer.includes("/@earendil-works/pi-tui/dist/");
		const local = (path) => new URL(path, import.meta.url).pathname;
		build.onResolve({ filter: /^(node:)?(path|events|perf_hooks|module|fs|os|child_process|url|tty|util|crypto|stream|readline)$/ }, (args) => {
			if (!fromPiTui(args)) return undefined;
			const name = args.path.replace(/^node:/, "");
			if (name === "path") return { path: local("./node_modules/path-browserify/index.js") };
			if (name === "events") return { path: local("./node_modules/events/events.js") };
			return { path: name, namespace: "pi-tui-node" };
		});
		build.onLoad({ filter: /.*/, namespace: "pi-tui-node" }, (args) => ({
			contents:
				args.path === "perf_hooks"
					? "module.exports = { performance: globalThis.performance };"
					: args.path === "module"
						? "module.exports = { createRequire: () => (id) => { throw new Error('require(' + id + ') is not available in pi on iOS'); } };"
						: `module.exports = new Proxy({}, { get: (_, key) => typeof key === "symbol" || key === "__esModule" ? undefined : () => { throw new Error("node:${args.path} is not available in pi on iOS (" + String(key) + ")"); } });`,
			loader: "js",
		}));
	},
};

// pi-mcp (mcp.ts): its stdio transport (child processes) can't run on iOS and isn't used; its imports resolve to modules
// that fail when called. Its OAuth flow and HTTP transport use Node's Buffer, which src/shims/mcp-buffer.ts provides.
const piMcpWithoutNode = {
	name: "pi-mcp-without-node",
	setup(build) {
		build.onResolve({ filter: /^(node:)?(child_process|process)$|^cross-spawn$/ }, (args) => {
			if (!args.importer.includes("/@earendil-works/pi-mcp/dist/")) return undefined;
			return { path: args.path.replace(/^node:/, ""), namespace: "pi-mcp-node" };
		});
		build.onLoad({ filter: /.*/, namespace: "pi-mcp-node" }, (args) => ({
			contents: `module.exports = new Proxy(function () { throw new Error("${args.path} is not available in pi on iOS"); }, { get: (_, key) => typeof key === "symbol" || key === "__esModule" ? undefined : () => { throw new Error("${args.path} is not available in pi on iOS (" + String(key) + ")"); } });`,
			loader: "js",
		}));
		const buffer = new URL("./src/shims/mcp-buffer.ts", import.meta.url).pathname;
		build.onLoad({ filter: /pi-mcp\/dist\/(oauth|transports)\/[\w-]+\.js$/ }, async (args) => {
			const source = await readFile(args.path, "utf8");
			if (!source.includes("Buffer.")) return undefined;
			return { contents: `import { Buffer } from ${JSON.stringify(buffer)};\n${source}`, loader: "js" };
		});
	},
};

const result = await build({
	plugins: [nodeShims, codexCryptoGate, connectionErrorCause, codingAgentFiles, piTuiWithoutNode, piMcpWithoutNode],
	entryPoints: ["src/main.ts"],
	outfile: "dist/engine.js",
	bundle: true,
	format: "esm",
	platform: "browser",
	target: "safari17",
	sourcemap: "linked",
	metafile: true,
	logLevel: "info",
});

// esbuild (WebAssembly) transpiles extension code at run time (src/extensions/runtime.ts).
await copyFile(new URL("./node_modules/esbuild-wasm/esbuild.wasm", import.meta.url), new URL("esbuild.wasm", outdir));

await writeFile(
	new URL("index.html", outdir),
	`<!doctype html>
<html>
<head><meta charset="utf-8"><title>pi engine</title></head>
<body><script type="module" src="engine.js"></script></body>
</html>
`,
);

// Every name pi-coding-agent exports must exist in the module extensions get, so an upgrade that adds one fails here.
{
	const checkFile = new URL("coding-agent-check.mjs", outdir);
	await build({
		plugins: [codingAgentFiles],
		entryPoints: ["src/extensions/coding-agent.ts"],
		outfile: checkFile.pathname,
		bundle: true,
		format: "esm",
		platform: "node",
		// For CommonJS dependencies that require Node built-ins.
		banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' },
		logLevel: "silent",
	});
	const ours = await import(checkFile.href).finally(() => rm(checkFile));
	const module = ours.codingAgentModule({ agentDir: "", copyToClipboard: async () => {}, exec: async () => ({ exitCode: 0 }) });
	const theirs = Object.keys(await import("@earendil-works/pi-coding-agent"));
	const absent = theirs.filter((name) => !(name in module));
	if (absent.length > 0) {
		console.error(`extensions/coding-agent.ts lacks pi-coding-agent exports: ${absent.join(", ")}`);
		process.exit(1);
	}
}

// Static and dynamic imports of Node built-ins break in WebKit. Guarded `require()` calls (e.g. pi-ai's Bun-only
// env fallback behind `typeof process`) never run there; list them so new ones get noticed.
const nodeImports = Object.entries(result.metafile.inputs).flatMap(([file, input]) =>
	input.imports.filter((imported) => imported.path.startsWith("node:")).map((imported) => ({ file, ...imported })),
);
for (const { file, path } of nodeImports.filter((i) => i.kind === "require-call")) {
	console.warn(`guarded require of ${path} in ${file}`);
}
const breaking = nodeImports.filter((i) => i.kind === "import-statement" || i.kind === "dynamic-import");
if (breaking.length > 0) {
	for (const { file, path, kind } of breaking) console.error(`${kind} of ${path} in ${file}`);
	process.exit(1);
}
