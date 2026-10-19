import type { JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type AuthType, clampThinkingLevel, getSupportedThinkingLevels, type Message, type Model, type ModelThinkingLevel, Type } from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { createProvider, type MutableModels } from "@earendil-works/pi-ai/models";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import {
	type AgentEventStream,
	type Conversation,
	AgentDoc,
	type CompactionPolicy,
	type ContextEdit,
	type ConversationId,
	type Cursor,
	type EntryRecord,
	DEFAULT_COMPACTION_POLICY,
	createRegistry,
	type EntryId,
	type Extension,
	defineExtension,
	defineTool,
	Harness,
	type Submission,
	watchEvents,
} from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { CodingTools } from "./read.ts";
import { loadDeviceId, NativeCredentialStore, runLogin } from "./auth.ts";
import { browserTools } from "./browser.ts";
import { CrabboxTools, crabboxAvailable, refreshCrabbox, releaseSessionLease } from "./crabbox.ts";
import { environmentGuide, setDevice } from "./environment.ts";
import { GitHubTools, githubLogin, refreshGitHub } from "./github.ts";
import { cancelMcpSignIn, listMcp, mcpAuthorizationResponse, mcpExtension, onMcpExtensionChange, reconnectMcp, refreshMcp, resumeMcp, signedOutMcp, signInMcp } from "./mcp.ts";
import { refreshSecrets } from "./secrets.ts";
import { expandSkillCommand, forgetSkills, sessionSkills, setSkillRoots, SkillsExtension, skillsIn } from "./skills.ts";
import { emit, forwardConsole, gateCommands, onCommand, request } from "./bridge.ts";
import { NativeExecutionEnv } from "./env.ts";
import { type BashResult, customMessageEntry, setConfiguredProviders, wrapModels } from "./extensions/adapter.ts";
import { type ExtensionRecord, Extensions, SessionExtensionsDoc, type SharedExtension } from "./extensions/manager.ts";
import { PanelTools } from "./extensions/panels.ts";
import { configureApps, SessionAppsDoc } from "./extensions/apps.ts";
import { setTranspileCache } from "./extensions/runtime.ts";
import { contextUsage } from "./context.ts";
import { VaultTools } from "./vault.ts";
import { BASH_ENTRY, SYSTEM_PROMPT_ENTRY } from "./extensions/session.ts";
import { installNativeFetch } from "./net.ts";
import { type SessionMeta, SessionsDoc, createSession, submissionReply, type TranscriptItem, transcriptOf } from "./sessions.ts";
import { NativeSqliteDatabase } from "./storage.ts";
import { appendWire, countOf, entriesAfter, hasEntriesAfter, idAt, ReplicaDoc, type Runs, type WireEntry, withIds } from "./replica.ts";

const context = BACKGROUND_CONTEXT;
const NEW_SESSION_TITLE = "New session";

/** An OpenAI-compatible endpoint the app adds next to pi's built-in providers (on-device llama-server, Ollama, …). */
type CustomProvider = {
	id: string;
	name: string;
	baseUrl: string;
	apiKey?: string;
	models: { id: string; name?: string; contextWindow?: number; maxTokens?: number }[];
};

type Engine = {
	models: MutableModels;
	harness: Harness;
	/** Holds the session list document; sessions are separate conversations. */
	root: Conversation;
	sessionsRoot: string;
	deviceId: string;
	customIds: Set<string>;
	watchers: Map<number, AgentEventStream>;
	extensions: Extensions;
	/** The browser's extension; its tools stay out of a session's requests until turned on (`showBrowserTools`). */
	browser: Extension;
	/** Automatic compaction's thresholds (pi's, unless a test changed them). */
	compaction: CompactionPolicy;
};

let engine: Engine | undefined;

forwardConsole();
installNativeFetch();
// pi-ai loads its OAuth flows through bundler-opaque imports; register them statically for this single-file bundle.
registerBunOAuthFlows();

/** Debug tool for durability tests (`debugTools`): slow enough to kill the engine mid-call. Not replay-safe. */
const slowCount = defineTool({
	name: "slow_count",
	description: "Count from 1 to n, one number per second. Use it when asked to count slowly.",
	parameters: Type.Object({ n: Type.Number({ minimum: 1, maximum: 60 }) }),
	execute: async (args, api) => {
		for (let i = 1; i <= args.n; i++) {
			await new Promise((resolve) => setTimeout(resolve, 1000));
			api.output(`${i}\n`);
		}
		return {};
	},
});

function requireEngine(): Engine {
	if (!engine) throw new Error("Engine is not open");
	return engine;
}

const sessionDirectory = (sessionsRoot: string, id: number) => `${sessionsRoot}/${id}`;

type OpenParams = {
	storage: string;
	sessionsRoot: string;
	extensionsRoot: string;
	tmp?: string;
	/** Where transpiled extension code is kept between launches. */
	cache?: string;
	providers?: CustomProvider[];
	debugTools?: boolean;
	/** Automatic compaction's thresholds, over pi's (tests). */
	compaction?: Partial<CompactionPolicy>;
	/**
	 * After the app replaced a page that stopped answering: extensions that were working then, turned off rather than
	 * loaded (a default stays off), and sessions whose runs are aborted rather than resumed, so whatever froze the
	 * engine doesn't run again.
	 */
	recover?: { extensions?: string[]; abort?: number[] };
	/** The device pi runs on, for the agent (`setDevice`), and whether its sessions sync. */
	device?: { kind: string; name: string; sync: boolean };
};

/**
 * The store opens in two steps: its sessions are listed (`listed`), then extensions load, sessions' event streams
 * start and unfinished runs resume (`opened`), after `open` has returned. The app shows the sessions of its last launch
 * before either, so what it asks for early waits rather than fails: a transcript (which only reads the store) for the
 * first step, everything else for the second.
 */
let settleListed!: () => void;
const listed = new Promise<void>((resolve) => {
	settleListed = resolve;
});
let settleOpen!: () => void;
const opened = new Promise<void>((resolve) => {
	settleOpen = resolve;
});
const READS_STORE = new Set(["session.transcript"]);
gateCommands((method) => (method === "open" ? Promise.resolve() : READS_STORE.has(method) ? listed : opened));

onCommand("open", async (params: OpenParams) => {
	try {
		const { sessions, rest } = await openStore(params);
		void rest()
			.catch((error: unknown) => console.warn(`open: ${error instanceof Error ? error.message : String(error)}`))
			.finally(settleOpen);
		return { sessions, resumed: [] };
	} catch (error) {
		settleOpen();
		throw error;
	} finally {
		settleListed();
	}
});

/**
 * Opens the durable store and lists its sessions; `rest` then loads extensions, starts the sessions' event streams and
 * resumes any run a previous engine left unfinished (reported in a `sessions_resumed` event).
 */
async function openStore(params: OpenParams) {
	if (engine) {
		for (const watcher of engine.watchers.values()) await watcher.stop();
		await engine.harness.close(context);
	}
	const models = builtinModels({ credentials: new NativeCredentialStore() });
	const customIds = new Set<string>();
	for (const provider of params.providers ?? []) setCustomProvider(models, customIds, provider);

	const { sessionsRoot } = params;
	if (params.device) setDevice(params.device);
	// The app's own temporary directory (os.tmpdir() in extensions): an iPhone app can't write to /tmp.
	const tmp: Record<string, string> = params.tmp ? { TMPDIR: params.tmp } : {};
	if (params.cache) setTranspileCache(params.cache);
	const sessionEnv = (id: number) => {
		const directory = sessionDirectory(sessionsRoot, id);
		return { cwd: directory, home: directory, env: { HOME: directory, PYTHONUSERBASE: `${directory}/.python`, ...tmp } };
	};
	const registry = createRegistry();
	const extensions = new Extensions(
		registry,
		params.extensionsRoot,
		sessionEnv,
		{ cwd: sessionsRoot, home: sessionsRoot, env: { HOME: sessionsRoot, ...tmp } },
		{
			harness: () => requireEngine().harness,
			models: () => requireEngine().models,
			sessionName: async (id) => (await listSessions()).find((session) => session.id === id)?.title,
			setSessionName: (id, name) => renameSession(id, name),
			setModel: (id, provider, modelId) => setSessionModel(id, provider, modelId),
			setThinkingLevel: async (id, level) => {
				await setSessionThinkingLevel(id, level);
			},
			submitted: (id, submission) => track(id, submission),
			fork: async (id, entryId) => (await forkSession(id, entryId))?.id,
		},
	);
	// Skills for every session (pi's ~/.pi/agent/skills), the session's own, then its extension packages'.
	setSkillRoots(async (id, cwd) => {
		const workspace = cwd ?? sessionDirectory(sessionsRoot, id);
		return [
			{ dir: `${extensions.agentDir}/skills`, source: "user" },
			{ dir: `${workspace}/.pi/skills`, source: "project" },
			{ dir: `${workspace}/.agents/skills`, source: "project" },
			...(await extensions.skillRoots(id, context)),
		];
	});
	const browser = browserTools(() => requireEngine().models);
	const builtIn = [
		// First, so its section opens the system prompt.
		environmentGuide((browser.tools ?? []).map((tool) => tool.name)),
		SkillsExtension,
		CodingTools,
		browser,
		VaultTools,
		PanelTools,
		extensions.extension(() => requireEngine().root.id),
		// Selected only while a Crabbox broker is set up and signed in (below).
		CrabboxTools,
		// Selected only while the user is signed in to GitHub.
		GitHubTools,
		...(params.debugTools ? [defineExtension({ name: "debug", tools: [slowCount] })] : []),
	];
	for (const extension of builtIn) registry.install(extension);
	// MCP servers' tools change as servers connect: the rebuilt extension replaces the installed one.
	registry.install(mcpExtension());
	onMcpExtensionChange((extension) => registry.install(extension));

	const compaction: CompactionPolicy = {
		...DEFAULT_COMPACTION_POLICY,
		...(params.debugTools ? { keepRecentTokens: 64 } : {}),
		...params.compaction,
	};
	const storage = await SqliteStorage.open(await NativeSqliteDatabase.open(params.storage));
	const harness = await Harness.open(
		storage,
		{
			// Requests carry the provider events extensions listen to.
			models: wrapModels(models),
			registry,
			// Every session gets the built-in extensions and the default ones; a session adds its own on top.
			settings: {
				get extensions() {
					return [
						...builtIn.filter((extension) => (extension !== CrabboxTools || crabboxAvailable()) && (extension !== GitHubTools || githubLogin() !== null)),
						mcpExtension(),
						...extensions.defaults,
					];
				},
				// A phone's network drops for longer than pi's default retries (3, about 14 seconds) cover: moving to the
				// background, a VPN such as WARP reconnecting, Wi-Fi to cellular. Six retries wait about two minutes.
				retry: { maxRetries: 6 },
				// pi's automatic compaction (pi-durable's defaults are pi's). Debug runs keep little verbatim, so a manual
				// compaction of a short session has something to summarize.
				compaction,
			},
			// Each session's tools run in its own workspace, with its own HOME and Python environment.
			env: ({ conversationId, cwd }) => {
				const directory = sessionDirectory(sessionsRoot, conversationId);
				return new NativeExecutionEnv({
					cwd: cwd ?? directory,
					home: directory,
					environment: { HOME: directory, PYTHONUSERBASE: `${directory}/.python` },
				});
			},
		},
		context,
	);
	const root = await harness.root(context);
	engine = {
		models,
		harness,
		root,
		sessionsRoot,
		deviceId: await loadDeviceId(),
		customIds,
		watchers: new Map(),
		extensions,
		browser,
		compaction,
	};
	// Apps keep their records in the sessions and, shared, in the root conversation.
	configureApps({ harness: () => requireEngine().harness, rootId: () => requireEngine().root.id });

	const sessions = await listSessions();
	return { sessions, rest: () => finishOpen(sessions, sessionsRoot, browser, extensions, params.recover) };
}

async function finishOpen(
	sessions: SessionMeta[],
	sessionsRoot: string,
	browser: ReturnType<typeof browserTools>,
	extensions: Extensions,
	recover: OpenParams["recover"],
) {
	const { harness, root } = requireEngine();
	// iOS moves the app's container (on updates and reinstalls), so a session's stored working directory can point
	// at the old one: point it at the session's directory again.
	for (const session of sessions) {
		const conversation = await harness.conversation(session.id as ConversationId, context);
		const directory = sessionDirectory(sessionsRoot, session.id);
		if (conversation && (await conversation.agent(context)).cwd !== directory) {
			await request("fs", "mkdir", { path: directory, recursive: true });
			await conversation.configure({ cwd: directory }, context);
		}
		// Sessions from before the browser's tools were hidden by default get them hidden too.
		if (conversation && (await harness.snapshot(AgentDoc, conversation.id, context))?.tools === undefined) {
			await conversation.configure({ tools: { remove: browser.tools ?? [] } }, context);
		}
	}
	// Crabbox's tools are offered while a broker is signed in; resumed runs may call them.
	await refreshCrabbox().catch((error) => console.warn(`crabbox: ${error}`));
	await refreshGitHub().catch((error) => console.warn(`github: ${error}`));
	await refreshSecrets().catch((error) => console.warn(`secrets: ${error}`));
	// The servers' last tool lists at once; connections in the background.
	await refreshMcp().catch((error) => console.warn(`mcp: ${error}`));
	// After a frozen page: the extensions that were working then stay off, and the runs that were going stop.
	const held = recover?.extensions ?? [];
	for (const name of held) await extensions.setDefaultEnabled(root, name, false, context).catch(() => {});
	extensions.hold(held);
	for (const id of recover?.abort ?? []) {
		const conversation = await harness.conversation(id as ConversationId, context).catch(() => undefined);
		await conversation?.abort(context).catch((error: unknown) => console.warn(`recover: abort ${id}: ${error}`));
	}
	// Extensions first: resumed runs may call their tools.
	await extensions.restore(harness, root, sessions.map((session) => session.id), context);
	// Defaults installed from GitHub whose folder changed: in the background.
	void extensions.updateFromGitHub(root, context).catch((error) => console.warn(`extension updates: ${error}`));
	await Promise.all(sessions.map((session) => watch(session.id)));
	harness.resume();
	const resumed: { sessionId: number; submissionId: number }[] = [];
	for (const record of (await harness.inspect(context)).submissions) {
		const submission = await harness.submission(record.id, context);
		if (!submission) continue;
		track(record.conversationId, submission);
		resumed.push({ sessionId: record.conversationId, submissionId: submission.id });
	}
	emit({ type: "sessions_resumed", resumed });
}

onCommand("providers.setCustom", ({ providers }: { providers: CustomProvider[] }) => {
	const { models, customIds } = requireEngine();
	for (const provider of providers) setCustomProvider(models, customIds, provider);
	return null;
});

/** Providers with their login methods and, for configured ones, their models. */
onCommand("providers.list", async () => {
	const { models, customIds } = requireEngine();
	const providers = [];
	const signIns: [string, "api_key" | "oauth" | "custom"][] = [];
	for (const provider of models.getProviders()) {
		const check = customIds.has(provider.id) ? undefined : await models.checkAuth(provider.id);
		const configured = customIds.has(provider.id) || check !== undefined;
		if (configured) signIns.push([provider.id, check?.type ?? "custom"]);
		providers.push({
			id: provider.id,
			name: provider.name,
			custom: customIds.has(provider.id),
			configured,
			apiKey: provider.auth.apiKey
				? { name: provider.auth.apiKey.name, canLogin: provider.auth.apiKey.login !== undefined }
				: undefined,
			oauth: provider.auth.oauth
				? {
						name: provider.auth.oauth.name,
						loginLabel: provider.auth.oauth.loginLabel,
						isSubscription: provider.auth.oauth.isSubscription === true,
					}
				: undefined,
			models: configured
				? models.getModels(provider.id).map((model) => ({
						id: model.id,
						name: model.name,
						contextWindow: model.contextWindow,
						reasoning: model.reasoning,
						thinkingLevels: model.reasoning ? getSupportedThinkingLevels(model) : ["off"],
					}))
				: [],
		});
	}
	setConfiguredProviders(signIns);
	return providers;
});

onCommand("auth.login", ({ providerId, type }: { providerId: string; type: AuthType }) => {
	const { models, deviceId } = requireEngine();
	return runLogin(models, providerId, type, deviceId);
});

onCommand("auth.logout", async ({ providerId }: { providerId: string }) => {
	await requireEngine().models.logout(providerId);
	return null;
});

onCommand("session.list", () => listSessions());

/** For the app's watchdog: answers at once unless something holds the engine's thread. */
onCommand("ping", () => "pong");

/** The app signed in to a Crabbox broker, or out: the tools follow. */
onCommand("crabbox.changed", async () => ({ available: await refreshCrabbox() }));
/** After the user changed extension secrets in Settings: extensions see the change at once. */
onCommand("secrets.changed", async () => {
	await refreshSecrets();
	return null;
});

/** Settings → MCP servers. */
onCommand("mcp.list", () => listMcp());
/** The user added, changed, or removed a server: connect what changed. */
onCommand("mcp.changed", async () => {
	await refreshMcp();
	return listMcp();
});
/** Resolves once signed in and connected; the app shows the authorization page meanwhile (`mcp_auth_url`). */
onCommand("mcp.signIn", async ({ name }: { name: string }) => {
	await signInMcp(name);
	return listMcp();
});
/** The app's sign-in view caught a server's redirect (a redirect URL that isn't loopback). */
onCommand("mcp.authorizationResponse", ({ url }: { url: string }) => {
	mcpAuthorizationResponse(url);
	return null;
});
onCommand("mcp.cancelSignIn", async () => {
	await cancelMcpSignIn();
	return null;
});
onCommand("mcp.signedOut", async ({ name }: { name: string }) => {
	await signedOutMcp(name);
	return null;
});
onCommand("mcp.reconnect", async ({ name }: { name: string }) => {
	await reconnectMcp(name);
	return listMcp();
});
/** The app is in the foreground again. */
onCommand("mcp.resume", () => {
	resumeMcp();
	return null;
});

onCommand("github.changed", async () => {
	await refreshGitHub();
	return { login: githubLogin() };
});

onCommand(
	"session.create",
	async ({
		provider,
		modelId,
		title,
		browser,
		requestId,
		thinkingLevel,
	}: { provider: string; modelId: string; title?: string; browser?: string; requestId?: string; thinkingLevel?: string }) => {
		const { harness, root, sessionsRoot } = requireEngine();
		const session = await createSession(root, {
			title: title ?? NEW_SESSION_TITLE,
			model: { provider, modelId },
			browser: browser ?? null,
			...(requestId ? { creationRequestId: requestId } : {}),
		}, context);
		const conversation = await requireConversation(session.id);
		const directory = sessionDirectory(sessionsRoot, session.id);
		const agent = await harness.snapshot(AgentDoc, conversation.id, context);
		if (!agent?.cwd) {
			await request("fs", "mkdir", { path: directory, recursive: true });
			await conversation.configure({ cwd: directory, tools: { remove: requireEngine().browser.tools ?? [] } }, context);
		}
		// The app's default for new sessions, as this model takes it.
		if (thinkingLevel && thinkingLevel !== "off" && session.thinkingLevel === undefined) {
			session.thinkingLevel = await setSessionThinkingLevel(session.id, thinkingLevel);
		}
		await watch(session.id);
		return { ...session, workspace: directory };
	},
);

/** How many rows the app loads at a time: the latest when a session opens, then as many earlier ones each time the reader
 * scrolls to the top. A session can run to tens of millions of tokens; its whole transcript would be too much to send and
 * to hold. */
const TRANSCRIPT_PAGE = 150;

/**
 * Where the next earlier page of a transcript ends: within the context's rows (`context`: the first one shown), or among
 * the entries before the context (`before`: an entry ID). After a compaction the context starts with its summary, a newer
 * entry than the ones it kept that follow it, so the rows aren't in ID order and a page can't just be "before the first".
 */
type TranscriptCursor = { context?: number; before?: number };

/**
 * A session's transcript, a page at a time: without `earlier` its latest rows, with it the rows before that. `earlier` in
 * the result is where the next page ends (null at the start). What came before a compaction shows too, after the rows of
 * the context (which starts at the compaction's summary, the entries it kept following).
 */
onCommand("session.transcript", async ({ id, limit, earlier }: { id: number; limit?: number; earlier?: TranscriptCursor }) => {
	const count = Math.max(1, Math.min(limit ?? TRANSCRIPT_PAGE, 2000));
	const stream = await watchEvents(requireEngine().harness, id as ConversationId, context);
	const { entries, run } = stream.snapshot;
	await stream.stop();
	const running = run !== undefined;
	if (earlier?.before !== undefined) return { ...(await transcriptBefore(id, earlier.before, count)), running };
	const rows = transcriptOf(entries);
	const end = Math.min(earlier?.context ?? rows.length, rows.length);
	const start = toCall(rows, Math.max(0, end - count));
	const items = rows.slice(start, end);
	if (start > 0) return { items, earlier: { context: start }, running };
	// The context's first rows: what came before it fills the page.
	const head = (entries[0] as { head?: number } | undefined)?.head;
	if (head === undefined) return { items, earlier: null, running };
	if (items.length >= count) return { items, earlier: { before: head }, running };
	const before = await transcriptBefore(id, head, count - items.length);
	return { items: [...before.items, ...items], earlier: before.earlier, running };
});

/** A page's start, moved back over tool results to the assistant message with their calls (a tool row shows its call). */
function toCall(rows: readonly TranscriptItem[], start: number): number {
	while (start > 0 && rows[start]?.kind === "tool") start--;
	return start;
}

/** The last `count` rows of the entries before `before`, read newest first a page at a time, and where the next page ends. */
async function transcriptBefore(id: number, before: number, count: number): Promise<{ items: TranscriptItem[]; earlier: TranscriptCursor | null }> {
	const conversation = await requireConversation(id);
	const newestFirst: EntryRecord[] = [];
	let cursor: Cursor | undefined;
	let rows: TranscriptItem[] = [];
	do {
		const page = await conversation.entries({ maxEntryId: (before - 1) as EntryId, order: "descending" }, 200, cursor, context);
		newestFirst.push(...page.items);
		cursor = page.next;
		rows = transcriptOf([...newestFirst].reverse());
		// Enough rows, and the page doesn't start with a tool result whose call is earlier.
	} while (cursor && (rows.length < count || rows[rows.length - count]?.kind === "tool"));
	const start = toCall(rows, Math.max(0, rows.length - count));
	const items = rows.slice(start);
	const more = start > 0 || cursor !== undefined;
	return { items, earlier: more && items[0] ? { before: items[0].entryId } : more ? { before } : null };
}

/** A session's entries before `before`, in order (the history a compaction took out of the context). */
async function entriesBefore(id: number, before: number): Promise<EntryRecord[]> {
	const conversation = await requireConversation(id);
	const entries: EntryRecord[] = [];
	let cursor: Cursor | undefined;
	do {
		const page = await conversation.entries({ maxEntryId: (before - 1) as EntryId }, 500, cursor, context);
		entries.push(...page.items);
		cursor = page.next;
	} while (cursor);
	return entries;
}

/** A shared session (`session.export`), as a `.pisession` file carries it. */
type SharedSession = {
	pi: string;
	version: number;
	title: string;
	model: { provider: string; modelId: string } | null;
	entries: { id: number; kind: string; model?: Message[]; data?: JsonValue; head?: number; edits?: (ContextEdit & { target: number })[] }[];
	agent: { thinkingLevel: string | null; instructions: string | null } | null;
	extensions: ExtensionRecord[];
	apps: unknown;
};

/**
 * A session to share (`.pisession`, the app adds its workspace's files): its details, every entry of its durable history in
 * order, its agent's settings, its own extensions, and its apps' records.
 */
onCommand("session.export", async ({ id }: { id: number }) => {
	const { harness } = requireEngine();
	const conversation = await requireConversation(id);
	const meta = (await listSessions()).find((session) => session.id === id);
	const entries: EntryRecord[] = [];
	let cursor: Cursor | undefined;
	do {
		const page = await conversation.entries({}, 500, cursor, context);
		entries.push(...page.items);
		cursor = page.next;
	} while (cursor);
	// Oldest first, as they're appended again (a compaction's head and an edit's target come before it).
	entries.sort((a, b) => a.id - b.id);
	const agent = await harness.snapshot(AgentDoc, id as ConversationId, context);
	const extensions = await harness.snapshot(SessionExtensionsDoc, id as ConversationId, context);
	const apps = await harness.snapshot(SessionAppsDoc, id as ConversationId, context);
	return {
		pi: "session",
		version: 1,
		title: meta?.title ?? NEW_SESSION_TITLE,
		model: meta?.model ?? agent?.model ?? null,
		createdAt: meta?.createdAt ?? Date.now(),
		lastActiveAt: meta?.lastActiveAt ?? null,
		entries: entries.map(({ id: entryId, kind, model, data, head, edits }) => ({ id: entryId, kind, model, data, head, edits })),
		agent: agent ? { thinkingLevel: (agent as { thinkingLevel?: unknown }).thinkingLevel ?? null, instructions: (agent as { instructions?: unknown }).instructions ?? null } : null,
		extensions: Object.values(extensions?.extensions ?? {}),
		apps: apps ?? null,
	};
});

/**
 * A shared session as a new one: its entries appended in order (ids are this store's, so a compaction's head and an
 * edit's target follow them), its agent's settings and its apps' records; with its model if this phone has it, else
 * `model` (the app's default). The app then puts its files in the workspace and calls `session.importExtensions`.
 */
onCommand(
	"session.import",
	async ({ shared, model: fallback }: { shared: SharedSession; model?: { provider: string; modelId: string } }) => {
		const { harness, root, sessionsRoot, models } = requireEngine();
		if (shared.pi !== "session" || !Array.isArray(shared.entries)) throw new Error("Not a shared pi session");
		const model = shared.model && models.getModel(shared.model.provider, shared.model.modelId) ? shared.model : (fallback ?? shared.model ?? undefined);
		const conversation = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: model ? { model } : {} }, context);
		const directory = sessionDirectory(sessionsRoot, conversation.id);
		await request("fs", "mkdir", { path: directory, recursive: true });
		await conversation.configure({ cwd: directory, tools: { remove: requireEngine().browser.tools ?? [] } }, context);
		const ids = new Map<number, number>();
		await conversation.commit(async (tx) => {
			for (const entry of shared.entries) {
				const head = entry.head === undefined ? undefined : entry.head === entry.id ? "self" : ids.get(entry.head);
				const edits = entry.edits?.flatMap((edit) => (ids.has(edit.target) ? [{ ...edit, target: ids.get(edit.target)! as EntryId }] : []));
				const record = await tx.appendEntry(conversation.id, {
					kind: entry.kind,
					...(entry.model ? { model: entry.model } : {}),
					...(entry.data !== undefined ? { data: entry.data } : {}),
					...(head !== undefined ? { head: head as EntryId | "self" } : {}),
					...(edits?.length ? { edits } : {}),
				});
				ids.set(entry.id, record.id);
			}
			if (shared.apps) Object.assign(await tx.doc(SessionAppsDoc, conversation.id), JSON.parse(JSON.stringify(shared.apps)));
		}, context);
		if (shared.agent?.thinkingLevel || shared.agent?.instructions) {
			await conversation.configure(
				{
					...(shared.agent.thinkingLevel ? { thinkingLevel: shared.agent.thinkingLevel as never } : {}),
					...(shared.agent.instructions ? { instructions: shared.agent.instructions } : {}),
				},
				context,
			);
		}
		const session: SessionMeta = {
			id: conversation.id,
			title: shared.title || NEW_SESSION_TITLE,
			createdAt: Date.now(),
			model: model ?? { provider: "", modelId: "" },
			browser: null,
			...(shared.agent?.thinkingLevel ? { thinkingLevel: shared.agent.thinkingLevel } : {}),
		};
		await root.commit(async (tx) => {
			(await tx.doc(SessionsDoc, root.id)).sessions.push(session);
		}, context);
		await watch(conversation.id);
		console.log(`session ${conversation.id}: imported "${session.title}" (${shared.entries.length} entries)`);
		return { ...session, workspace: directory };
	},
);

/** The shared session's own extensions, once its files are in its workspace (`session.import`). */
onCommand("session.importExtensions", async ({ id, extensions: records }: { id: number; extensions: ExtensionRecord[] }) =>
	requireEngine().extensions.adoptSessionExtensions(id, records ?? [], context),
);

// ---- Sessions on the user's other devices (replica.ts; the app's SessionSync moves them through iCloud) ----

/** At most this many entries go in one `replica.export` (one chunk in iCloud). */
const REPLICA_CHUNK = 1000;

/** A session's details as they travel: listed before its entries arrive, and kept up to date on the other devices. */
type ReplicaMeta = {
	title: string;
	model: { provider: string; modelId: string } | null;
	thinkingLevel: string | null;
	createdAt: number;
	lastActiveAt: number | null;
};
/** A session's settings that travel: its agent's, its own extensions (loaded once a device takes it), its apps' records. */
type ReplicaDocs = {
	agent: { thinkingLevel: string | null; instructions: string | null } | null;
	extensions: JsonValue | null;
	apps: JsonValue | null;
};

/** Fails while another device has the session: it's read-only here until the user continues it here. */
async function requireHeldHere(id: number): Promise<void> {
	const heldBy = (await listSessions()).find((session) => session.id === id)?.heldBy;
	if (heldBy) throw new Error(`This session is on ${heldBy} now. Tap Continue Here to continue it on this device.`);
}

async function replicaRuns(id: number): Promise<Runs> {
	return ((await requireEngine().harness.snapshot(ReplicaDoc, id as ConversationId, context))?.runs ?? []) as Runs;
}

/**
 * What the other devices don't have yet of a session this device has: its entries after theirs (`base` of them), at most
 * a chunk (`more`: there are others after it), its details and settings; and its id across devices, given now if it had
 * none. Once they're in iCloud, `replica.uploaded` records the entries as everyone's.
 */
onCommand("replica.export", async ({ id, limit }: { id: number; limit?: number }) => {
	const { harness } = requireEngine();
	const conversation = await requireConversation(id);
	if (!(await listSessions()).find((session) => session.id === id)?.syncId) {
		const syncId = crypto.randomUUID();
		await updateSession(id, (session) => {
			session.syncId ??= syncId;
		});
	}
	const meta = (await listSessions()).find((session) => session.id === id);
	if (!meta?.syncId) throw new Error(`No session ${id}`);
	const runs = await replicaRuns(id);
	const { entries, ids, more } = await entriesAfter(conversation, runs, Math.max(1, Math.min(limit ?? REPLICA_CHUNK, 5000)), context);
	const agent = (await harness.snapshot(AgentDoc, id as ConversationId, context)) as { thinkingLevel?: string; instructions?: string } | undefined;
	const extensions = await harness.snapshot(SessionExtensionsDoc, id as ConversationId, context);
	const apps = await harness.snapshot(SessionAppsDoc, id as ConversationId, context);
	const docs: ReplicaDocs = {
		agent: { thinkingLevel: agent?.thinkingLevel ?? null, instructions: agent?.instructions ?? null },
		extensions: (extensions ?? null) as JsonValue,
		apps: (apps ?? null) as JsonValue,
	};
	const details: ReplicaMeta = {
		title: meta.title,
		model: meta.model,
		thinkingLevel: meta.thinkingLevel ?? null,
		createdAt: meta.createdAt,
		lastActiveAt: meta.lastActiveAt ?? null,
	};
	return { syncId: meta.syncId, base: countOf(runs), entries, ids, more, meta: details, docs };
});

/** The entries `replica.export` gave are in iCloud: every device has them now. */
onCommand("replica.uploaded", async ({ id, ids }: { id: number; ids: number[] }) => {
	const conversation = await requireConversation(id);
	const runs = await replicaRuns(id);
	const last = idAt(runs, countOf(runs) - 1) ?? -1;
	const next = withIds(runs, (ids ?? []).filter((entryId) => entryId > last));
	await conversation.commit(async (tx) => {
		(await tx.doc(ReplicaDoc, conversation.id)).runs = next;
	}, context);
	return { count: countOf(next) };
});

/**
 * Another device's session, as far as iCloud has it: added here (readable, but read-only until the user continues it
 * here: `heldBy`), or brought up to date with the entries after the `base` it had. `missing`: this device has fewer
 * than `base` (send from there); `diverged`: it has entries no other device has (`replica.split` them off first).
 */
onCommand(
	"replica.apply",
	async ({
		syncId,
		base,
		entries,
		meta,
		docs,
		heldBy,
		model: fallback,
	}: {
		syncId: string;
		base: number;
		entries: WireEntry[];
		meta: ReplicaMeta;
		docs: ReplicaDocs | null;
		heldBy: string | null;
		model?: { provider: string; modelId: string };
	}) => {
		const { harness, root, sessionsRoot, models, browser } = requireEngine();
		const known = (model: ReplicaMeta["model"]) => (model && models.getModel(model.provider, model.modelId) ? model : undefined);
		let session = (await listSessions()).find((candidate) => candidate.syncId === syncId);
		let created = false;
		if (!session) {
			if (base !== 0) return { id: null, missing: 0 };
			// Its model if this device has it, else the app's default.
			const model = known(meta.model) ?? fallback ?? meta.model ?? undefined;
			const conversation = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: model ? { model } : {} }, context);
			const directory = sessionDirectory(sessionsRoot, conversation.id);
			await request("fs", "mkdir", { path: directory, recursive: true });
			await conversation.configure({ cwd: directory, tools: { remove: browser.tools ?? [] } }, context);
			const added: SessionMeta = {
				id: conversation.id,
				title: meta.title || NEW_SESSION_TITLE,
				createdAt: meta.createdAt || Date.now(),
				...(meta.lastActiveAt ? { lastActiveAt: meta.lastActiveAt } : {}),
				model: model ? { provider: model.provider, modelId: model.modelId } : { provider: "", modelId: "" },
				browser: null,
				syncId,
				...(heldBy ? { heldBy } : {}),
			};
			await root.commit(async (tx) => {
				(await tx.doc(SessionsDoc, root.id)).sessions.push(added);
			}, context);
			await watch(conversation.id);
			session = added;
			created = true;
		}
		const id = session.id;
		const conversation = await requireConversation(id);
		const runs = await replicaRuns(id);
		const count = countOf(runs);
		if (count < base) return { id, missing: count };
		if (await hasEntriesAfter(conversation, runs, context)) return { id, diverged: true, count };
		const fresh = (entries ?? []).slice(count - base);
		const total = await conversation.commit(async (tx) => {
			const ids = await appendWire(tx, conversation.id, runs, fresh);
			const next = withIds(runs, ids);
			const replica = await tx.doc(ReplicaDoc, conversation.id);
			replica.runs = next;
			if (docs?.extensions) replica.extensions = JSON.parse(JSON.stringify(docs.extensions)) as JsonValue;
			if (docs?.apps) {
				const value = JSON.parse(JSON.stringify(docs.apps)) as { apps?: Record<string, JsonValue>; states?: Record<string, JsonValue> };
				const apps = await tx.doc(SessionAppsDoc, conversation.id);
				Object.assign(apps, { apps: value.apps ?? {}, states: value.states ?? {} });
			}
			return countOf(next);
		}, context);
		// Its settings, as the device that has it set them (the model only if this device has it).
		const model = known(meta.model);
		const agent = docs?.agent;
		if (model || agent?.thinkingLevel || agent?.instructions) {
			await conversation.configure(
				{
					...(model ? { model } : {}),
					...(agent?.thinkingLevel ? { thinkingLevel: agent.thinkingLevel as ModelThinkingLevel } : {}),
					...(agent?.instructions ? { instructions: agent.instructions } : {}),
				},
				context,
			);
		}
		await updateSession(id, (target) => {
			target.title = meta.title || target.title;
			if (meta.lastActiveAt) target.lastActiveAt = meta.lastActiveAt;
			if (model) target.model = { provider: model.provider, modelId: model.modelId };
			if (meta.thinkingLevel) target.thinkingLevel = meta.thinkingLevel;
			else delete target.thinkingLevel;
			if (heldBy) target.heldBy = heldBy;
			else delete target.heldBy;
		});
		if (created) emit({ type: "session_added", session: (await listSessions()).find((candidate) => candidate.id === id) });
		return { id, count: total, created, added: fresh.length };
	},
);

/**
 * A session this device added to while another device had it (offline, say): what all devices share goes on as the
 * session everyone syncs (a fork at the last entry they share, with a copy of the files), and this device's additions
 * stay in the session they were made in, now one of its own (`label` in its title) that syncs from here.
 */
onCommand("replica.split", async ({ id, label }: { id: number; label: string }) => {
	const { root, sessionsRoot, harness } = requireEngine();
	const meta = (await listSessions()).find((session) => session.id === id);
	if (!meta?.syncId) throw new Error(`Session ${id} doesn't sync`);
	const runs = await replicaRuns(id);
	const title = `${meta.title} (${label})`;
	const last = idAt(runs, countOf(runs) - 1);
	if (last === undefined) {
		// Nothing shared: the other device's session comes in as a new one.
		await updateSession(id, (session) => {
			delete session.syncId;
			delete session.heldBy;
			session.title = title;
		});
		return { id: null, kept: id };
	}
	const source = await requireConversation(id);
	const fork = await source.fork(last as EntryId, { ownership: { kind: "ownerless" } }, context);
	const directory = sessionDirectory(sessionsRoot, fork.id);
	try {
		await request("fs", "copy", { from: sessionDirectory(sessionsRoot, id), to: directory });
	} catch {
		await request("fs", "mkdir", { path: directory, recursive: true });
	}
	await fork.configure({ cwd: directory }, context);
	const pending = (await harness.snapshot(ReplicaDoc, id as ConversationId, context))?.extensions ?? null;
	await fork.commit(async (tx) => {
		const replica = await tx.doc(ReplicaDoc, fork.id);
		replica.runs = runs;
		replica.extensions = JSON.parse(JSON.stringify(pending)) as JsonValue;
	}, context);
	await source.commit(async (tx) => {
		(await tx.doc(ReplicaDoc, source.id)).runs = [];
	}, context);
	const session: SessionMeta = {
		id: fork.id,
		title: meta.title,
		createdAt: meta.createdAt,
		...(meta.lastActiveAt ? { lastActiveAt: meta.lastActiveAt } : {}),
		model: { provider: meta.model.provider, modelId: meta.model.modelId },
		browser: meta.browser ?? null,
		...(meta.thinkingLevel ? { thinkingLevel: meta.thinkingLevel } : {}),
		syncId: meta.syncId,
	};
	await root.commit(async (tx) => {
		const doc = await tx.doc(SessionsDoc, root.id);
		doc.sessions.push(session);
		const kept = doc.sessions.find((candidate) => candidate.id === id);
		if (kept) {
			delete kept.syncId;
			delete kept.heldBy;
			kept.title = title;
		}
	}, context);
	await watch(fork.id);
	emit({ type: "session_added", session });
	const kept = (await listSessions()).find((candidate) => candidate.id === id);
	if (kept) emit({ type: "session_updated", session: kept });
	return { id: fork.id, kept: id };
});

/**
 * The user continues here a session another device had: it's this device's now, and the agent reads where it moved
 * from (`from`, `to`: the devices' names). The session's own extensions load here, as the other device had them.
 */
onCommand("replica.claim", async ({ id, from, to }: { id: number; from: string; to: string }) => {
	const { harness, extensions } = requireEngine();
	const conversation = await requireConversation(id);
	await updateSession(id, (session) => {
		delete session.heldBy;
	});
	const text =
		`This session moved from ${from} to ${to}. Its history and workspace files came along, except installed Python packages (.python), which need installing again. ` +
		`Whatever was still running on ${from} (a command, a Crabbox box) and its browser sign-ins stayed there. Check the workspace before you rely on earlier results.`;
	await conversation.submit({ type: "write", entry: customMessageEntry({ customType: "pimobile.moved", content: text, display: true, details: { from, to } }) }, context);
	const pending = (await harness.snapshot(ReplicaDoc, id as ConversationId, context))?.extensions as { extensions?: Record<string, ExtensionRecord> } | null | undefined;
	const current = (await harness.snapshot(SessionExtensionsDoc, id as ConversationId, context))?.extensions ?? {};
	// The ones this device doesn't have as they are (it may have had the session before).
	const records = Object.values(pending?.extensions ?? {}).filter((record) => JSON.stringify(current[record.name]) !== JSON.stringify(record));
	return records.length ? await extensions.adoptSessionExtensions(id, records, context) : { added: [], skipped: [] };
});

/**
 * Another device has the session now (`heldBy`; null: none does): read-only here. A run it had here stops (what it adds
 * from now on stays here, `replica.split`), and its Crabbox box is given back.
 */
onCommand("replica.setHolder", async ({ id, heldBy }: { id: number; heldBy: string | null }) => {
	const { harness } = requireEngine();
	await updateSession(id, (session) => {
		if (heldBy) session.heldBy = heldBy;
		else delete session.heldBy;
	});
	if (heldBy) {
		const stream = await watchEvents(harness, id as ConversationId, context);
		const running = stream.snapshot.run !== undefined;
		await stream.stop();
		if (running) await (await requireConversation(id)).abort(context);
		await releaseSessionLease(harness, id, context);
	}
	return null;
});

/** The sessions this device has with entries the other devices don't have yet (or that never synced). */
onCommand("replica.unsent", async () => {
	const ids: number[] = [];
	for (const session of await listSessions()) {
		if (session.heldBy) continue;
		const conversation = await requireEngine().harness.conversation(session.id as ConversationId, context);
		if (!session.syncId || (conversation && (await hasEntriesAfter(conversation, await replicaRuns(session.id), context)))) ids.push(session.id);
	}
	return { ids };
});

/** The device pi runs on, and whether sessions sync, for the agent's environment section. */
onCommand("replica.device", ({ kind, name, sync }: { kind?: string; name?: string; sync?: boolean }) => {
	setDevice({ kind, name, sync });
	return null;
});

/** How full a session's context is, and where pi compacts it automatically (`context.ts`). */
onCommand("session.context", async ({ id }: { id: number }) => {
	const { models, compaction } = requireEngine();
	const conversation = await requireConversation(id);
	const [view, agent] = await Promise.all([conversation.context(context), conversation.agent(context)]);
	const model = agent.model ? models.getModel(agent.model.provider, agent.model.modelId) : undefined;
	return contextUsage(view, model?.contextWindow ?? 0, compaction);
});

/** Compacts a session's context now (pi's `/compact`), with what the summary should keep, if given. */
onCommand("session.compact", async ({ id, instructions }: { id: number; instructions?: string }) => {
	await requireHeldHere(id);
	await (await requireConversation(id)).compact(instructions?.trim() || undefined, context);
	return null;
});

/**
 * The reply to a prompt (for Shortcuts): waits for its run to settle, then gives the agent's last message after the
 * prompt, or why there is none.
 */
onCommand("session.reply", async ({ id, submissionId }: { id: number; submissionId: number }) => {
	const { harness } = requireEngine();
	const submission = await harness.submission(submissionId as Parameters<typeof harness.submission>[0], context);
	const record = submission ? await submission.wait(context) : undefined;
	const stream = await watchEvents(harness, id as ConversationId, context);
	const items = transcriptOf(stream.snapshot.entries);
	await stream.stop();
	const prompt = items.findLastIndex((item) => item.kind === "user");
	const replies = items.slice(prompt + 1).filter((item) => item.kind === "assistant");
	const text = replies.map((item) => (item.kind === "assistant" ? item.text : "")).filter(Boolean).at(-1) ?? "";
	const error = replies.map((item) => (item.kind === "assistant" ? item.error : undefined)).filter(Boolean).at(-1);
	return { status: record?.status ?? "done", reason: record?.reason ?? null, detail: record?.detail ?? null, text, error: error ?? null };
});

onCommand("session.submission", ({ id, submissionId }: { id: number; submissionId: number }) =>
	submissionReply(requireEngine().harness, id, submissionId, context),
);

/** A prompt from the user. While the agent works, `whenBusy` says where it goes: "steer" reaches the agent after its
 * current tool call, "followUp" waits until the run is done. */
onCommand("session.prompt", async ({ id, text: typed, whenBusy, requestId }: { id: number; text: string; whenBusy?: "steer" | "followUp"; requestId?: string }) => {
	await requireHeldHere(id);
	const conversation = await requireConversation(id);
	if (requestId) {
		const existing = await conversation.commit((tx) => tx.submissionByRequest(conversation.id, requestId), context);
		if (existing) return { submissionId: existing.id };
	}
	// For "Clean Up": sessions are old by when they were last used.
	await updateSession(id, (session) => {
		session.lastActiveAt = Date.now();
	});
	// `!command` runs in the session's shell, as in pi; `!!command` keeps its output from the model.
	const bash = /^!(!?)([\s\S]+)$/.exec(typed.trim());
	if (bash) {
		await runUserBash(id, conversation, bash[2]!.trim(), bash[1] === "!");
		return { submissionId: null, kind: "bash" };
	}
	// `/name args` runs an extension's command, when one registered `name`.
	if (typed.startsWith("/") && (await requireEngine().extensions.runCommand(id, typed, context))) return { submissionId: null, kind: "command" };
	// `/compact [instructions]` compacts the context now, as in pi.
	const compact = /^\/compact(?:\s+([\s\S]*))?$/.exec(typed.trim());
	if (compact) {
		await conversation.compact(compact[1]?.trim() || undefined, context);
		return { submissionId: null, kind: "compact" };
	}
	// `/skill:name args` puts the skill's instructions in the prompt, as in pi.
	const expanded = typed.startsWith("/skill:") ? await expandSkillCommand(typed, await skillsOf(id)) : typed;
	// Extensions may rewrite the prompt, take it, add messages before it, or replace the system prompt for its run.
	const { text, handled, messages, replacedSystemPrompt } = await requireEngine().extensions.prompt(id, expanded, context);
	if (handled) return { submissionId: null, kind: "handled" };
	for (const message of messages) await conversation.submit({ type: "write", entry: customMessageEntry(message) }, context);
	if (replacedSystemPrompt !== undefined) {
		await conversation.submit({ type: "write", entry: { kind: SYSTEM_PROMPT_ENTRY, data: { systemPrompt: replacedSystemPrompt } } }, context);
	}
	const submission = await conversation.submit({ type: "input", content: text, whenBusy: whenBusy ?? "steer", ...(requestId ? { requestId } : {}) }, context);
	track(id, submission);
	await updateSession(id, (session) => {
		if (session.title === NEW_SESSION_TITLE) session.title = text.replace(/\s+/g, " ").trim().slice(0, 48);
	});
	// During a run it waits: a steer for the run's next step, a follow-up for its end. The app shows it as queued (the
	// text as submitted, after extensions) until it's in the transcript (`session.queued`).
	const queued = (await submission.status(context)).status === "queued";
	return { submissionId: submission.id, queued, text };
});

/** Which of these submissions still wait in the queue (not in the transcript yet, nor dropped). */
onCommand("session.queued", async ({ ids }: { ids: number[] }) => {
	const { harness } = requireEngine();
	const queued: number[] = [];
	for (const id of ids ?? []) {
		const submission = await harness.submission(id as Parameters<typeof harness.submission>[0], context);
		if (submission && (await submission.status(context)).status === "queued") queued.push(id);
	}
	return { queued };
});

/** Takes back a queued message: "aborted", or "already_placed" / "settled" when it's too late. */
onCommand("session.withdraw", async ({ submissionId }: { submissionId: number }) => {
	const { harness } = requireEngine();
	const submission = await harness.submission(submissionId as Parameters<typeof harness.submission>[0], context);
	return { result: submission ? await submission.abort(context) : "settled" };
});

/** The slash commands the session's extensions registered. */
/** A shared extension file's contents (.piext), for the share sheet: a session's extension, or a default. */
onCommand("extensions.share", ({ name, sessionId }: { name: string; sessionId?: number }) => requireEngine().extensions.share(name, sessionId));

/** The background checks extensions registered (pi.registerCheck), for the app to schedule and run when iOS wakes it. */
onCommand("checks.list", () => requireEngine().extensions.checks());

/** Runs one background check (`key`: extension/name) within `timeoutMs`. */
onCommand("checks.run", ({ key, timeoutMs }: { key: string; timeoutMs?: number }) => requireEngine().extensions.runCheck(key, timeoutMs ?? 20_000));

/** A Home Screen widget's button: its extension's handler (`pi.widget.onAction`), run without the UI. */
onCommand("widget.action", ({ id, action, value, timeoutMs }: { id: string; action: string; value?: unknown; timeoutMs?: number }) =>
	requireEngine().extensions.runWidgetAction(id, action, value ?? null, timeoutMs ?? 20_000),
);

/** An extension's folder and files, to read and change in Settings (ExtensionSourceView). */
onCommand("extensions.source", ({ name, sessionId }: { name: string; sessionId?: number }) => requireEngine().extensions.source(name, sessionId));

/** Loads an extension again after its files changed in Settings. */
onCommand("extensions.reload", async ({ name, sessionId }: { name: string; sessionId?: number }) => {
	await requireEngine().extensions.reload(name, sessionId);
	return null;
});

/** Adds a shared extension (a .piext file the user opened in pi, and agreed to add) for every session. */
onCommand("extensions.import", ({ shared }: { shared: SharedExtension }) => {
	const { extensions, root } = requireEngine();
	return extensions.importShared(root, shared, context);
});

/** A session's dock (the apps it runs) and launcher (the apps its extensions offer). */
onCommand("apps.list", ({ sessionId }: { sessionId: number }) => requireEngine().extensions.apps(sessionId, context));

/** Opens a session's app from its dock, the launcher, or a widget (with its tap area's target), or shows it again. */
onCommand("apps.open", async ({ sessionId, key, target }: { sessionId: number; key: string; target?: string }) => {
	await requireEngine().extensions.openApp(sessionId, key, { visible: true, ...(typeof target === "string" ? { target } : {}) }, context);
	return null;
});

/** Closes a session's app (holding its dock entry). */
onCommand("apps.close", async ({ sessionId, key }: { sessionId: number; key: string }) => {
	await requireEngine().extensions.closeApp(sessionId, key);
	return null;
});

onCommand("session.commands", async ({ id }: { id: number }) => [
	...(await requireEngine().extensions.commands(id, context)),
	...(await skillsOf(id)).map((skill) => ({ name: `skill:${skill.name}`, description: skill.description, extension: "skills" })),
]);

function skillsOf(id: number) {
	return sessionSkills(id, sessionDirectory(requireEngine().sessionsRoot, id));
}

/** Forks a session at an entry into a new session with a copy of its workspace; an extension may cancel it. */
onCommand("session.fork", async ({ id, entryId }: { id: number; entryId: number }) => (await forkSession(id, entryId)) ?? { cancelled: true });

async function forkSession(id: number, entryId: number): Promise<(SessionMeta & { workspace: string }) | undefined> {
	const { root, sessionsRoot, extensions } = requireEngine();
	if (await extensions.beforeFork(id, entryId, context)) return undefined;
	const source = await requireConversation(id);
	const meta = (await listSessions()).find((session) => session.id === id);
	const fork = await source.fork(entryId as EntryId, { ownership: { kind: "ownerless" } }, context);
	const directory = sessionDirectory(sessionsRoot, fork.id);
	// A copy of the files as they are now (an APFS clone, so it costs little); the fork changes its own.
	try {
		await request("fs", "copy", { from: sessionDirectory(sessionsRoot, id), to: directory });
	} catch {
		await request("fs", "mkdir", { path: directory, recursive: true });
	}
	await fork.configure({ cwd: directory }, context);
	const model = meta?.model ?? (await fork.agent(context)).model ?? { provider: "", modelId: "" };
	const session: SessionMeta = {
		id: fork.id,
		title: `Fork: ${meta?.title ?? "Session"}`,
		createdAt: Date.now(),
		model: { provider: model.provider, modelId: model.modelId },
		browser: meta?.browser ?? null,
		...(meta?.thinkingLevel ? { thinkingLevel: meta.thinkingLevel } : {}),
	};
	await root.commit(async (tx) => {
		(await tx.doc(SessionsDoc, root.id)).sessions.push(session);
	}, context);
	await extensions.forked(id, fork.id, context);
	await watch(fork.id);
	emit({ type: "session_added", session });
	return { ...session, workspace: directory };
}

onCommand("session.abort", async ({ id }: { id: number }) => {
	// Extensions' commands, and their reading of a message, stop too: Stop ends whatever the session is doing.
	requireEngine().extensions.stopForUser(id);
	await (await requireConversation(id)).abort(context);
	return null;
});

/** Stops one of an extension's tasks in the session (the indicator's list), leaving the run and the others. */
onCommand("session.stopTask", ({ id, task }: { id: number; task: number }) => ({ stopped: requireEngine().extensions.stopForUser(id, task) }));

onCommand("session.setModel", async ({ id, provider, modelId }: { id: number; provider: string; modelId: string }) => {
	await setSessionModel(id, provider, modelId);
	return { thinkingLevel: (await listSessions()).find((session) => session.id === id)?.thinkingLevel ?? "off" };
});

/** How much the session's model thinks: the level as its model takes it (the nearest it has), which it returns. */
onCommand("session.setThinkingLevel", async ({ id, level }: { id: number; level: string }) => ({
	thinkingLevel: await setSessionThinkingLevel(id, level),
}));

/** Attaches the session's browser to a profile (its key), or detaches it (`null`). */
onCommand("session.setBrowser", async ({ id, browser }: { id: number; browser: string | null }) => {
	await updateSession(id, (session) => {
		session.browser = browser;
	});
	// Choosing a browser for the session asks for it: its tools are offered from then on.
	if (browser !== null) await showBrowserTools(id);
	return null;
});

/**
 * Offers the browser's tools in a session's requests. The session's stored tool filter only ever hides them; an empty
 * filter (rather than none) marks the session as already past the launch-time migration that hides them.
 */
async function showBrowserTools(id: number): Promise<void> {
	await (await requireConversation(id)).configure({ tools: { remove: [] } }, context);
}

onCommand("session.rename", async ({ id, title }: { id: number; title: string }) => {
	await renameSession(id, title);
	return null;
});

/** Removes a session from the list. Its transcript stays in storage; its workspace is deleted by the app. */
onCommand("session.delete", async ({ id }: { id: number }) => {
	const { root, watchers, extensions, harness } = requireEngine();
	await watchers.get(id)?.stop();
	watchers.delete(id);
	extensions.forget(id);
	// Its Crabbox box stops costing money.
	await releaseSessionLease(harness, id, context);
	await root.commit(async (tx) => {
		const doc = await tx.doc(SessionsDoc, root.id);
		doc.sessions = doc.sessions.filter((session) => session.id !== id);
	}, context);
	return null;
});

/** A session's extensions and the defaults, for the app's list. */
onCommand("extensions.list", ({ id }: { id: number }) =>
	requireEngine()
		.extensions.list(id)
		.map((item) => ({
			name: item.record.name,
			version: item.record.version ?? null,
			source: item.record.source,
			scope: item.scope,
			left: item.left,
			tools: item.tools,
			notes: item.notes,
		})),
);

// ---- Settings → Extensions ----

/** Every installed extension: the defaults (on or off) and each session's own. */
onCommand("extensions.installed", async () => {
	const { extensions, root } = requireEngine();
	return extensions.inventory(root.id, await listSessions(), context);
});

onCommand("extensions.addDefault", ({ source }: { source: string }) => requireEngine().extensions.addDefault(requireEngine().root, source, context));

/** Updates the defaults installed from GitHub whose folder changed (`force`: now, else at most every few hours). */
onCommand("extensions.checkUpdates", ({ force }: { force?: boolean } = {}) => requireEngine().extensions.updateFromGitHub(requireEngine().root, context, force === true));

onCommand("extensions.setEnabled", async ({ name, enabled }: { name: string; enabled: boolean }) => {
	await requireEngine().extensions.setDefaultEnabled(requireEngine().root, name, enabled, context);
	return null;
});

/** Removes a default from every session, or a session's own extension when `sessionId` is given. */
onCommand("extensions.remove", async ({ name, sessionId }: { name: string; sessionId?: number }) => {
	const { extensions, root } = requireEngine();
	if (sessionId === undefined) await extensions.removeDefault(root, name, context);
	else await extensions.removeFromSession(sessionId, name, context);
	return null;
});

onCommand("extensions.makeDefault", async ({ name, sessionId }: { name: string; sessionId: number }) => {
	await requireEngine().extensions.makeDefault(requireEngine().root, sessionId, name, context);
	return null;
});

/** The skills in the app's skills folder (for every session). */
onCommand("skills.installed", async () =>
	(await skillsIn(`${requireEngine().extensions.agentDir}/skills`, "user")).map((skill) => ({ name: skill.name, description: skill.description, path: skill.baseDir })),
);

onCommand("skills.remove", async ({ name }: { name: string }) => {
	const folder = `${requireEngine().extensions.agentDir}/skills`;
	const skill = (await skillsIn(folder, "user")).find((candidate) => candidate.name === name);
	if (!skill) throw new Error(`No skill named ${name}`);
	// A skill folder, or a standalone .md at the top of the skills folder.
	const path = skill.filePath.endsWith("/SKILL.md") ? skill.baseDir : skill.filePath;
	if (!path.startsWith(`${folder}/`)) throw new Error(`${name} is not in the skills folder`);
	await request("fs", "rm", { path, recursive: true, force: true });
	forgetSkills();
	return null;
});

/** Diagnostics: runs one command through the native ExecutionEnv, as pi's bash tool would. */
onCommand("debug.exec", async ({ command, timeout }: { command: string; timeout?: number }) => {
	const directory = `${requireEngine().sessionsRoot}/debug`;
	await request("fs", "mkdir", { path: directory, recursive: true });
	const env = new NativeExecutionEnv({
		cwd: directory,
		home: directory,
		environment: { HOME: directory, PYTHONUSERBASE: `${directory}/.python` },
	});
	let output = "";
	const started = performance.now();
	const result = await env.exec(command, { timeout, onOutput: (text) => (output += text) }, context);
	const ms = Math.round(performance.now() - started);
	return result.ok
		? { exitCode: result.value.exitCode, output, ms }
		: { error: result.error.code, message: result.error.message, output, ms };
});

async function listSessions(): Promise<SessionMeta[]> {
	const { harness, root } = requireEngine();
	return (await harness.snapshot(SessionsDoc, root.id, context))?.sessions ?? [];
}

async function updateSession(id: number, change: (session: SessionMeta) => void): Promise<void> {
	const { root } = requireEngine();
	let updated: SessionMeta | undefined;
	await root.commit(async (tx) => {
		const session = (await tx.doc(SessionsDoc, root.id)).sessions.find((candidate) => candidate.id === id);
		if (session) {
			change(session);
			// A plain copy: the document draft cannot be read once the commit settles.
			updated = JSON.parse(JSON.stringify(session)) as SessionMeta;
		}
	}, context);
	if (updated) emit({ type: "session_updated", session: updated });
}

async function setSessionModel(id: number, provider: string, modelId: string): Promise<void> {
	const { models, extensions } = requireEngine();
	const meta = (await listSessions()).find((session) => session.id === id);
	const previous = meta?.model;
	await (await requireConversation(id)).configure({ model: { provider, modelId } }, context);
	await updateSession(id, (session) => {
		session.model = { provider, modelId };
	});
	// The thinking level carries over, as far as the new model goes.
	if (meta?.thinkingLevel && meta.thinkingLevel !== "off") await setSessionThinkingLevel(id, meta.thinkingLevel);
	await extensions.notify(
		id,
		{
			type: "model_select",
			model: models.getModel(provider, modelId),
			previousModel: previous ? models.getModel(previous.provider, previous.modelId) : undefined,
			source: "set",
		},
		context,
	);
}

/** The level `level` is for this model: itself, or the nearest one it takes (pi-ai's clampThinkingLevel). */
function thinkingLevelFor(model: { provider: string; modelId: string } | undefined, level: string): string {
	const known = model ? requireEngine().models.getModel(model.provider, model.modelId) : undefined;
	return known ? clampThinkingLevel(known, level as ModelThinkingLevel) : level;
}

/** Sets how much the session's model thinks, as the model takes it; returns the level set. */
async function setSessionThinkingLevel(id: number, level: string): Promise<string> {
	const meta = (await listSessions()).find((session) => session.id === id);
	const effective = thinkingLevelFor(meta?.model, level);
	await (await requireConversation(id)).configure({ thinkingLevel: effective as ModelThinkingLevel }, context);
	await updateSession(id, (session) => {
		session.thinkingLevel = effective;
	});
	return effective;
}

async function renameSession(id: number, title: string): Promise<void> {
	await updateSession(id, (session) => {
		session.title = title;
	});
	await requireEngine().extensions.notify(id, { type: "session_info_changed", name: title }, context);
}

const MAX_BASH_OUTPUT = 50_000;

/** Runs a `!command` the user typed (or lets an extension run or answer it) and records it in the transcript. */
async function runUserBash(id: number, conversation: Conversation, command: string, excludeFromContext: boolean): Promise<void> {
	const { extensions, sessionsRoot } = requireEngine();
	const directory = sessionDirectory(sessionsRoot, id);
	const outcome = await extensions.userBash(id, command, excludeFromContext, context);
	let result: BashResult;
	if (outcome?.result) {
		result = outcome.result;
	} else {
		let output = "";
		let exitCode: number | undefined;
		if (outcome?.operations) {
			const ran = await outcome.operations.exec(command, directory, { onData: (data) => (output += String(data)) });
			exitCode = ran.exitCode ?? undefined;
		} else {
			const env = new NativeExecutionEnv({ cwd: directory, home: directory, environment: { HOME: directory, PYTHONUSERBASE: `${directory}/.python` } });
			const ran = await env.exec(command, { onOutput: (text) => (output += text) }, context);
			if (ran.ok) exitCode = ran.value.exitCode;
			else output += `${output ? "\n" : ""}${ran.error.message}`;
		}
		const truncated = output.length > MAX_BASH_OUTPUT;
		result = { output: truncated ? output.slice(-MAX_BASH_OUTPUT) : output, exitCode, cancelled: false, truncated };
	}
	// What pi shows the model for it (bashExecutionToText).
	let text = `Ran \`${command}\`\n${result.output ? `\`\`\`\n${result.output}\n\`\`\`` : "(no output)"}`;
	if (result.cancelled) text += "\n\n(command cancelled)";
	else if (result.exitCode !== undefined && result.exitCode !== 0) text += `\n\nCommand exited with code ${result.exitCode}`;
	await conversation.submit(
		{
			type: "write",
			entry: {
				kind: BASH_ENTRY,
				data: { command, output: result.output, exitCode: result.exitCode ?? null, cancelled: result.cancelled, truncated: result.truncated, excludeFromContext },
				...(excludeFromContext ? {} : { model: [{ role: "user" as const, content: text, timestamp: Date.now() }] }),
			},
		},
		context,
	);
}

async function requireConversation(id: number): Promise<Conversation> {
	const conversation = await requireEngine().harness.conversation(id as ConversationId, context);
	if (!conversation) throw new Error(`No session ${id}`);
	return conversation;
}

async function watch(id: number): Promise<void> {
	const { harness, watchers } = requireEngine();
	if (watchers.has(id)) return;
	const stream = await watchEvents(harness, id as ConversationId, context);
	stream.start(async (events) => {
		emit({ type: "agent_events", sessionId: id, events });
		requireEngine().extensions.observe(id, events, context);
	});
	watchers.set(id, stream);
}

function track(sessionId: number, submission: Submission): void {
	void submission.wait(context).then(
		(record) => emit({ type: "submission_settled", sessionId, record }),
		(error: unknown) => emit({ type: "submission_failed", sessionId, id: submission.id, message: String(error) }),
	);
}

/**
 * What a custom provider's model takes (text, images) and whether it reasons, as pi-ai's catalogs declare it for the
 * model of that name: a gateway's ids name the route first (anthropic/claude-sonnet-5-5, azure/gpt-6.1-sol); one not in
 * a catalog takes text and doesn't reason.
 */
function catalogTraits(models: MutableModels, customIds: Set<string>): (id: string) => { input: Model<"openai-completions">["input"]; reasoning: boolean } {
	const traits = new Map<string, { input: Model<"openai-completions">["input"]; reasoning: boolean }>();
	for (const provider of models.getProviders()) {
		if (customIds.has(provider.id)) continue;
		for (const model of models.getModels(provider.id)) {
			const known = traits.get(model.id);
			traits.set(model.id, {
				input: !known || model.input.includes("image") ? [...model.input] : known.input,
				reasoning: (known?.reasoning ?? false) || model.reasoning,
			});
		}
	}
	// A model newer than the catalog (claude-haiku-5-5 before pi-ai lists it) takes after its family: the name without its
	// version parts (claude-haiku), as the catalog's models of that family do.
	const families = new Map<string, { input: Model<"openai-completions">["input"]; reasoning: boolean }>();
	for (const [id, trait] of traits) {
		const family = familyOf(id);
		const known = families.get(family);
		families.set(family, {
			input: !known || trait.input.includes("image") ? [...trait.input] : known.input,
			reasoning: (known?.reasoning ?? false) || trait.reasoning,
		});
	}
	return (id) => {
		const bare = id.slice(id.indexOf("/") + 1);
		// A family of one word ("mini") says too little to go by.
		const family = familyOf(bare);
		return traits.get(id) ?? traits.get(bare) ?? (family.includes("-") ? families.get(family) : undefined) ?? { input: ["text"], reasoning: false };
	};
}

/** A model's family: its name without the parts that carry a version (claude-haiku-5-5 and claude-haiku-latest: claude-haiku). */
function familyOf(id: string): string {
	return id
		.toLowerCase()
		.split(/[-_.:]/)
		.filter((part) => part && !/\d/.test(part) && part !== "latest" && part !== "preview")
		.join("-");
}

function setCustomProvider(models: MutableModels, customIds: Set<string>, config: CustomProvider): void {
	const traitsOf = catalogTraits(models, customIds);
	const catalog: Model<"openai-completions">[] = config.models.map((model) => ({
		id: model.id,
		name: model.name ?? model.id,
		api: "openai-completions",
		provider: config.id,
		baseUrl: config.baseUrl,
		// A reasoning model thinks as asked through the server's reasoning_effort: the efforts every OpenAI-compatible
		// server takes (low, medium, high), not minimal, xhigh or max.
		reasoning: traitsOf(model.id).reasoning,
		...(traitsOf(model.id).reasoning ? { thinkingLevelMap: { minimal: null, xhigh: null, max: null } } : {}),
		input: traitsOf(model.id).input,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: model.contextWindow ?? 32768,
		maxTokens: model.maxTokens ?? 4096,
	}));
	// pi-ai's OpenAI-compatible client requires a key; keyless local servers (Ollama, llama.cpp) ignore it.
	const apiKey = config.apiKey ?? "no-key";
	models.setProvider(
		createProvider({
			id: config.id,
			name: config.name,
			baseUrl: config.baseUrl,
			auth: { apiKey: { name: config.name, resolve: async () => ({ auth: { apiKey } }) } },
			models: catalog,
			api: openAICompletionsApi(),
		}),
	);
	customIds.add(config.id);
}

await request("engine", "ready", {
	userAgent: navigator.userAgent,
	secureContext: window.isSecureContext,
	webAssembly: typeof WebAssembly === "object",
});
