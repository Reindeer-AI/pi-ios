import type { JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type AuthType, type Message, type Model, Type } from "@earendil-works/pi-ai";
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
import { environmentGuide } from "./environment.ts";
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
import { type SessionMeta, SessionsDoc, createSession, submissionReply, transcriptOf } from "./sessions.ts";
import { NativeSqliteDatabase } from "./storage.ts";

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
	return { sessions, rest: () => finishOpen(sessions, sessionsRoot, browser, extensions) };
}

async function finishOpen(sessions: SessionMeta[], sessionsRoot: string, browser: ReturnType<typeof browserTools>, extensions: Extensions) {
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
	async ({ provider, modelId, title, browser, requestId }: { provider: string; modelId: string; title?: string; browser?: string; requestId?: string }) => {
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
		await watch(session.id);
		return { ...session, workspace: directory };
	},
);

onCommand("session.transcript", async ({ id }: { id: number }) => {
	const stream = await watchEvents(requireEngine().harness, id as ConversationId, context);
	const { entries, run } = stream.snapshot;
	await stream.stop();
	// After a compaction the context starts at its summary (the entries it kept follow): what came before shows too.
	const start = (entries[0] as { head?: number } | undefined)?.head;
	const earlier = start === undefined ? [] : await entriesBefore(id, start);
	return { items: [...transcriptOf(earlier), ...transcriptOf(entries)], running: run !== undefined };
});

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
	return { submissionId: submission.id };
});

/** The slash commands the session's extensions registered. */
/** A shared extension file's contents (.piext), for the share sheet: a session's extension, or a default. */
onCommand("extensions.share", ({ name, sessionId }: { name: string; sessionId?: number }) => requireEngine().extensions.share(name, sessionId));

/** The background checks extensions registered (pi.registerCheck), for the app to schedule and run when iOS wakes it. */
onCommand("checks.list", () => requireEngine().extensions.checks());

/** Runs one background check (`key`: extension/name) within `timeoutMs`. */
onCommand("checks.run", ({ key, timeoutMs }: { key: string; timeoutMs?: number }) => requireEngine().extensions.runCheck(key, timeoutMs ?? 20_000));

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

/** Opens a session's app from its dock or the launcher, or shows it again. */
onCommand("apps.open", async ({ sessionId, key }: { sessionId: number; key: string }) => {
	await requireEngine().extensions.openApp(sessionId, key, { visible: true }, context);
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
	await (await requireConversation(id)).abort(context);
	return null;
});

onCommand("session.setModel", async ({ id, provider, modelId }: { id: number; provider: string; modelId: string }) => {
	await setSessionModel(id, provider, modelId);
	return null;
});

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
	const previous = (await listSessions()).find((session) => session.id === id)?.model;
	await (await requireConversation(id)).configure({ model: { provider, modelId } }, context);
	await updateSession(id, (session) => {
		session.model = { provider, modelId };
	});
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
 * What a custom provider's model takes (text, images), as pi-ai's catalogs declare it for the model of that name: a
 * gateway's ids name the route first (anthropic/claude-sonnet-5-5, azure/gpt-6.1-sol); one not in a catalog takes text.
 */
function catalogInputs(models: MutableModels, customIds: Set<string>): (id: string) => Model<"openai-completions">["input"] {
	const inputs = new Map<string, Model<"openai-completions">["input"]>();
	for (const provider of models.getProviders()) {
		if (customIds.has(provider.id)) continue;
		for (const model of models.getModels(provider.id)) {
			if (!inputs.has(model.id) || model.input.includes("image")) inputs.set(model.id, [...model.input]);
		}
	}
	return (id) => inputs.get(id) ?? inputs.get(id.slice(id.indexOf("/") + 1)) ?? ["text"];
}

function setCustomProvider(models: MutableModels, customIds: Set<string>, config: CustomProvider): void {
	const inputOf = catalogInputs(models, customIds);
	const catalog: Model<"openai-completions">[] = config.models.map((model) => ({
		id: model.id,
		name: model.name ?? model.id,
		api: "openai-completions",
		provider: config.id,
		baseUrl: config.baseUrl,
		reasoning: false,
		input: inputOf(model.id),
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
