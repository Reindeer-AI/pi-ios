/**
 * Crabbox: a real Linux machine for work the phone cannot do (Node, compilers, Docker, any toolchain), leased from
 * the user's Crabbox broker (openclaw/crabbox) while the agent stays on the phone.
 *
 * A session leases one box on first use and keeps it (heartbeats) until it is released, the session is deleted, or
 * the broker's TTL or idle timeout ends it. The app holds the broker token and each lease's SSH key (the native
 * `crabbox` service); this module only asks it for broker calls and SSH commands.
 *
 * - The workspace goes to the box as a tar.gz stream over SSH, as Crabbox itself does without rsync.
 * - A command runs detached on the box, its output in a log there, and is followed until it exits. Its ID is kept in
 *   the tool call's memo, so after the app is suspended or killed, the resumed call follows the same run instead of
 *   starting another.
 */
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { type ConversationId, defineDoc, defineExtension, defineTool, type Harness, section, type ToolExecutionApi } from "@earendil-works/pi-durable";
import { onCommand, request } from "./bridge.ts";

type Lease = {
	id: string;
	/** The create-attempt token sent with the lease's creation; sending it again replays that creation. */
	attempt?: string;
	host?: string;
	port?: number;
	user?: string;
	/** Pinned from the broker, or from the first connection. */
	hostKey?: string;
	/** This session's folder on the box. */
	root?: string;
	provider?: string;
	/** The machine class asked for: standard, fast, or beast. */
	size?: Size;
	expiresAt?: string;
};

type Size = "standard" | "fast" | "beast";

const GCP_MACHINES: Record<Size, string> = { standard: "e2-standard-8", fast: "e2-standard-16", beast: "e2-standard-32" };

/** The session's lease; a fork starts without one (it gets its own box). */
export const CrabboxDoc = defineDoc<{ lease: Lease | null }>({
	kind: "pimobile.crabbox",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ lease: null }),
});

type Status = { broker: string | null; signedIn: boolean; provider: string | null; identity: Record<string, unknown> | null };
type BrokerLease = { id: string; state?: string; host?: string; sshUser?: string; sshPort?: string; sshHostKey?: string; workRoot?: string; provider?: string; expiresAt?: string; failureError?: string };

/** Whether a broker is set up and signed in, as of the last check (the app tells the engine when it changes). */
let available = false;

export async function refreshCrabbox(): Promise<boolean> {
	const status = await request<Status>("crabbox", "status");
	available = status.signedIn && status.broker !== null;
	return available;
}

export function crabboxAvailable(): boolean {
	return available;
}

// ---- native calls ----

const outputs = new Map<string, (data: Uint8Array, stderr: boolean) => void>();

onCommand("crabbox.output", ({ id, data, stderr }: { id: string; data: string; stderr: boolean }) => {
	outputs.get(id)?.(Uint8Array.from(atob(data), (c) => c.charCodeAt(0)), stderr);
	return null;
});

async function broker<T>(method: string, path: string, body?: unknown, options?: { prefer?: string; timeout?: number }): Promise<T> {
	const reply = await request<{ status: number; body: unknown }>("crabbox", "request", { method, path, body: body ?? null, ...options });
	if (reply.status >= 400) {
		const message = (reply.body as { error?: string } | null)?.error ?? JSON.stringify(reply.body);
		throw new BrokerError(reply.status, `Crabbox broker: ${method} ${path} → ${reply.status} ${message}`);
	}
	return reply.body as T;
}

class BrokerError extends Error {
	constructor(
		readonly status: number,
		message: string,
	) {
		super(message);
	}
}

let nextExec = 0;

type ExecOptions = { stdout?: (text: string) => void; stderr?: (text: string) => void; stdinPath?: string; stdoutPath?: string; signal?: AbortSignal };

/** A command on the lease's box; resolves with its exit code (null when it was killed or the connection dropped). */
async function exec(lease: Lease, command: string, options: ExecOptions = {}): Promise<{ exitCode: number | null; hostKey: string }> {
	const id = `crabbox-${++nextExec}`;
	const decoders = { out: new TextDecoder(), err: new TextDecoder() };
	outputs.set(id, (data, stderr) => {
		if (stderr) options.stderr?.(decoders.err.decode(data, { stream: true }));
		else options.stdout?.(decoders.out.decode(data, { stream: true }));
	});
	const kill = () => void request("crabbox", "kill", { id });
	options.signal?.addEventListener("abort", kill, { once: true });
	try {
		return await request("crabbox", "exec", {
			id,
			keyId: lease.id,
			host: lease.host,
			port: lease.port ?? 22,
			user: lease.user,
			hostKey: lease.hostKey ?? null,
			command,
			stdinPath: options.stdinPath ?? null,
			stdoutPath: options.stdoutPath ?? null,
		});
	} finally {
		outputs.delete(id);
		options.signal?.removeEventListener("abort", kill);
	}
}

/** A shell word, single-quoted. */
function quote(value: string): string {
	return `'${value.replaceAll("'", `'\\''`)}'`;
}

function randomHex(bytes: number): string {
	return Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- leases ----

/** A copy: documents read in a commit are views that end with it. */
async function readLease(api: ToolExecutionApi): Promise<Lease | null> {
	return api.commit(async (tx) => {
		const { lease } = await tx.doc(CrabboxDoc, api.conversationId);
		return lease ? { ...lease } : null;
	}, BACKGROUND);
}

async function writeLease(api: ToolExecutionApi, lease: Lease | null): Promise<void> {
	await api.commit(async (tx) => {
		(await tx.doc(CrabboxDoc, api.conversationId)).lease = lease;
	}, BACKGROUND);
}

/** The lease bookkeeping is not part of the call's cancellation. */
const BACKGROUND = BACKGROUND_CONTEXT;

/**
 * The session's box: the one it has (still leased), else a new lease. Creating is idempotent, as the Crabbox CLI does
 * it: the lease ID and a create-attempt token are chosen here and recorded first, then sent with `POST /v1/leases`, so
 * a call resumed after the app was killed replays that creation and gets the same box rather than a second one.
 */
async function ensureLease(api: ToolExecutionApi, size: Size, progress: (line: string) => void, signal?: AbortSignal): Promise<Lease> {
	let lease = await readLease(api);
	if (lease?.host) {
		try {
			const { lease: current } = await broker<{ lease: BrokerLease }>("POST", `/v1/leases/${encodeURIComponent(lease.id)}/heartbeat`, {});
			if (current.state === "active") return lease;
		} catch (error) {
			if (!(error instanceof BrokerError)) throw error;
		}
		progress(`Lease ${lease.id} has ended; leasing a new box.`);
		await request("crabbox", "forgetKey", { keyId: lease.id });
		lease = null;
		await writeLease(api, null);
	}
	const status = await request<Status>("crabbox", "status");
	const id = lease?.id ?? `cbx_${randomHex(6)}`;
	const attempt = lease?.attempt ?? randomHex(16);
	// A lease being created keeps the size it was asked for, so a resumed call replays the same request.
	size = lease?.size ?? size;
	if (!lease?.attempt) await writeLease(api, { id, attempt, size });
	const { publicKey } = await request<{ publicKey: string }>("crabbox", "keygen", { keyId: id });
	progress(`Leasing a ${size} Linux box from ${status.broker} (${id})…`);
	const body: Record<string, unknown> = {
		leaseID: id,
		slug: `pi-${api.conversationId}`,
		target: "linux",
		// Always sent: a broker's default class may be its largest machine (GCP's c4-standard-192 for "beast").
		class: size,
		ttlSeconds: 4 * 3600,
		idleTimeoutSeconds: 30 * 60,
		keep: false,
		sshPublicKey: publicKey,
		createAttemptID: attempt,
	};
	if (status.provider) body.provider = status.provider;
	// On Google Cloud the broker's classes start at C4 machines (c4-standard-32 for standard), which a broker that
	// boots them from pd-balanced disks gets refused (HTTP 400, no fallback); E2 machines boot from it.
	if (status.provider === "gcp") {
		body.serverType = GCP_MACHINES[size];
		body.serverTypeExplicit = true;
	}
	// The broker answers at once with a provisioning lease (`Prefer: respond-async`); one that ignores the preference
	// answers when the box is up. A lease with this ID that already exists is this creation's, from before.
	let current: BrokerLease;
	try {
		({ lease: current } = await broker<{ lease: BrokerLease }>("POST", "/v1/leases", body, { prefer: "respond-async", timeout: 900 }));
	} catch (error) {
		if (!(error instanceof BrokerError) || error.status !== 409) throw error;
		({ lease: current } = await broker<{ lease: BrokerLease }>("GET", `/v1/leases/${encodeURIComponent(id)}`));
	}
	const started = Date.now();
	while (current.state !== "active" || !current.host) {
		if (current.state === "failed" || current.state === "released" || current.state === "expired") {
			throw new Error(`Crabbox could not provide a box (${current.state}): ${current.failureError ?? "no reason given"}`);
		}
		if (Date.now() - started > 15 * 60_000) throw new Error(`Crabbox lease ${id} was not ready after 15 minutes`);
		if (signal?.aborted) throw new Error("aborted");
		await sleep(3000);
		({ lease: current } = await broker<{ lease: BrokerLease }>("GET", `/v1/leases/${encodeURIComponent(id)}`));
	}
	const leased: Lease = {
		id,
		host: current.host,
		port: Number(current.sshPort) || 22,
		user: current.sshUser || "crabbox",
		hostKey: current.sshHostKey || undefined,
		root: `${(current.workRoot || "/work/crabbox").replace(/\/+$/, "")}/${id}/pi`,
		provider: current.provider,
		size,
		expiresAt: current.expiresAt,
	};
	// The box answers SSH once it has booted.
	progress(`Box ${current.host} is up (${current.provider ?? "provider"}); waiting for SSH…`);
	for (let attempt = 0; ; attempt++) {
		try {
			const result = await exec(leased, `mkdir -p ${quote(leased.root!)}`, { signal });
			if (result.exitCode === 0) {
				leased.hostKey ??= result.hostKey;
				break;
			}
		} catch (error) {
			if (attempt >= 60 || signal?.aborted) throw error;
		}
		await sleep(3000);
	}
	await writeLease(api, leased);
	return leased;
}

/** The workspace as a tar.gz on the box, replacing changed files (files deleted here stay there). */
async function sync(api: ToolExecutionApi, lease: Lease, context: Context): Promise<void> {
	const env = api.env;
	if (!env) throw new Error("no workspace to sync");
	const archive = `${env.cwd}/.crabbox/sync.tgz`;
	const packed = await env.exec("mkdir -p .crabbox && tar czf .crabbox/sync.tgz --exclude ./.crabbox --exclude ./.python .", { cwd: env.cwd }, context);
	if (!packed.ok || packed.value.exitCode !== 0) throw new Error(`could not pack the workspace for the box (${packed.ok ? `exit ${packed.value.exitCode}` : packed.error.message})`);
	let errors = "";
	const unpacked = await exec(lease, `mkdir -p ${quote(lease.root!)} && tar xzf - -C ${quote(lease.root!)} --no-same-owner -m`, {
		stdinPath: archive,
		stderr: (text) => (errors += text),
		signal: context.abortSignal,
	});
	if (unpacked.exitCode !== 0) throw new Error(`could not unpack the workspace on the box: ${errors.trim() || `exit ${unpacked.exitCode}`}`);
}

/** Starts the command detached on the box, once per run ID (a resumed call finds it started). */
function startScript(lease: Lease, runId: string, command: string): string {
	const run = `.crabbox/runs/${runId}`;
	const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(command)));
	return [
		`cd ${quote(lease.root!)} && mkdir -p .crabbox/runs`,
		`if mkdir ${run} 2>/dev/null; then`,
		`  printf %s ${quote(encoded)} | base64 -d > ${run}/command`,
		// The user's GitHub token, when the app put it on the box, for gh and other tools.
		`  setsid sh -c 'if [ -r ~/.config/pi/github-token ]; then GH_TOKEN=$(cat ~/.config/pi/github-token); GITHUB_TOKEN=$GH_TOKEN; export GH_TOKEN GITHUB_TOKEN; fi; sh ${run}/command > ${run}/out 2>&1 < /dev/null; echo $? > ${run}/exit' > /dev/null 2>&1 < /dev/null &`,
		`  echo $! > ${run}/pid`,
		"fi",
	].join("\n");
}

/** Prints the run's output from byte `offset` on as it grows, then `CRABBOX_EXIT <code>` on stderr. */
function followScript(lease: Lease, runId: string, offset: number): string {
	const run = `.crabbox/runs/${runId}`;
	return [
		`cd ${quote(lease.root!)} || exit 1`,
		`off=${offset}`,
		"while :; do",
		`  size=$(wc -c < ${run}/out 2>/dev/null || echo 0)`,
		`  if [ "$size" -gt "$off" ]; then tail -c +$((off + 1)) ${run}/out | head -c $((size - off)); off=$size; fi`,
		`  if [ -f ${run}/exit ]; then`,
		`    size=$(wc -c < ${run}/out 2>/dev/null || echo 0)`,
		`    if [ "$size" -le "$off" ]; then echo "CRABBOX_EXIT $(cat ${run}/exit)" >&2; exit 0; fi`,
		"  else sleep 0.5; fi",
		"done",
	].join("\n");
}

function killScript(lease: Lease, runId: string): string {
	const run = `.crabbox/runs/${runId}`;
	return `cd ${quote(lease.root!)} && kill -TERM -- -$(cat ${run}/pid) 2>/dev/null; sleep 1; [ -f ${run}/exit ] || echo 143 > ${run}/exit`;
}

/** The end of a long output, for the tool result (the whole output streams to the chat as it runs). */
function tail(text: string, maxLines = 120, maxChars = 12_000): string {
	let lines = text.split("\n");
	const cut = lines.length > maxLines;
	if (cut) lines = lines.slice(-maxLines);
	let result = lines.join("\n");
	if (result.length > maxChars) result = result.slice(-maxChars);
	return cut || result.length < text.length ? `[earlier output omitted]\n${result}` : result;
}

// ---- the extension ----

const run = defineTool({
	name: "crabbox_run",
	description:
		"Run a shell command (bash) on a real Linux machine leased through Crabbox, in a copy of this session's workspace. The first call leases the box; later calls reuse it. Use it for what this phone cannot do: Node, npm, compilers, Docker, apt packages, tests, builds.",
	parameters: Type.Object({
		command: Type.String({ description: "A bash command, run in the workspace copy on the box" }),
		sync: Type.Optional(Type.Boolean({ description: "Copy the workspace to the box first (default true)" })),
		timeout: Type.Optional(Type.Number({ description: "Seconds before the command is stopped (default 1800)" })),
		size: Type.Optional(
			Type.Union([Type.Literal("standard"), Type.Literal("fast"), Type.Literal("beast")], {
				description:
					"The machine, chosen for the task when the box is leased: standard (the default; installs, tests, ordinary builds), fast (heavy compiles, long test suites), beast (the largest and most expensive; only for big parallel builds that need it)",
			}),
		),
	}),
	// A resumed call follows the run its memo names instead of starting another.
	replay: "safe",
	executionMode: "sequential",
	execute: async (args, api, context) => {
		const signal = context.abortSignal;
		const lease = await ensureLease(api, args.size ?? "standard", (line) => api.output(`${line}\n`), signal);
		const runId = await api.memo<string>("run", `run_${randomHex(6)}`, context);
		if (!(await api.memo<boolean>("synced", context)) && args.sync !== false) {
			await sync(api, lease, context);
			await api.memo<boolean>("synced", true, context);
		}
		const started = await exec(lease, startScript(lease, runId, args.command), { signal });
		if (started.exitCode !== 0) throw new Error(`could not start the command on the box (exit ${started.exitCode})`);

		let output = "";
		let exitCode: number | undefined;
		let stopped: string | undefined;
		const timeout = setTimeout(
			() => {
				stopped = "timed out";
				void exec(lease, killScript(lease, runId));
			},
			(args.timeout ?? 1800) * 1000,
		);
		const heartbeat = setInterval(() => void broker("POST", `/v1/leases/${encodeURIComponent(lease.id)}/heartbeat`, {}).catch(() => {}), 120_000);
		const abort = () => {
			stopped = "stopped";
			void exec(lease, killScript(lease, runId));
		};
		signal?.addEventListener("abort", abort, { once: true });
		try {
			// Follow until the run reports its exit; a dropped connection follows again from where it was.
			for (let attempt = 0; exitCode === undefined && attempt < 20; attempt++) {
				let stderr = "";
				await exec(lease, followScript(lease, runId, new TextEncoder().encode(output).length), {
					stdout: (text) => {
						output += text;
						api.output(text);
					},
					stderr: (text) => (stderr += text),
				}).catch(() => undefined);
				const match = /CRABBOX_EXIT (\d+)/.exec(stderr);
				if (match) exitCode = Number(match[1]);
				else await sleep(2000);
			}
		} finally {
			clearTimeout(timeout);
			clearInterval(heartbeat);
			signal?.removeEventListener("abort", abort);
		}
		if (exitCode === undefined) throw new Error(`lost the command on box ${lease.host} (run ${runId}); its output so far:\n${tail(output)}`);
		const note = stopped ? ` (${stopped})` : "";
		const other = args.size && lease.size && args.size !== lease.size ? ` This session's box is ${lease.size}: crabbox_release it first to run on a ${args.size} machine.` : "";
		return {
			content: [{ type: "text", text: `${tail(output)}\n[exit code ${exitCode}${note} on Crabbox box ${lease.host} (${lease.size ?? "standard"}), ${lease.root}]${other}` }],
			isError: exitCode !== 0,
		};
	},
});

const pull = defineTool({
	name: "crabbox_pull",
	description: "Copy a file or folder from the Crabbox box's workspace copy back into this session's workspace (same relative path).",
	parameters: Type.Object({ path: Type.String({ description: "Path relative to the workspace, such as dist or build/app.log" }) }),
	replay: "safe",
	executionMode: "sequential",
	execute: async (args, api, context) => {
		const lease = await readLease(api);
		if (!lease?.host) throw new Error("This session has no Crabbox box yet; crabbox_run leases one.");
		const env = api.env;
		if (!env) throw new Error("no workspace");
		const path = args.path.replace(/^\.?\/+/, "");
		if (path.split("/").includes("..")) throw new Error("the path must stay inside the workspace");
		await env.exec("mkdir -p .crabbox", { cwd: env.cwd }, context);
		let errors = "";
		const packed = await exec(lease, `cd ${quote(lease.root!)} && tar czf - -- ${quote(path)}`, {
			stdoutPath: `${env.cwd}/.crabbox/pull.tgz`,
			stderr: (text) => (errors += text),
			signal: context.abortSignal,
		});
		if (packed.exitCode !== 0) throw new Error(`could not pack ${path} on the box: ${errors.trim() || `exit ${packed.exitCode}`}`);
		const unpacked = await env.exec("tar xzf .crabbox/pull.tgz -C . && rm .crabbox/pull.tgz", { cwd: env.cwd }, context);
		if (!unpacked.ok || unpacked.value.exitCode !== 0) throw new Error(`could not unpack ${path} into the workspace`);
		return { content: [{ type: "text", text: `Copied ${path} from the box into the workspace.` }] };
	},
});

const release = defineTool({
	name: "crabbox_release",
	description: "Give the session's Crabbox box back (it stops costing money). A later crabbox_run leases a new one.",
	parameters: Type.Object({}),
	execute: async (_args, api) => {
		const lease = await readLease(api);
		if (!lease) return { content: [{ type: "text", text: "This session has no Crabbox box." }] };
		await releaseLease(lease);
		await writeLease(api, null);
		return { content: [{ type: "text", text: `Released Crabbox lease ${lease.id}.` }] };
	},
});

const status = defineTool({
	name: "crabbox_status",
	description: "The session's Crabbox box (host, provider, expiry), if it has one.",
	parameters: Type.Object({}),
	replay: "safe",
	execute: async (_args, api) => {
		const lease = await readLease(api);
		if (!lease?.host) return { content: [{ type: "text", text: "This session has no Crabbox box; crabbox_run leases one." }] };
		const { lease: current } = await broker<{ lease: BrokerLease }>("GET", `/v1/leases/${encodeURIComponent(lease.id)}`);
		return {
			content: [
				{
					type: "text",
					text: `Lease ${lease.id}: ${current.state}, a ${lease.size ?? "standard"} box on ${current.provider ?? lease.provider} (${lease.user}@${lease.host}), workspace copy ${lease.root}, expires ${current.expiresAt ?? lease.expiresAt}.`,
				},
			],
		};
	},
});

async function releaseLease(lease: Lease): Promise<void> {
	try {
		await broker("POST", `/v1/leases/${encodeURIComponent(lease.id)}/release`, { delete: true });
	} catch (error) {
		// Already gone (released, expired) is fine.
		if (!(error instanceof BrokerError && (error.status === 404 || error.status === 409))) throw error;
	}
	await request("crabbox", "forgetKey", { keyId: lease.id });
}

/** When a session is deleted: its box goes back. */
export async function releaseSessionLease(harness: Harness, id: number, context: Context): Promise<void> {
	const lease = (await harness.snapshot(CrabboxDoc, id as ConversationId, context))?.lease;
	if (lease) await releaseLease(lease).catch((error) => console.warn(`crabbox: releasing ${lease.id}: ${error}`));
}

export const CrabboxTools = defineExtension({
	name: "crabbox",
	sections: [
		section(
			"crabbox",
			() =>
				"A real Linux machine is available through Crabbox for what this phone cannot do (Node and npm, compilers, Docker, apt packages, builds, test suites): crabbox_run runs a bash command there in a copy of this workspace, crabbox_pull brings files back, crabbox_release gives the box back when you are done. The phone stays your workspace; the box is for running.",
		),
	],
	tools: [run, pull, release, status],
});
