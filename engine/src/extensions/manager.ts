/**
 * pi extensions at run time: "add extension X to this session" (or "as a default for every session"), from npm, git,
 * or a file the agent wrote in its workspace.
 *
 * - A session's extensions are its own instances (registry name `session:<id>:<name>`), added to its agent's selection
 *   on top of the defaults; default extensions (`default:<name>`) are in every session's selection (HarnessSettings
 *   reads `defaults` at every resolution), and a session can leave one out.
 * - What was added is kept in pi-durable documents (the root conversation's for defaults, each session's for its
 *   own), so the app reinstalls them before resumed runs continue; pi-durable itself keeps only the names.
 * - The agent manages them with extension_add, extension_reload, extension_remove, and extension_list.
 */
import { type Message, Type } from "@earendil-works/pi-ai";
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import {
	type AgentEvent,
	type Conversation,
	type ConversationId,
	configure,
	defineDoc,
	defineExtension,
	defineTool,
	type Extension,
	GenerationTask,
	type Harness,
	hook,
	type Registry,
	type Tx,
} from "@earendil-works/pi-durable";
import { emit, request } from "../bridge.ts";
import { NativeExecutionEnv } from "../env.ts";
import { type Adapted, adapt, type CheckDefinition, type Host, hostModules, type Prompt, startRequest, type UserBash } from "./adapter.ts";
import { type AppDefinition, type AppHandle, appKey, closeApp as endApp, listApps } from "./apps.ts";
import { forgetApps, parseWidgetId, publishApps, runAction } from "./widgets.ts";
import { installDependencies, installPackage } from "./npm.ts";
import { codingAgentModule } from "./coding-agent.ts";
import { forgetSkills } from "../skills.ts";
import { fetchFor } from "../net.ts";
import { extensionOf, withSecrets } from "../secrets.ts";
import { ModuleRuntime } from "./runtime.ts";
import { Histories, SYSTEM_PROMPT_ENTRY } from "./session.ts";

export type Scope = "session" | "default";

export type ExtensionRecord = {
	/** The name people and the agent use: the package's name, or the file's. */
	name: string;
	/** As given: npm:pkg@range, git:url, github:owner/repo/path@ref, or a path. */
	source: string;
	kind: "npm" | "git" | "github" | "path";
	/** From GitHub: the hash of the folder's tree when installed; an update comes when it changes. */
	revision?: string;
	/** What `entries` are relative to: the extensions folder, or the session's workspace. (The app's container moves
	 * when it is reinstalled, so no path is stored absolute; records from before this have absolute entries.) */
	base?: "installs" | "workspace";
	/** The modules to load. */
	entries: string[];
	/** Folders (or files) of the package's skills (`pi.skills`, else its skills/ folder), relative like `entries`. */
	skills?: string[];
	version?: string;
	addedAt: number;
	/** A default turned off in Settings: kept, but not loaded into any session. */
	disabled?: boolean;
};

type Records = Record<string, ExtensionRecord>;

/** Default extensions, on the root conversation. */
export const DefaultExtensionsDoc = defineDoc<{ extensions: Records }>({
	kind: "pimobile.extensions.defaults",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ extensions: {} }),
});

/** A session's own extensions, and the defaults it leaves out. */
export const SessionExtensionsDoc = defineDoc<{ extensions: Records; withoutDefaults: string[] }>({
	kind: "pimobile.extensions.session",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ extensions: {}, withoutDefaults: [] }),
});

/**
 * A shared extension (a .piext file, from the share sheet): one installed from GitHub, npm or git as where to get it
 * (the recipient's copy then updates the same way, and a private repository still needs access), one written here as
 * its files.
 */
export type SharedExtension = {
	pi: "extension";
	format: 1;
	name: string;
	version?: string;
	description?: string;
	source?: string;
	/** Its files, base64, by path relative to its package folder (or its file's folder); which are entries and skills. */
	files?: Record<string, string>;
	entries?: string[];
	skills?: string[];
	tools: string[];
	apps: { name: string; title: string; icon: string | null }[];
};

/** The most a shared extension's files may weigh. */
const SHARE_LIMIT = 10 * 1024 * 1024;

export type InstalledExtension = {
	name: string;
	version: string | null;
	source: string;
	kind: ExtensionRecord["kind"];
	/** From GitHub: the installed folder's tree hash. */
	revision: string | null;
	enabled: boolean;
	tools: string[];
	/** Whether it brings skills. */
	skills: boolean;
	notes: string[];
	addedAt: number;
};

export type InstalledExtensions = {
	defaults: InstalledExtension[];
	sessions: { id: number; title: string | null; extensions: InstalledExtension[] }[];
};

type Loaded = { readonly record: ExtensionRecord; readonly adapted: Adapted; readonly extension: Extension; readonly tools: string[]; readonly notes: string[] };
type SessionEnv = (sessionId: number) => { cwd: string; home: string; env: Record<string, string> };
/** What extensions reach of the engine, besides what the manager provides itself. */
export type Services = Omit<Host, "histories" | "env" | "startReason" | "broadcast">;

export class Extensions {
	/** Loaded extensions by registry name. */
	private readonly loaded = new Map<string, Loaded>();
	/** Default extensions, in the order added (HarnessSettings.extensions appends them). */
	defaults: Extension[] = [];
	private readonly host: Host;

	constructor(
		private readonly registry: Registry,
		private readonly installRoot: string,
		private readonly sessionEnv: SessionEnv,
		private readonly neutralEnv: { cwd: string; home: string; env: Record<string, string> },
		services: Services,
	) {
		this.host = {
			...services,
			histories: new Histories(services.harness, BACKGROUND_CONTEXT),
			env: sessionEnv,
			startReason: (id) => {
				const source = this.forks.get(id);
				return source === undefined ? { reason: "startup" } : { reason: "fork", previousSessionFile: String(source) };
			},
			broadcast: (id, event) => this.notify(id, event, BACKGROUND_CONTEXT),
		};
		this.codingAgent = codingAgentModule({
			// pi's ~/.pi/agent: one for the app, beside the installed extensions.
			agentDir: this.agentDir,
			copyToClipboard: async (text) => {
				await request("clipboard", "write", { text });
			},
			exec: async (command, cwd, options) => {
				const shell = new NativeExecutionEnv({ cwd, home: this.neutralEnv.home, environment: this.neutralEnv.env });
				const context = options.signal ? withAbortSignal(options.signal, BACKGROUND_CONTEXT) : BACKGROUND_CONTEXT;
				const result = await shell.exec(command, { timeout: options.timeout, onOutput: options.onData }, context);
				return { exitCode: result.ok ? result.value.exitCode : null };
			},
		});
	}

	/** pi-coding-agent as extensions import it. */
	private readonly codingAgent: Record<string, unknown>;

	/** Sessions forked since the app started, and what they were forked from. */
	private readonly forks = new Map<number, number>();
	/** Each session's agent events, delivered in order. */
	private readonly observing = new Map<number, Promise<void>>();

	static registryName(scope: Scope, name: string, sessionId?: number): string {
		return scope === "default" ? `default:${name}` : `session:${sessionId}:${name}`;
	}

	/** Reinstalls every recorded extension, before the Harness resumes runs that may call their tools. */
	async restore(harness: Harness, root: Conversation, sessionIds: number[], context: Context): Promise<void> {
		const defaults = (await harness.snapshot(DefaultExtensionsDoc, root.id, context))?.extensions ?? {};
		for (const record of Object.values(defaults)) if (!record.disabled) await this.loadOrPlaceholder(record, "default");
		for (const sessionId of sessionIds) {
			const own = (await harness.snapshot(SessionExtensionsDoc, sessionId as ConversationId, context))?.extensions ?? {};
			for (const record of Object.values(own)) await this.loadOrPlaceholder(record, "session", sessionId);
		}
	}

	/** Extensions not to load this time: they froze the engine (the app replaced its page). */
	private held = new Set<string>();

	/** Keeps these extensions from loading until the engine starts again; they show why (extension_list). */
	hold(names: string[]): void {
		for (const name of names) this.held.add(name);
	}

	private async loadOrPlaceholder(record: ExtensionRecord, scope: Scope, sessionId?: number): Promise<void> {
		try {
			if (this.held.has(record.name)) throw new Error("turned off: it froze pi's engine, which pi then restarted");
			await this.load(record, scope, sessionId);
		} catch (error) {
			// Keep the name resolvable so the session still runs; extension_list shows why it has no tools.
			const name = Extensions.registryName(scope, record.name, sessionId);
			const adapted = failed(name, `failed to load: ${message(error)}`);
			this.registry.install(adapted.extension);
			this.loaded.set(name, loadedOf(record, adapted));
			if (scope === "default") this.updateDefaults();
			console.warn(`extension ${name}: ${message(error)}`);
		}
	}

	/** Loads (or reloads) a recorded extension and installs it in the registry. */
	async load(record: ExtensionRecord, scope: Scope, sessionId?: number): Promise<Loaded> {
		// The app hears whose code is loading: one that freezes the engine as it loads is the one turned off.
		emit({ type: "extension_loading", extension: record.name });
		try {
			return await this.loadNow(record, scope, sessionId);
		} finally {
			emit({ type: "extension_loading", extension: null });
		}
	}

	private async loadNow(record: ExtensionRecord, scope: Scope, sessionId?: number): Promise<Loaded> {
		const name = Extensions.registryName(scope, record.name, sessionId);
		const base = scope === "default" ? this.neutralEnv : this.sessionEnv(sessionId!);
		// Its process.env carries the secrets the user lets it read.
		const context = { ...base, env: withSecrets({ ...base.env }, record.name), fetch: fetchFor(extensionOf(record.name)) };
		// One module graph for the extension; its function runs once per session (adapter.ts).
		const runtime = new ModuleRuntime(context, hostModules(this.codingAgent));
		const modules: unknown[] = [];
		for (const entry of record.entries.map((entry) => this.entryPath(record, entry, sessionId))) {
			await runtime.prepare(entry);
			modules.push(await runtime.load(entry));
		}
		const adapted = await adapt(name, modules, this.host, scope === "session" ? sessionId : undefined);
		const previous = this.loaded.get(name);
		this.registry.install(adapted.extension);
		const loaded = loadedOf(record, adapted);
		this.loaded.set(name, loaded);
		if (scope === "default") this.updateDefaults();
		forgetSkills();
		// The widget lists its apps (one that failed to load keeps what it listed last).
		publishApps(name, adapted.offeredApps);
		void previous?.adapted.shutdown("reload");
		return loaded;
	}

	private entryPath(record: ExtensionRecord, entry: string, sessionId?: number): string {
		if (entry.startsWith("/")) return entry;
		if (record.base !== "workspace") return normalize(`${this.installRoot}/${entry}`);
		if (sessionId === undefined) throw new Error(`${record.name}: a workspace extension needs a session`);
		return normalize(`${this.sessionEnv(sessionId).cwd}/${entry}`);
	}

	private updateDefaults(): void {
		this.defaults = [...this.loaded].filter(([name]) => name.startsWith("default:")).map(([, loaded]) => loaded.extension);
	}

	/** Installs what `source` names (npm, git, or a path relative to `cwd`) and returns its record, not yet loaded. A
	 * path stays in the session's `workspace`, unless it becomes a default: then it is copied to the extensions folder,
	 * since a default outlives the session that wrote it. */
	async fetch(source: string, cwd: string, scope: Scope, workspace: string): Promise<ExtensionRecord> {
		const trimmed = source.trim();
		const github = gitHubSource(trimmed);
		if (github) return this.fromGitHub(github);
		const npm = /^npm:(.+)$/.exec(trimmed)?.[1];
		const git = /^git:(.+)$/.exec(trimmed)?.[1] ?? (/^(https?:\/\/|git@).+(\.git|github\.com\/[^/]+\/[^/]+\/?)$/.test(trimmed) ? trimmed : undefined);
		if (git) return this.fromGit(trimmed, git);
		const path = trimmed.startsWith("/") ? trimmed : `${cwd}/${trimmed}`;
		if (!npm && (await exists(path))) return this.fromPath(trimmed, normalize(path), scope, workspace);
		const spec = npm ?? trimmed;
		// Looks like a file that isn't there (yet: written by a call running alongside this one, say).
		const scoped = /^@[\w.-]+\/[\w.-]+(@\S+)?$/.test(trimmed);
		if (!npm && !scoped && (/^[./~]/.test(trimmed) || /[/\\]/.test(trimmed) || /\.[cm]?[jt]sx?$/.test(trimmed)))
			throw new Error(`no file at ${path}: write the extension first (in an earlier step), then add it`);
		if (!/^(@[\w.-]+\/)?[\w.-]+(@[^\s]+)?$/.test(spec)) throw new Error(`not a path, npm package, or git URL: ${source}`);
		const at = spec.lastIndexOf("@");
		const [name, range] = at > 0 ? [spec.slice(0, at), spec.slice(at + 1)] : [spec, "latest"];
		const root = `${this.installRoot}/npm/${name.replace("/", "+")}`;
		await request("fs", "rm", { path: root, recursive: true, force: true });
		await request("fs", "mkdir", { path: root, recursive: true });
		const { directory, version } = await installPackage(root, name, range);
		const skills = await packageSkills(directory);
		return { name, source: `npm:${spec}`, kind: "npm", base: "installs", entries: this.installed(await packageEntries(directory, skills.length > 0)), skills: this.installed(skills), version, addedAt: Date.now() };
	}

	/**
	 * A folder (or file) of a GitHub repository, downloaded by the app's native `github` service with the user's GitHub
	 * sign-in (so private repositories work, and the agent never sees the token), then installed as a package.
	 */
	private async fromGitHub(spec: GitHubSource): Promise<ExtensionRecord> {
		const directory = `${this.installRoot}/github/${[spec.owner, spec.repo, ...spec.path.split("/").filter(Boolean)].join("+")}`;
		const downloaded = await request<{ sha: string; ref: string; files: number; file: string | null }>("github", "download", {
			owner: spec.owner,
			repo: spec.repo,
			path: spec.path,
			ref: spec.ref ?? "",
			destination: directory,
		});
		const source = canonicalGitHubSource(spec);
		if (downloaded.file) {
			const entry = `${directory}/${downloaded.file}`;
			return { name: basename(entry).replace(/\.[^.]+$/, ""), source, kind: "github", base: "installs", entries: this.installed([entry]), skills: [], revision: downloaded.sha, addedAt: Date.now() };
		}
		const manifest = await readManifest(directory);
		if (manifest?.dependencies && Object.keys(manifest.dependencies).length > 0) await installDependencies(directory, manifest);
		const skills = await packageSkills(directory);
		const name = manifest?.name ?? (spec.path.split("/").filter(Boolean).pop() || spec.repo);
		return {
			name,
			source,
			kind: "github",
			base: "installs",
			entries: this.installed(await packageEntries(directory, skills.length > 0)),
			skills: this.installed(skills),
			...(manifest?.version ? { version: manifest.version } : {}),
			revision: downloaded.sha,
			addedAt: Date.now(),
		};
	}

	private lastUpdateCheck = 0;
	private updating: Promise<{ name: string; updated: boolean; error?: string }[]> | undefined;

	/**
	 * Updates the extensions installed from GitHub (defaults, and those of single sessions) whose folder or file changed
	 * (its hash): re-downloads and reloads them, keeping when they were added. At most every few hours unless `force`;
	 * a check that failed for one (no network yet, at launch) is tried again at the next one. Returns what changed.
	 */
	async updateFromGitHub(root: Conversation, context: Context, force = false): Promise<{ name: string; updated: boolean; error?: string }[]> {
		// One check at a time: a second one (the launch's and the user's) gets the same result.
		if (this.updating) return this.updating;
		if (!force && Date.now() - this.lastUpdateCheck < 4 * 3600_000) return [];
		this.lastUpdateCheck = Date.now();
		this.updating = this.checkGitHubUpdates(root, context)
			.then((results) => {
				const failed = results.filter((result) => result.error);
				for (const result of failed) console.warn(`extension ${result.name}: update check failed: ${result.error}`);
				if (failed.length > 0) this.lastUpdateCheck = 0;
				return results;
			})
			.finally(() => {
				this.updating = undefined;
			});
		return this.updating;
	}

	private async checkGitHubUpdates(root: Conversation, context: Context): Promise<{ name: string; updated: boolean; error?: string }[]> {
		const harness = this.host.harness();
		const defaults = (await harness.snapshot(DefaultExtensionsDoc, root.id, context))?.extensions ?? {};
		const installs: { record: ExtensionRecord; sessionId?: number }[] = Object.values(defaults).map((record) => ({ record }));
		for (const [name, loaded] of this.loaded) {
			const sessionId = /^session:(\d+):/.exec(name)?.[1];
			if (sessionId !== undefined) installs.push({ record: loaded.record, sessionId: Number(sessionId) });
		}
		// One look (and one download) per source, for a default and sessions with the same one.
		const hashes = new Map<string, Promise<string>>();
		const downloads = new Map<string, Promise<ExtensionRecord>>();
		const results: { name: string; updated: boolean; error?: string }[] = [];
		for (const { record, sessionId } of installs) {
			const spec = record.kind === "github" ? gitHubSource(record.source) : undefined;
			if (!spec || record.disabled) continue;
			const source = canonicalGitHubSource(spec);
			const label = sessionId === undefined ? record.name : `${record.name} (session ${sessionId})`;
			try {
				if (!hashes.has(source)) {
					hashes.set(source, request<{ sha: string }>("github", "check", { owner: spec.owner, repo: spec.repo, path: spec.path, ref: spec.ref ?? "" }).then((found) => found.sha));
				}
				const sha = await hashes.get(source)!;
				if (sha === record.revision) {
					results.push({ name: label, updated: false });
					continue;
				}
				if (!downloads.has(source)) downloads.set(source, this.fromGitHub(spec));
				const updated = { ...(await downloads.get(source)!), addedAt: record.addedAt };
				if (sessionId === undefined) {
					await this.load(updated, "default");
					await root.commit(async (tx) => {
						const doc = await tx.doc(DefaultExtensionsDoc, root.id);
						delete doc.extensions[record.name];
						doc.extensions[updated.name] = updated;
					}, context);
					if (updated.name !== record.name) this.unload(Extensions.registryName("default", record.name));
				} else {
					await this.load(updated, "session", sessionId);
					const conversation = await harness.conversation(sessionId as ConversationId, context);
					await conversation?.commit(async (tx) => {
						const doc = await tx.doc(SessionExtensionsDoc, sessionId as ConversationId);
						delete doc.extensions[record.name];
						doc.extensions[updated.name] = updated;
					}, context);
					if (updated.name !== record.name) this.unload(Extensions.registryName("session", record.name, sessionId));
				}
				console.log(`extension ${label}: updated from GitHub (${record.revision?.slice(0, 7) ?? "?"} → ${sha.slice(0, 7)})`);
				results.push({ name: label, updated: true });
			} catch (error) {
				results.push({ name: label, updated: false, error: message(error) });
			}
		}
		return results;
	}

	private async fromGit(source: string, url: string): Promise<ExtensionRecord> {
		const repository = url.replace(/\.git$/, "").replace(/\/$/, "").split("/").pop() ?? "extension";
		const directory = `${this.installRoot}/git/${repository}`;
		await request("fs", "rm", { path: directory, recursive: true, force: true });
		await request("fs", "mkdir", { path: `${this.installRoot}/git`, recursive: true });
		const shell = new NativeExecutionEnv({ cwd: `${this.installRoot}/git`, home: this.neutralEnv.home, environment: this.neutralEnv.env });
		let output = "";
		const cloned = await shell.exec(`git clone '${url.replaceAll("'", "")}' '${repository}' > /dev/null`, { timeout: 300, onOutput: (text) => (output += text) }, BACKGROUND_CONTEXT);
		if (!cloned.ok || cloned.value.exitCode !== 0) throw new Error(`git clone ${url} failed: ${output.trim() || (cloned.ok ? `exit ${cloned.value.exitCode}` : cloned.error.message)}`);
		const manifest = await readManifest(directory);
		if (manifest?.dependencies && Object.keys(manifest.dependencies).length > 0) await installDependencies(directory, manifest);
		const skills = await packageSkills(directory);
		return { name: manifest?.name ?? repository, source, kind: "git", base: "installs", entries: this.installed(await packageEntries(directory, skills.length > 0)), skills: this.installed(skills), addedAt: Date.now() };
	}

	private async fromPath(source: string, path: string, scope: Scope, workspace: string): Promise<ExtensionRecord> {
		const directory = (await request<{ kind: string }>("fs", "stat", { path })).kind === "directory";
		let name: string;
		let entries: string[];
		let skills: string[] = [];
		if (directory) {
			const manifest = await readManifest(path);
			if (manifest?.dependencies && !(await exists(`${path}/node_modules`))) await installDependencies(path, manifest);
			// A skill's own folder (with its SKILL.md) is a package of one skill.
			skills = (await existsFile(`${path}/SKILL.md`)) ? [path] : await packageSkills(path);
			name = manifest?.name ?? basename(path);
			entries = (await existsFile(`${path}/SKILL.md`)) && !manifest ? [] : await packageEntries(path, skills.length > 0);
		} else {
			name = basename(path).replace(/\.[^.]+$/, "");
			entries = [path];
		}
		const record = { name, source, kind: "path" as const, addedAt: Date.now() };
		if (scope === "session") return { ...record, base: "workspace", entries: entries.map((entry) => relative(workspace, entry)), skills: skills.map((skill) => relative(workspace, skill)) };

		// A package is copied whole; a single file with the modules it imports from its folder.
		const from = directory ? path : dirname(path);
		const to = `${this.installRoot}/local/${name.replace("/", "+")}`;
		let files: string[];
		if (directory) files = await listFiles(from);
		else {
			const runtime = new ModuleRuntime(this.neutralEnv, hostModules(this.codingAgent));
			await runtime.prepare(path);
			files = runtime.files.filter((file) => file.startsWith(`${from}/`));
		}
		await request("fs", "rm", { path: to, recursive: true, force: true });
		for (const file of files) {
			const target = `${to}${file.slice(from.length)}`;
			await request("fs", "mkdir", { path: dirname(target), recursive: true });
			await request("fs", "write", { path: target, data: await request<string>("fs", "readBinary", { path: file }) });
		}
		const moved = (paths: string[]) => this.installed(paths.map((path) => `${to}${path.slice(from.length)}`));
		return { ...record, base: "installs", entries: moved(entries), skills: moved(skills) };
	}

	private installed(paths: string[]): string[] {
		return paths.map((path) => relative(this.installRoot, path));
	}

	// ---- selection ----

	/** The session's selection: the defaults it keeps, and its own extensions. */
	/**
	 * A shared session's own extensions, on its copy (`session.import`): one from GitHub, npm or git is fetched again,
	 * one in its workspace loads from the copied files; others (installed from a file elsewhere) stay behind. Run once
	 * the workspace's files are in place. What was added, and what couldn't come.
	 */
	async adoptSessionExtensions(sessionId: number, records: ExtensionRecord[], context: Context): Promise<{ added: string[]; skipped: string[] }> {
		const added: string[] = [];
		const skipped: string[] = [];
		const workspace = this.sessionEnv(sessionId).cwd;
		for (const original of records) {
			try {
				const portable = original.kind === "github" || original.kind === "npm" || original.kind === "git";
				const record = portable ? await this.fetch(original.source, workspace, "session", workspace) : original.base === "workspace" ? original : undefined;
				if (!record) {
					skipped.push(original.name);
					continue;
				}
				await this.load(record, "session", sessionId);
				const conversation = await this.host.harness().conversation(sessionId as ConversationId, context);
				await conversation?.commit(async (tx) => {
					(await tx.doc(SessionExtensionsDoc, sessionId as ConversationId)).extensions[record.name] = { ...record, addedAt: original.addedAt };
					await this.select(tx, sessionId);
				}, context);
				added.push(record.name);
			} catch (error) {
				skipped.push(`${original.name} (${message(error)})`);
			}
		}
		return { added, skipped };
	}

	private async select(tx: Tx, sessionId: number): Promise<void> {
		const doc = await tx.doc(SessionExtensionsDoc, sessionId as ConversationId);
		const add = Object.keys(doc.extensions)
			.map((name) => this.loaded.get(Extensions.registryName("session", name, sessionId))?.extension)
			.filter((extension): extension is Extension => extension !== undefined);
		const remove = doc.withoutDefaults
			.map((name) => this.loaded.get(Extensions.registryName("default", name))?.extension)
			.filter((extension): extension is Extension => extension !== undefined);
		await configure(tx, sessionId as ConversationId, { extensions: { add, remove } });
	}

	// ---- tools ----

	/** The extension that lets the agent manage extensions; part of every session's default selection. */
	extension(rootId: () => ConversationId): Extension {
		const describe = (loaded: Loaded, scope: Scope) =>
			`${loaded.record.name}${loaded.record.version ? `@${loaded.record.version}` : ""} (${scope === "default" ? "default for every session" : "this session"}, from ${loaded.record.source}): ` +
			(loaded.tools.length > 0 ? `tools ${loaded.tools.join(", ")}` : "no tools") +
			(loaded.record.skills?.length ? "; skills, now in your skill list" : "") +
			(loaded.notes.length > 0 ? `\n  notes: ${loaded.notes.join("; ")}` : "");
		const sessionOf = (api: { conversationId: ConversationId }) => api.conversationId as unknown as number;
		const envOf = (api: { env?: unknown }) => (api.env as { cwd?: string } | undefined)?.cwd ?? "/";

		return defineExtension({
			name: "extensions",
			// Runs first in every session (the built-in extensions come first): starts each request's provider events,
			// and applies a system prompt that `before_agent_start` replaced for the run.
			hooks: [
				hook(GenerationTask, {
					beforeRequest: async (request, api) => {
						const conversationId = Number(api.conversationId);
						startRequest(conversationId);
						const systemPrompt = await this.replacedSystemPrompt(conversationId);
						return systemPrompt === undefined ? undefined : { messages: replaceSystemPrompt(request.messages, systemPrompt) };
					},
				}),
			],
			tools: [
				defineTool({
					name: "extension_add",
					description:
						"Add a pi extension, for this session (default) or as a default for every session: a path in the workspace, npm:<package>[@version], git:<url>, or github:<owner>/<repo>[/<folder>][@<ref>] (or a github.com URL; downloaded with the user's GitHub sign-in, so private repositories work, and a default is updated when the folder changes). Returns the tools it adds.",
					parameters: Type.Object({
						source: Type.String({ description: "A path (file or package directory), npm:<package>[@version], git:<url>, or github:<owner>/<repo>[/<folder>][@<ref>]" }),
						scope: Type.Optional(Type.Union([Type.Literal("session"), Type.Literal("default")], { description: "session (default) or default (every session)" })),
					}),
					replay: "unsafe",
					execute: async (args, api, context) => {
						const scope: Scope = args.scope ?? "session";
						const sessionId = sessionOf(api);
						// Code from the internet runs only once the user agrees (the app asks); a path is the session's own.
						if (remoteSource(args.source) && !(await request<boolean>("consent", "addExtension", { source: args.source, scope }))) {
							return { output: [{ type: "text", text: `The user didn't allow adding ${args.source}.` }], isError: true };
						}
						const record = await this.fetch(args.source, envOf(api), scope, this.sessionEnv(sessionId).cwd);
						const loaded = await this.load(record, scope, sessionId);
						await api.commit(async (tx) => {
							if (scope === "default") {
								(await tx.doc(DefaultExtensionsDoc, rootId())).extensions[record.name] = record;
							} else {
								(await tx.doc(SessionExtensionsDoc, api.conversationId)).extensions[record.name] = record;
								await this.select(tx, sessionId);
							}
						}, context);
						return { output: [{ type: "text", text: `Added ${describe(loaded, scope)}` }] };
					},
				}),
				defineTool({
					name: "extension_reload",
					description:
						"Reload an extension from its files (after editing it), keeping its scope. A default added from a path runs from a copy; reloading it copies the path again when this session's workspace has it.",
					parameters: Type.Object({ name: Type.String() }),
					replay: "safe",
					execute: async (args, api) => {
						const sessionId = sessionOf(api);
						for (const scope of ["session", "default"] as const) {
							const current = this.loaded.get(Extensions.registryName(scope, args.name, sessionId));
							if (!current) continue;
							const { record } = current;
							const copied = scope === "default" && record.kind === "path" && record.base === "installs";
							const source = record.source.startsWith("/") ? record.source : `${envOf(api)}/${record.source}`;
							// The copy keeps its place (local/<name>), so the stored record still describes it.
							if (copied && (await exists(source))) await this.fetch(record.source, envOf(api), scope, this.sessionEnv(sessionId).cwd);
							const loaded = await this.load(record, scope, sessionId);
							return { output: [{ type: "text", text: `Reloaded ${describe(loaded, scope)}` }] };
						}
						return { output: [{ type: "text", text: `No extension named ${args.name}.` }], isError: true };
					},
				}),
				defineTool({
					name: "extension_remove",
					description:
						"Remove an extension. A session extension leaves this session; for a default one, scope default removes it from every session, scope session only leaves it out of this one.",
					parameters: Type.Object({
						name: Type.String(),
						scope: Type.Optional(Type.Union([Type.Literal("session"), Type.Literal("default")])),
					}),
					replay: "unsafe",
					execute: async (args, api, context) => {
						const sessionId = sessionOf(api);
						const own = Extensions.registryName("session", args.name, sessionId);
						const shared = Extensions.registryName("default", args.name);
						if (this.loaded.has(own) && args.scope !== "default") {
							await api.commit(async (tx) => {
								delete (await tx.doc(SessionExtensionsDoc, api.conversationId)).extensions[args.name];
								await this.select(tx, sessionId);
							}, context);
							this.unload(own);
							return { output: [{ type: "text", text: `Removed ${args.name} from this session.` }] };
						}
						if (this.loaded.has(shared) && args.scope === "default") {
							await api.commit(async (tx) => {
								delete (await tx.doc(DefaultExtensionsDoc, rootId())).extensions[args.name];
							}, context);
							this.unload(shared);
							return { output: [{ type: "text", text: `Removed ${args.name} from every session.` }] };
						}
						if (this.loaded.has(shared)) {
							await api.commit(async (tx) => {
								const doc = await tx.doc(SessionExtensionsDoc, api.conversationId);
								if (!doc.withoutDefaults.includes(args.name)) doc.withoutDefaults.push(args.name);
								await this.select(tx, sessionId);
							}, context);
							return { output: [{ type: "text", text: `Left the default extension ${args.name} out of this session.` }] };
						}
						return { output: [{ type: "text", text: `No extension named ${args.name}.` }], isError: true };
					},
				}),
				defineTool({
					name: "extension_list",
					description: "List the extensions this session has: its own and the defaults.",
					parameters: Type.Object({}),
					replay: "safe",
					execute: async (_args, api) => {
						const lines = this.list(sessionOf(api)).map((item) => `- ${describe(item, item.scope)}${item.left ? " — left out of this session" : ""}`);
						return { output: [{ type: "text", text: lines.length > 0 ? lines.join("\n") : "No extensions yet." }] };
					},
				}),
				defineTool({
					name: "apps_list",
					description:
						"List the session's apps: pages its extensions offer (pi.registerApp) that the user keeps in the session's dock, above the message box. Says which run (on screen or minimized) and what each is for.",
					parameters: Type.Object({}),
					replay: "safe",
					execute: async (_args, api, context) => {
						const { running, available } = await this.apps(sessionOf(api), context);
						if (available.length === 0) return { output: [{ type: "text", text: "This session's extensions offer no apps." }] };
						const status = (key: string) => {
							const app = running.find((each) => each.key === key);
							return !app ? "not running" : app.visible ? "on screen" : "minimized in the dock";
						};
						const lines = available.map(
							(app) =>
								`- ${app.name} ("${app.title}", from ${app.extension}${app.shared ? ", shared by every session" : ""}): ${status(app.key)}${app.description ? ` — ${app.description}` : ""}`,
						);
						return { output: [{ type: "text", text: lines.join("\n") }] };
					},
				}),
				defineTool({
					name: "app_open",
					description:
						"Open one of the session's apps for the user (apps_list names them), or bring it back on screen from the dock. With minimized: true it goes to the dock without taking the screen.",
					parameters: Type.Object({
						name: Type.String({ description: "The app's name (or extension/name when two extensions offer one with that name)" }),
						minimized: Type.Optional(Type.Boolean({ description: "Put it in the dock, not on screen" })),
					}),
					replay: "safe",
					execute: async (args, api, context) => {
						const sessionId = sessionOf(api);
						const found = await this.findApp(sessionId, args.name, context);
						if (typeof found === "string") return { output: [{ type: "text", text: found }], isError: true };
						await this.openApp(sessionId, found.key, { visible: args.minimized !== true }, context);
						return { output: [{ type: "text", text: args.minimized ? `${found.title} is in the dock.` : `${found.title} is open on the user's screen.` }] };
					},
				}),
				defineTool({
					name: "app_close",
					description: "Close one of the session's running apps (it leaves the dock; what it saved stays for the next time it opens).",
					parameters: Type.Object({ name: Type.String({ description: "The app's name (or extension/name)" }) }),
					replay: "safe",
					execute: async (args, api, context) => {
						const sessionId = sessionOf(api);
						const found = await this.findApp(sessionId, args.name, context);
						if (typeof found === "string") return { output: [{ type: "text", text: found }], isError: true };
						await endApp(sessionId, found.key);
						return { output: [{ type: "text", text: `Closed ${found.title}.` }] };
					},
				}),
			],
		});
	}

	// ---- sharing ----

	/** A session's extension (or a default) as a shared extension file's contents. */
	async share(name: string, sessionId?: number): Promise<SharedExtension> {
		const loaded =
			(sessionId === undefined ? undefined : this.loaded.get(Extensions.registryName("session", name, sessionId))) ??
			this.loaded.get(Extensions.registryName("default", name));
		if (!loaded) throw new Error(`No extension named ${name}`);
		const { record } = loaded;
		const shared: SharedExtension = {
			pi: "extension",
			format: 1,
			name: record.name,
			...(record.version ? { version: record.version } : {}),
			tools: loaded.tools,
			apps: loaded.adapted.offeredApps,
		};
		if (record.kind !== "path") return { ...shared, source: record.source };
		const { root, files } = await this.packageOf(record, sessionId);
		const inside = (path: string) => (path.startsWith(`${root}/`) ? [path.slice(root.length + 1)] : []);
		const contents: Record<string, string> = {};
		let size = 0;
		for (const file of files.filter((each) => !each.includes("/node_modules/"))) {
			const data = await request<string>("fs", "readBinary", { path: file });
			size += (data.length * 3) / 4;
			if (size > SHARE_LIMIT) throw new Error(`${record.name} is too big to share (over 10 MB)`);
			contents[file.slice(root.length + 1)] = data;
		}
		let description: string | undefined;
		try {
			const manifest = contents["package.json"];
			if (manifest) description = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(manifest), (c) => c.charCodeAt(0)))).description;
		} catch {}
		return {
			...shared,
			...(typeof description === "string" ? { description } : {}),
			files: contents,
			entries: record.entries.flatMap((entry) => inside(this.entryPath(record, entry, sessionId))),
			skills: (record.skills ?? []).flatMap((skill) => inside(this.entryPath(record, skill, sessionId))),
		};
	}

	/** A path extension's folder and files: its installed copy, or (a session's own) its package, or its file with what it imports. */
	private async packageOf(record: ExtensionRecord, sessionId?: number): Promise<{ root: string; files: string[] }> {
		const installed = `${this.installRoot}/local/${record.name.replace("/", "+")}`;
		if (record.base !== "workspace" && (await exists(installed))) return { root: installed, files: await listFiles(installed) };
		const cwd = sessionId === undefined ? this.neutralEnv.cwd : this.sessionEnv(sessionId).cwd;
		const source = record.source.startsWith("/") ? record.source : normalize(`${cwd}/${record.source}`);
		if ((await request<{ kind: string }>("fs", "stat", { path: source })).kind === "directory") return { root: source, files: await listFiles(source) };
		const runtime = new ModuleRuntime(this.neutralEnv, hostModules(this.codingAgent));
		await runtime.prepare(source);
		const root = dirname(source);
		return { root, files: runtime.files.filter((file) => file.startsWith(`${root}/`)) };
	}

	// ---- background checks ----

	/** The background checks the defaults registered (`pi.registerCheck`), which the app runs when iOS wakes it. */
	checks(): { key: string; extension: string; name: string; description: string | null; every: number }[] {
		return this.defaultChecks().map(({ key, extension, check }) => ({ key, extension, name: check.name, description: check.description ?? null, every: check.every }));
	}

	/** Runs one background check within `timeoutMs`: what it returned (a short text), or what it threw. */
	async runCheck(key: string, timeoutMs: number): Promise<{ result: string | null }> {
		const found = this.defaultChecks().find((each) => each.key === key);
		if (!found) throw new Error(`No background check ${key}`);
		const controller = new AbortController();
		const timedOut = new Promise<never>((_, reject) => {
			controller.signal.addEventListener("abort", () => reject(new Error(`didn't finish in ${Math.round(timeoutMs / 1000)} seconds`)));
		});
		const timer = setTimeout(() => controller.abort(), timeoutMs);
		try {
			const value = await Promise.race([Promise.resolve(found.check.run({ signal: controller.signal })), timedOut]);
			return { result: typeof value === "string" ? value : value == null ? null : JSON.stringify(value) };
		} finally {
			clearTimeout(timer);
		}
	}

	/** A widget button's action (`id`: the widget's app), run in the background within `timeoutMs`. */
	async runWidgetAction(id: string, action: string, value: unknown, timeoutMs: number): Promise<null> {
		const { extension, app, sessionId } = parseWidgetId(id);
		const loaded = this.loaded.get(sessionId === undefined ? Extensions.registryName("default", extension) : Extensions.registryName("session", extension, sessionId));
		if (!loaded || loaded.record.disabled) throw new Error(`${extension} isn't in pi (removed or turned off)`);
		const handler = loaded.adapted.widgetAction(action);
		if (!handler) throw new Error(`${extension} has no widget action ${action}`);
		await runAction(handler, app, value, timeoutMs);
		return null;
	}

	private defaultChecks(): { key: string; extension: string; check: CheckDefinition }[] {
		return [...this.loaded]
			.filter(([name, loaded]) => name.startsWith("default:") && !loaded.record.disabled)
			.flatMap(([name, loaded]) => loaded.adapted.checks.map((check) => ({ key: `${extensionOf(name)}/${check.name}`, extension: extensionOf(name), check })));
	}

	// ---- source ----

	/**
	 * An extension's source, to read and change in Settings: its folder (a path extension's package, or the installed
	 * package around its entry) and its files there by relative path, without its dependencies.
	 */
	async source(name: string, sessionId?: number): Promise<{ root: string; files: string[] }> {
		const { record } = this.named(name, sessionId);
		let root: string;
		let files: string[];
		if (record.kind === "path") ({ root, files } = await this.packageOf(record, sessionId));
		else {
			root = await packageFolder(this.entryPath(record, record.entries[0] ?? "", sessionId), this.installRoot);
			files = await listFiles(root);
		}
		const relativePaths = files.map((file) => file.slice(root.length + 1)).filter((file) => !/(^|\/)(node_modules|\.git)\//.test(file));
		return { root, files: relativePaths.sort() };
	}

	/** Loads an extension again where it's loaded (a default, or a session's own), after its files changed. */
	async reload(name: string, sessionId?: number): Promise<void> {
		const { record, scope } = this.named(name, sessionId);
		await this.load(record, scope, scope === "session" ? sessionId : undefined);
	}

	/** A session's own extension of that name, else the default. */
	private named(name: string, sessionId?: number): { record: ExtensionRecord; scope: Scope } {
		const own = sessionId === undefined ? undefined : this.loaded.get(Extensions.registryName("session", name, sessionId));
		if (own) return { record: own.record, scope: "session" };
		const loaded = this.loaded.get(Extensions.registryName("default", name));
		if (!loaded) throw new Error(`No extension named ${name}`);
		return { record: loaded.record, scope: "default" };
	}

	/** Adds a shared extension (a .piext file the user opened) for every session: from its source, or from its files. */
	async importShared(root: Conversation, shared: SharedExtension, context: Context): Promise<InstalledExtension> {
		if (shared?.pi !== "extension" || typeof shared.name !== "string" || !shared.name) throw new Error("This is not a pi extension");
		if (shared.source) return this.addDefault(root, shared.source, context);
		const files = shared.files ?? {};
		const paths = Object.keys(files);
		if (paths.length === 0) throw new Error(`${shared.name}: the file has no extension code`);
		for (const path of paths) {
			if (path.startsWith("/") || path.split("/").some((part) => part === ".." || part === "")) throw new Error(`${shared.name}: unsafe path ${path}`);
		}
		const staging = `${this.installRoot}/shared/${shared.name.replace(/[^\w.-]+/g, "+")}`;
		await request("fs", "rm", { path: staging, recursive: true, force: true });
		try {
			for (const [path, data] of Object.entries(files)) {
				const target = `${staging}/${path}`;
				await request("fs", "mkdir", { path: dirname(target), recursive: true });
				await request("fs", "write", { path: target, data });
			}
			// A package installs from its folder; a single file (with the modules it imports) from the file. Either way
			// it is copied into the extensions folder.
			const entry = shared.entries?.[0];
			const installed = await this.addDefault(root, paths.includes("package.json") || !entry ? staging : `${staging}/${entry}`, context);
			const source = `shared: ${shared.name}`;
			await root.commit(async (tx) => {
				const record = (await tx.doc(DefaultExtensionsDoc, root.id)).extensions[installed.name];
				if (record) record.source = source;
			}, context);
			return { ...installed, source };
		} finally {
			await request("fs", "rm", { path: staging, recursive: true, force: true }).catch(() => {});
		}
	}

	// ---- apps ----

	/** The apps a session's extensions offer, in load order. */
	private async offeredApps(sessionId: number, context: Context): Promise<{ extension: string; loaded: Loaded; definition: AppDefinition }[]> {
		const offered: { extension: string; loaded: Loaded; definition: AppDefinition }[] = [];
		for (const loaded of await this.selected(sessionId, context)) {
			const definitions = await loaded.adapted.apps(sessionId).catch((error: unknown) => {
				console.warn(`${loaded.record.name}: apps: ${message(error)}`);
				return [];
			});
			for (const definition of definitions) offered.push({ extension: loaded.record.name, loaded, definition });
		}
		return offered;
	}

	/** A session's dock (the apps it runs) and launcher (the apps its extensions offer). */
	async apps(sessionId: number, context: Context) {
		return listApps(sessionId, await this.offeredApps(sessionId, context));
	}

	/** Opens a session's app by key (extension/name), or shows it, running; `visible: false` puts it in the dock.
	 * `target`: a widget's tap area opened it, for the app's `onWidgetOpen`. */
	async openApp(sessionId: number, key: string, options: { visible?: boolean; target?: string }, context: Context): Promise<AppHandle> {
		const offer = (await this.offeredApps(sessionId, context)).find((each) => appKey(each.extension, each.definition.name) === key);
		if (!offer) throw new Error(`No app ${key} in this session`);
		const app = await offer.loaded.adapted.openApp(sessionId, offer.definition.name, { visible: options.visible });
		if (!app) throw new Error(`No app ${key} in this session`);
		if (options.target !== undefined && offer.definition.onWidgetOpen) {
			try {
				await offer.definition.onWidgetOpen(options.target, app);
			} catch (error) {
				console.warn(`${key}: onWidgetOpen: ${message(error)}`);
			}
		}
		return app;
	}

	/** Closes a session's app by key, running or only in its dock. */
	closeApp(sessionId: number, key: string): Promise<void> {
		return endApp(sessionId, key);
	}

	/** An app the session offers, by name, extension/name, or title; or why there is none. */
	private async findApp(sessionId: number, name: string, context: Context): Promise<{ key: string; title: string } | string> {
		const { available } = await this.apps(sessionId, context);
		const wanted = name.trim().toLowerCase();
		const matches = available.filter((app) => app.key.toLowerCase() === wanted || app.name.toLowerCase() === wanted || app.title.toLowerCase() === wanted);
		if (matches.length === 1) return matches[0]!;
		if (matches.length > 1) return `Several apps are named ${name}: ${matches.map((app) => app.key).join(", ")}. Pass extension/name.`;
		return available.length === 0
			? "This session's extensions offer no apps."
			: `No app named ${name}. The session's apps: ${available.map((app) => app.name).join(", ")}.`;
	}

	/** The session's extensions and the defaults (with whether the session leaves each out). */
	list(sessionId: number, withoutDefaults: string[] = []): (Loaded & { scope: Scope; left: boolean })[] {
		const items: (Loaded & { scope: Scope; left: boolean })[] = [];
		for (const [name, loaded] of this.loaded) {
			if (name.startsWith("default:")) items.push({ ...loaded, scope: "default", left: withoutDefaults.includes(loaded.record.name) });
			else if (name.startsWith(`session:${sessionId}:`)) items.push({ ...loaded, scope: "session", left: false });
		}
		return items;
	}

	// ---- Settings → Extensions ----

	/** Every installed extension, for the app: the defaults (on or off) and each session's own. */
	async inventory(rootId: ConversationId, sessions: { id: number; title?: string }[], context: Context): Promise<InstalledExtensions> {
		const harness = this.host.harness();
		const item = (record: ExtensionRecord, loaded: Loaded | undefined): InstalledExtension => ({
			name: record.name,
			version: record.version ?? null,
			source: record.source,
			kind: record.kind,
			revision: record.revision ?? null,
			enabled: !record.disabled,
			tools: loaded?.tools ?? [],
			skills: (record.skills?.length ?? 0) > 0,
			notes: loaded?.notes ?? [],
			addedAt: record.addedAt,
		});
		const defaults = Object.values((await harness.snapshot(DefaultExtensionsDoc, rootId, context))?.extensions ?? {}).map((record) =>
			item(record, this.loaded.get(Extensions.registryName("default", record.name))),
		);
		const own: InstalledExtensions["sessions"] = [];
		for (const session of sessions) {
			const records = Object.values((await harness.snapshot(SessionExtensionsDoc, session.id as ConversationId, context))?.extensions ?? {});
			if (records.length === 0) continue;
			own.push({
				id: session.id,
				title: session.title ?? null,
				extensions: records.map((record) => item(record, this.loaded.get(Extensions.registryName("session", record.name, session.id)))),
			});
		}
		return { defaults: defaults.sort((a, b) => a.name.localeCompare(b.name)), sessions: own };
	}

	/** Adds a default from Settings: npm:<package>, git:<url>, or an absolute path. */
	async addDefault(root: Conversation, source: string, context: Context): Promise<InstalledExtension> {
		const record = await this.fetch(source, this.neutralEnv.cwd, "default", this.neutralEnv.cwd);
		const loaded = await this.load(record, "default");
		await root.commit(async (tx) => {
			(await tx.doc(DefaultExtensionsDoc, root.id)).extensions[record.name] = record;
		}, context);
		return { name: record.name, version: record.version ?? null, source: record.source, kind: record.kind, revision: record.revision ?? null, enabled: true, tools: loaded.tools, skills: (record.skills?.length ?? 0) > 0, notes: loaded.notes, addedAt: record.addedAt };
	}

	/** Turns a default on (loaded into every session that keeps it) or off (kept, loaded nowhere). */
	async setDefaultEnabled(root: Conversation, name: string, enabled: boolean, context: Context): Promise<void> {
		// Turned back on by the user: no longer held for freezing the engine.
		if (enabled) this.held.delete(name);
		let record: ExtensionRecord | undefined;
		await root.commit(async (tx) => {
			const doc = await tx.doc(DefaultExtensionsDoc, root.id);
			const stored = doc.extensions[name];
			if (!stored) throw new Error(`No default extension named ${name}`);
			if (enabled) delete stored.disabled;
			else stored.disabled = true;
			// A plain copy: the document's value ends with the commit.
			record = JSON.parse(JSON.stringify(stored)) as ExtensionRecord;
		}, context);
		if (enabled) await this.loadOrPlaceholder(record!, "default");
		else this.unload(Extensions.registryName("default", name));
	}

	/** Removes a default from every session. */
	async removeDefault(root: Conversation, name: string, context: Context): Promise<void> {
		await root.commit(async (tx) => {
			delete (await tx.doc(DefaultExtensionsDoc, root.id)).extensions[name];
		}, context);
		this.unload(Extensions.registryName("default", name));
		forgetApps(Extensions.registryName("default", name));
	}

	/** Removes a session's own extension. */
	async removeFromSession(sessionId: number, name: string, context: Context): Promise<void> {
		const conversation = await this.host.harness().conversation(sessionId as ConversationId, context);
		if (!conversation) throw new Error(`No session ${sessionId}`);
		await conversation.commit(async (tx) => {
			delete (await tx.doc(SessionExtensionsDoc, sessionId as ConversationId)).extensions[name];
			await this.select(tx, sessionId);
		}, context);
		this.unload(Extensions.registryName("session", name, sessionId));
		forgetApps(Extensions.registryName("session", name, sessionId));
	}

	/** Makes a session's extension a default for every session (a workspace path is copied), and takes it out of the
	 * session, which now gets it as a default. */
	async makeDefault(root: Conversation, sessionId: number, name: string, context: Context): Promise<void> {
		const harness = this.host.harness();
		const own = (await harness.snapshot(SessionExtensionsDoc, sessionId as ConversationId, context))?.extensions[name];
		if (!own) throw new Error(`Session ${sessionId} has no extension named ${name}`);
		const workspace = this.sessionEnv(sessionId).cwd;
		const record = own.base === "workspace" ? await this.fetch(own.source, workspace, "default", workspace) : { ...own, addedAt: Date.now() };
		await this.removeFromSession(sessionId, name, context);
		await this.load(record, "default");
		await root.commit(async (tx) => {
			(await tx.doc(DefaultExtensionsDoc, root.id)).extensions[record.name] = record;
		}, context);
	}

	/** Forgets a deleted session's extensions, and its instances of the defaults. */
	forget(sessionId: number): void {
		for (const [name, loaded] of [...this.loaded]) {
			if (name.startsWith(`session:${sessionId}:`)) {
				this.unload(name);
				forgetApps(name);
			} else if (name.startsWith("default:")) void loaded.adapted.shutdown("quit", sessionId);
		}
		this.host.histories.forget(sessionId);
	}

	/**
	 * Before the app submits a prompt: the session's extensions may rewrite it or take it (`input`), add messages that
	 * go before it, and replace the system prompt of the run it starts (`before_agent_start`).
	 */
	async prompt(sessionId: number, text: string, context: Context): Promise<Prompt> {
		await this.host.histories.refresh(sessionId);
		let prompt: Prompt = { text, handled: false, messages: [], systemPrompt: this.host.histories.systemPrompt(sessionId) };
		for (const loaded of await this.selected(sessionId, context)) {
			const before: Prompt = prompt;
			// Stopped while an extension reads the message: it isn't sent.
			prompt = await this.forUser(sessionId, loaded.record.name, "reading your message", () => loaded.adapted.prompt(sessionId, before), {
				...before,
				handled: true,
			});
			if (prompt.handled) break;
		}
		return prompt;
	}

	/** What extensions are doing in each session for the user (commands, reading a message before it's sent), by task id. */
	private forUserTasks = new Map<number, Map<number, { extension: string; what: string; startedAt: number; controller: AbortController }>>();
	private nextTask = 1;

	/**
	 * Runs an extension's handler as one of the session's tasks for the user, which Stop ends (`stopForUser`): the handler
	 * gets the abort signal, and the session stops waiting for it even when it ignores the signal (`stopped` is then the
	 * result). The app hears the session's tasks (`extension_tasks`) as they start and end; it shows the ones that take a
	 * moment, so quick ones don't flash.
	 */
	private async forUser<T>(sessionId: number, extension: string, what: string, run: (signal: AbortSignal) => Promise<T>, stopped: T): Promise<T> {
		const controller = new AbortController();
		const id = this.nextTask++;
		const tasks = this.forUserTasks.get(sessionId) ?? new Map();
		this.forUserTasks.set(sessionId, tasks);
		const task = { extension, what, startedAt: Date.now(), controller };
		tasks.set(id, task);
		// At once (the app shows a task once it takes a moment): if the extension then holds the engine, the app knows whose.
		this.announceTasks(sessionId);
		const aborted = new Promise<"stopped">((resolve) => controller.signal.addEventListener("abort", () => resolve("stopped"), { once: true }));
		try {
			const result = await Promise.race([run(controller.signal), aborted]);
			return result === "stopped" && controller.signal.aborted ? stopped : (result as T);
		} finally {
			tasks.delete(id);
			if (tasks.size === 0) this.forUserTasks.delete(sessionId);
			this.announceTasks(sessionId);
		}
	}

	/** The session's tasks for the user, for the app's indicator. */
	private announceTasks(sessionId: number): void {
		const tasks = [...(this.forUserTasks.get(sessionId)?.entries() ?? [])].map(([id, task]) => ({
			id,
			extension: task.extension,
			what: task.what,
			startedAt: task.startedAt,
		}));
		emit({ type: "extension_tasks", sessionId, tasks });
	}

	/** Stop: ends the session's tasks for the user (or the one `taskId` names); how many it ended. */
	stopForUser(sessionId: number, taskId?: number): number {
		let stopped = 0;
		for (const [id, task] of this.forUserTasks.get(sessionId) ?? []) {
			if (taskId !== undefined && id !== taskId) continue;
			console.warn(`[${task.extension}] stopped by the user: ${task.what}`);
			task.controller.abort(new Error("Stopped by the user"));
			stopped++;
		}
		return stopped;
	}

	/** A `!command` the user runs: the first extension that runs or answers it (`user_bash`). */
	async userBash(sessionId: number, command: string, excludeFromContext: boolean, context: Context): Promise<UserBash | undefined> {
		for (const loaded of await this.selected(sessionId, context)) {
			const outcome = await loaded.adapted.userBash(sessionId, command, excludeFromContext);
			if (outcome) return outcome;
		}
		return undefined;
	}

	/** The session's agent events, for the events extensions get from them (streaming, messages, failed compactions). */
	observe(sessionId: number, events: readonly AgentEvent[], context: Context): void {
		if (this.loaded.size === 0) return;
		const previous = this.observing.get(sessionId) ?? Promise.resolve();
		const next = previous
			.then(async () => {
				for (const loaded of await this.selected(sessionId, context)) await loaded.adapted.observe(sessionId, events);
			})
			.catch((error: unknown) => console.warn(`extensions: ${message(error)}`));
		this.observing.set(sessionId, next);
	}

	/** The skill folders of a session's extension packages, in load order. */
	async skillRoots(sessionId: number, context: Context): Promise<{ dir: string; source: string }[]> {
		return (await this.selected(sessionId, context)).flatMap(({ record }) =>
			(record.skills ?? []).map((skill) => ({ dir: this.entryPath(record, skill, sessionId), source: record.name })),
		);
	}

	/** pi's agent folder (~/.pi/agent): its skills/ folder holds skills for every session. */
	get agentDir(): string {
		return `${this.installRoot}/agent`;
	}

	/** The slash commands of a session's extensions, for the app to suggest. */
	async commands(sessionId: number, context: Context): Promise<{ name: string; description?: string; extension: string }[]> {
		return (await this.resolvedCommands(sessionId, context)).map(({ invocation, description, loaded }) => ({ name: invocation, description, extension: loaded.record.name }));
	}

	/** Runs `/name args` when an extension of the session registered `name`; false when none did. */
	async runCommand(sessionId: number, text: string, context: Context): Promise<boolean> {
		const match = /^\/(\S+)\s*([\s\S]*)$/.exec(text.trim());
		if (!match) return false;
		const command = (await this.resolvedCommands(sessionId, context)).find(({ invocation }) => invocation === match[1]);
		if (!command) return false;
		return this.forUser(sessionId, command.loaded.record.name, `/${command.invocation}`, (signal) => command.loaded.adapted.runCommand(sessionId, command.name, match[2]!, signal), true);
	}

	/** The session's commands in load order, named as pi names them: a name two extensions register becomes `name:1`, `name:2`, …. */
	private async resolvedCommands(sessionId: number, context: Context) {
		const commands: { name: string; description?: string; loaded: Loaded }[] = [];
		for (const loaded of await this.selected(sessionId, context)) {
			for (const command of await loaded.adapted.commands(sessionId)) commands.push({ ...command, loaded });
		}
		const counts = new Map<string, number>();
		for (const { name } of commands) counts.set(name, (counts.get(name) ?? 0) + 1);
		const seen = new Map<string, number>();
		const taken = new Set<string>();
		return commands.map((command) => {
			const occurrence = (seen.get(command.name) ?? 0) + 1;
			seen.set(command.name, occurrence);
			let suffix = occurrence;
			let invocation = (counts.get(command.name) ?? 0) > 1 ? `${command.name}:${suffix}` : command.name;
			while (taken.has(invocation)) invocation = `${command.name}:${++suffix}`;
			taken.add(invocation);
			return { ...command, invocation };
		});
	}

	/** Before the session is forked at an entry: true when an extension cancels (`session_before_fork`). */
	async beforeFork(sessionId: number, entryId: number, context: Context): Promise<boolean> {
		for (const loaded of await this.selected(sessionId, context)) if (await loaded.adapted.beforeFork(sessionId, entryId)) return true;
		return false;
	}

	/**
	 * A session forked from `sourceId` gets its own copies of the source's extensions (workspace paths resolve in its
	 * copy of the workspace), and its instances start with `session_start` reason "fork".
	 */
	async forked(sourceId: number, forkId: number, context: Context): Promise<void> {
		this.forks.set(forkId, sourceId);
		const harness = this.host.harness();
		const source = await harness.snapshot(SessionExtensionsDoc, sourceId as ConversationId, context);
		const records = Object.values(source?.extensions ?? {});
		for (const record of records) await this.loadOrPlaceholder(record, "session", forkId);
		const conversation = await harness.conversation(forkId as ConversationId, context);
		if (!conversation) return;
		await conversation.commit(async (tx) => {
			const doc = await tx.doc(SessionExtensionsDoc, forkId as ConversationId);
			doc.extensions = structuredClone(source?.extensions ?? {});
			doc.withoutDefaults = [...(source?.withoutDefaults ?? [])];
			// The fork's agent came with the source's own extensions selected; it has its own now.
			const inherited = records
				.map((record) => this.loaded.get(Extensions.registryName("session", record.name, sourceId))?.extension)
				.filter((extension): extension is Extension => extension !== undefined);
			await configure(tx, forkId as ConversationId, { extensions: { remove: inherited } });
			await this.select(tx, forkId);
		}, context);
	}

	/** The system prompt `before_agent_start` set for the run in progress: from its entry until the run's answer. */
	private async replacedSystemPrompt(conversationId: number): Promise<string | undefined> {
		const { histories } = this.host;
		await histories.refresh(conversationId);
		const entries = histories.entries(conversationId);
		for (let index = entries.length - 1; index >= 0; index--) {
			const entry = entries[index]!;
			if (entry.type === "custom" && entry.customType === SYSTEM_PROMPT_ENTRY) return String((entry.data as { systemPrompt?: unknown } | undefined)?.systemPrompt ?? "");
			const answer = entry.message as { role?: string; stopReason?: string } | undefined;
			if (answer?.role === "assistant" && answer.stopReason !== "toolUse") return undefined;
		}
		return undefined;
	}

	/** Delivers an event (such as `model_select`) to the session's instances of its extensions. */
	async notify(sessionId: number, event: { type: string; [key: string]: unknown }, context: Context): Promise<void> {
		for (const loaded of await this.selected(sessionId, context)) await loaded.adapted.notify(sessionId, event);
	}

	/** The extensions in a session's selection: the defaults it keeps, then its own. */
	private async selected(sessionId: number, context: Context): Promise<Loaded[]> {
		const doc = await this.host.harness().snapshot(SessionExtensionsDoc, sessionId as ConversationId, context);
		const left = new Set(doc?.withoutDefaults ?? []);
		return [...this.loaded].flatMap(([name, loaded]) =>
			(name.startsWith("default:") && !left.has(loaded.record.name)) || name.startsWith(`session:${sessionId}:`) ? [loaded] : [],
		);
	}

	private unload(name: string): void {
		const loaded = this.loaded.get(name);
		if (!loaded) return;
		this.loaded.delete(name);
		this.registry.uninstall(loaded.extension);
		if (name.startsWith("default:")) this.updateDefaults();
		forgetSkills();
		void loaded.adapted.shutdown("quit");
	}
}

function loadedOf(record: ExtensionRecord, adapted: Adapted): Loaded {
	return {
		record,
		adapted,
		get extension() {
			return adapted.extension;
		},
		get tools() {
			return adapted.tools;
		},
		get notes() {
			return adapted.notes;
		},
	};
}

/** Keeps a name that failed to load resolvable, so its sessions still run; extension_list shows why it has no tools. */
function failed(name: string, note: string): Adapted {
	return {
		extension: defineExtension({ name }),
		tools: [],
		notes: [note],
		prompt: async (_, prompt) => prompt,
		notify: async () => {},
		observe: async () => {},
		userBash: async () => undefined,
		beforeFork: async () => false,
		commands: async () => [],
		runCommand: async () => false,
		apps: async () => [],
		openApp: async () => undefined,
		offeredApps: [],
		widgetAction: () => undefined,
		checks: [],
		shutdown: async () => {},
	};
}

/** How to write and add pi extensions here: the environment guide's `extensions` topic. */
export const EXTENSIONS_GUIDE = `You can extend yourself with pi extensions (pi-coding-agent's format), for this session or as a default for every session.
- An extension is a TypeScript or JavaScript module: \`import { Type } from "@earendil-works/pi-ai"; export default function (pi) { pi.registerTool({ name, description, parameters: Type.Object({ ... }), async execute(toolCallId, params, signal, onUpdate, ctx) { return { content: [{ type: "text", text: "..." }] }; } }); }\`. pi.exec(command, args) runs a shell command; ctx.cwd is the session's workspace. Type is TypeBox, not Zod: an optional parameter is Type.Optional(Type.Number({ description })), never .optional().
- To add one you wrote, save it in the workspace (for example .pi/extensions/name.ts) and call extension_add with its path; after editing it, extension_reload. To add a published one, extension_add npm:<package>[@version] or git:<url>. Its tools are available from your next step. A default added from a path is copied (with the files it imports from its folder), so it outlives this session.
- No build step, and never Crabbox: write the extension as a .ts or .js file here and extension_add it. The app compiles TypeScript itself and bundles nothing; adding a folder with a package.json installs its dependencies (pure JavaScript npm packages). Do not run npm, tsc, a bundler, or tests for it on a Crabbox box: it would not run there (it needs this app's pi and ctx.ui), and nothing built there is used here. To test it, call its new tool yourself right after extension_add (it is yours from your next step), or ask the user to run its /command; extension_add and extension_list report load errors.
- pi.on(event, handler) works for pi's events: tool_call (block or change arguments), tool_result, tool_execution_*, context, context_with_system, input, before_agent_start (add a message, replace the system prompt), agent_start, agent_end (pi.sendUserMessage there continues the run), agent_before_settle, agent_settled, turn_start, turn_end, message_start/update/end, before_provider_request, before_provider_headers, after_provider_response, provider_stream_event, user_bash (the user's !command), session_start, session_before_fork, session_before_compact, session_compact, session_compact_failed, session_shutdown, model_select, and session_info_changed. ctx.sessionManager.getBranch() returns the session's history.
- pi.registerCommand adds a /command the user runs from the message box. ctx.ui dialogs (select, confirm, input, editor), notify, setStatus, setWidget, setFooter, setEditorText, and ctx.ui.custom show in the app; pi-tui components (SelectList, Input, Editor, Text, Markdown, Loader, Container, …) become native views you tap, other components show their rendered lines with a key bar. On iOS there is also ctx.ui.panel({ html, title, placement: "sheet" | "widget", onMessage }) for an HTML page (in it, pi.post(data), pi.onMessage(callback), pi.close(result)); it returns { post, update, close, closed }. Everything @earendil-works/pi-coding-agent exports can be imported; its CLI parts (SessionManager, SettingsManager, createAgentSession, built-in tool factories) throw.
- Stopping (required): the user can stop anything an extension does for them (Stop, Send now), and every extension must honor it: ignoring the signal is not allowed. A command's handler gets ctx.signal, a tool's execute gets signal (its third argument), and a background check's run gets { signal }. Pass it on to everything that waits (fetch(url, { signal }), pi.exec(command, args, { signal }), child_process), clear timers and end loops when it aborts (signal.addEventListener(\"abort\", ...), if (signal.aborted) return), and stop promptly, saying so if it matters (ctx.ui.notify). Never block the engine: no long synchronous loops or busy waits, as pi's engine runs everything in one thread and nothing else (not even Stop) runs while such code does; break long work into awaited steps. An extension that ignores Stop is cut off anyway and keeps running unseen, which the user sees as a broken extension.
- Apps (iOS): for a page the user keeps using, not a one-off sheet, register an app: pi.registerApp({ name, title, icon (an SF Symbol name, e.g. "airplane"), description, render: (app) => html, onMessage: (data, app) => …, onOpen/onMinimize/onRestore/onClose?, shared?: true for one app in every session }). It opens in a sheet; closing the sheet minimizes it to the session's dock above the message box, with its page still running, and only Close ends it. Its record and saved state outlive relaunches: render(app) draws the page from app.state when it opens again. Open it with pi.apps.open(name, { visible?: false }) (from a command, a tool, or an event); pi.apps.get(name) finds it running. The handle: app.post(data) to the page, app.setState(json), app.state, app.setBadge("3") on its dock entry, app.setTitle, app.refresh() (render again), app.show(), app.minimize(), app.close(), app.closed, app.ui (the session's ctx.ui). In the page: pi.post(data), pi.onMessage(callback), pi.state.get()/set(json)/onChange(callback) (saved with the app), pi.minimize(), pi.close(). Keep what the page shows in app.state or the extension's own storage, so a page drawn again after a relaunch looks the same. You can list and open the session's apps yourself (apps_list, app_open, app_close). ctx.ui.panel({ …, persistent: true, icon }) is a quick app that minimizes the same way but ends with the engine.
- Home Screen widgets and Live Activities (iOS): any app can go on the Home Screen as a widget that opens it full screen, and an extension can show something in progress on the Lock Screen and in the Dynamic Island (pi.liveActivity). It draws both with native views described as JSON (pi.widget.update), and their buttons can run its code in the background without opening pi (pi.widget.onAction). Read environment_guide topic widgets before you write either.
- Synced storage (iOS): pi.synced keeps an extension's small JSON values (128 KB in all) on all the user's devices, through iCloud Keychain: pi.synced.get(key), .set(key, value), .delete(key), .keys(); synchronous. Devices merge it key by key, so keep each record under its own key ("entry:<id>") rather than one list. Changes from another device arrive when pi next starts. Prefer it over a file for settings and records the user expects on every device; secrets go to pi.secrets, sensitive numbers to pi.vault.
- Background checks and notifications (iOS): pi.registerCheck({ name, description, every: minutes (15 at least), run: async ({ signal }) => short text }) runs when iOS wakes pi (as often as iOS decides: often every 15 to 60 minutes, not after the user swipes pi away or in Low Power Mode), for a few seconds, without a session or the model, and only for an extension added for every session. It suits polling an API and remembering what it saw (pi.synced); await pi.notify({ title, body, session?, prompt? }) tells the user (asked the first time, like the camera); tapping it opens session (a session's id, or "new"; from a session, that one by default), and with prompt that session gets the message (a new session when there's none, as from a background check), so the agent picks up from there. The user sees each check and its last result in Settings → Extensions.
- Device (iOS): await pi.location() (also ctx.location) gives { latitude, longitude, accuracy, altitude?, timestamp }; an app's page has the same pi.location() and navigator.mediaDevices.getUserMedia for the camera and microphone (or <input type="file" accept="image/*" capture> for one photo). The user is asked the first time each extension wants one and can change it in Settings; a denial rejects (handle it). The engine itself has no camera or microphone: use them from an app's page.
- MCP servers (iOS): an extension's code can call the user's MCP servers (Settings → MCP servers) without the model, with their sign-in: await pi.mcp.servers() gives [{ name, enabled, state, permission: "allowed" | "denied" | "ask", tools: [{ name, title?, description?, inputSchema }] }] (tools only for servers it may use); await pi.mcp.call(server, tool, args) gives the server's result { content, structuredContent?, isError? }. The user is asked the first time each extension calls each server and can change it in Settings → Extensions → the extension → MCP servers; a refusal (or no answer yet, in a background check) rejects, so handle it. The same server added twice under two names is two accounts.
- Vault (iOS): pi.vault keeps sensitive values (card numbers and security codes, passport, ID, license and social security numbers) behind Face ID; keep everything else (names, addresses, expiry dates) in the extension's own storage. pi.vault.add({ kind: "card" | "passport" | "id" | "license" | "ssn" | "note", label: "Chase Sapphire Preferred", fields?: [{ key, label }] }) opens the app's secure sheet, where the user types the values (you never see them), and returns { id, label, hint, fields } (or null); with id, it re-enters an item of yours. pi.vault.set({ id?, kind, label, values?, hint? }) stores values you have, or renames; pi.vault.delete(id) (yours only); pi.vault.list({ kind? }) gives every item's name and hint, never values; pi.vault.choose({ kind, reason }) is the app's picker. To use a value without seeing it: pi.vault.fill(id, { field, ref }) types it into the session's browser page, and pi.vault.placeholder(id, field) ("{{vault:ID/FIELD}}") in a fetch body or header is replaced natively. pi.vault.get(id, { fields, reason }) reveals values only after the user's consent and Face ID; they are masked in what your tools return. Item names are public: the user says "my passport" or "my Chase card".
- Extensions run in this app's JavaScript engine with Node's fs, path, os, crypto, events, util, url, buffer, and asynchronous child_process (exec, execFile, spawn), plus fetch. There is no execSync or spawnSync, and no native Node addons.
- Secrets (API keys): the user adds them in Settings → Extensions and skills → Secrets, for every extension or chosen ones. An extension reads them as process.env.NAME (also in its pi.exec and child_process commands), or with await pi.secrets.get(name) (also ctx.secrets; list() gives the names it may read). To keep one the user gives it, ask with ctx.ui.input, then await pi.secrets.set(name, value): stored in the Keychain for that extension only. Never write a secret to a file, print it, or put it in a tool result; you cannot read secrets yourself, so do not ask the user to paste one into the chat.
- Hardware keys: pi.keys (also ctx.keys) gives an extension its own P-256 keys in the Secure Enclave, which never leave the phone: await pi.keys.create(name, { biometry: "none" | "current-set" }) returns { name, publicKey: { spkiDerBase64, rawXYBase64, x, y } }; "current-set" makes every use ask for Face ID (and the key goes when biometrics change). pi.keys.sign(name, data, { reason }) returns a DER ECDSA SHA-256 signature, base64 (Face ID shows the reason); get, list, delete. pi.keys.setCertificate(name, pemChain) makes the key a TLS client identity: fetch(url, { clientKey: name }) (or pi.keys.fetch(name, url, init)) then presents it (mTLS). For device enrollment and sign-in protocols; never put a key's signature or certificate where it isn't needed.
- Skills (pi's and the Agent Skills format) teach you a workflow without code: a folder with a SKILL.md that starts with frontmatter (name: lowercase-with-hyphens, description: what it does and when to use it), then the instructions, beside any scripts and references it mentions by relative path. A skill in the workspace's .pi/skills/<name>/ is this session's; extension_add the folder with scope "default" to copy it for every session. pi packages added with npm: or git: bring their skills too (package.json "pi.skills", or a skills/ folder). Skills are listed in your prompt by name and description, and the user runs one with /skill:name. Run their scripts with sh or python3 and the script's full path.`;

/** The extension modules a package directory provides: its package.json `pi.extensions`, else its extensions/ folder,
 * else (unless it is a package of skills) its main module. */
async function packageEntries(directory: string, hasSkills = false): Promise<string[]> {
	const manifest = await readManifest(directory);
	const declared = manifest?.pi?.extensions;
	if (Array.isArray(declared) && declared.length > 0) {
		const entries: string[] = [];
		for (const pattern of declared as string[]) {
			const path = normalize(`${directory}/${pattern}`);
			if (path.includes("*")) {
				const folder = path.slice(0, path.lastIndexOf("/"));
				const [prefix, suffix] = path.slice(folder.length + 1).split("*") as [string, string];
				for (const entry of await request<{ name: string }[]>("fs", "readdir", { path: folder })) {
					if (entry.name.startsWith(prefix) && entry.name.endsWith(suffix)) entries.push(`${folder}/${entry.name}`);
				}
			} else if ((await exists(path)) && !(await existsFile(path))) {
				entries.push(...(await folderEntries(path)));
			} else {
				entries.push(path);
			}
		}
		return entries;
	}
	if (await exists(`${directory}/extensions`)) {
		const entries = await folderEntries(`${directory}/extensions`);
		if (entries.length > 0) return entries;
	}
	if (hasSkills) return [];
	const main = manifest?.main ?? manifest?.module;
	const entry = (main && ((await existsFile(`${directory}/${main}`)) ? normalize(`${directory}/${main}`) : undefined)) ?? (await moduleIn(directory));
	if (!entry) throw new Error(`${directory} has no extension or skill: no "pi.extensions" or "pi.skills" in package.json, no extensions/ or skills/ folder, and no index`);
	return [entry];
}

/** A package's skills: its package.json `pi.skills` (folders or files), else its skills/ folder. */
async function packageSkills(directory: string): Promise<string[]> {
	const declared = (await readManifest(directory))?.pi?.skills;
	if (Array.isArray(declared)) {
		const paths = declared.filter((entry): entry is string => typeof entry === "string").map((entry) => normalize(`${directory}/${entry}`));
		const found: string[] = [];
		for (const path of paths) if (await exists(path)) found.push(path);
		return found;
	}
	return (await exists(`${directory}/skills`)) ? [`${directory}/skills`] : [];
}

/** A folder's extension modules, as pi finds them: its index, else its script files and its subfolders' indexes. */
async function folderEntries(folder: string): Promise<string[]> {
	const index = await moduleIn(folder);
	if (index) return [index];
	const entries: string[] = [];
	for (const entry of await request<{ name: string; kind: string }[]>("fs", "readdir", { path: folder })) {
		if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
		const path = `${folder}/${entry.name}`;
		if (entry.kind === "file" && /\.(ts|js|mjs|cjs)$/.test(entry.name) && !entry.name.endsWith(".d.ts")) entries.push(path);
		else if (entry.kind === "directory") {
			const nested = await moduleIn(path);
			if (nested) entries.push(nested);
		}
	}
	return entries;
}

async function moduleIn(directory: string): Promise<string | undefined> {
	for (const name of ["index.ts", "index.js", "index.mjs", "index.cjs"]) {
		if (await existsFile(`${directory}/${name}`)) return `${directory}/${name}`;
	}
	return undefined;
}

async function readManifest(directory: string): Promise<{ name?: string; version?: string; main?: string; module?: string; dependencies?: Record<string, string>; pi?: { extensions?: unknown; skills?: unknown } } | undefined> {
	try {
		return JSON.parse(await request<string>("fs", "readText", { path: `${directory}/package.json` }));
	} catch {
		return undefined;
	}
}

async function exists(path: string): Promise<boolean> {
	try {
		await request("fs", "stat", { path });
		return true;
	} catch {
		return false;
	}
}

async function existsFile(path: string): Promise<boolean> {
	try {
		return (await request<{ kind: string }>("fs", "stat", { path })).kind === "file";
	} catch {
		return false;
	}
}

/** The package an installed entry belongs to: the nearest folder above it with a package.json, up to the install root
 * (an npm or git package, a GitHub folder); without one, the entry's own folder (a single file from GitHub). */
async function packageFolder(entry: string, installRoot: string): Promise<string> {
	for (let folder = dirname(entry); folder.startsWith(`${installRoot}/`); folder = dirname(folder)) {
		if (await existsFile(`${folder}/package.json`)) return folder;
	}
	return dirname(entry);
}

/** Every file under `directory`. */
async function listFiles(directory: string): Promise<string[]> {
	const files: string[] = [];
	for (const entry of await request<{ name: string; kind: string }[]>("fs", "readdir", { path: directory })) {
		const path = `${directory}/${entry.name}`;
		if (entry.kind === "directory") files.push(...(await listFiles(path)));
		else if (entry.kind === "file") files.push(path);
	}
	return files;
}

function dirname(path: string): string {
	return path.slice(0, path.lastIndexOf("/")) || "/";
}

/** `to` relative to the directory `from` (both absolute and normalized). */
function relative(from: string, to: string): string {
	const base = from.split("/").filter(Boolean);
	const target = to.split("/").filter(Boolean);
	let common = 0;
	while (common < base.length && common < target.length && base[common] === target[common]) common++;
	return [...base.slice(common).map(() => ".."), ...target.slice(common)].join("/") || ".";
}

function basename(path: string): string {
	return path.replace(/\/+$/, "").split("/").pop() ?? path;
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

function message(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** A request's messages with one system prompt in place of the agent's: the first system message carries it, and no
 * system message keeps sections (their tool changes stay). */
function replaceSystemPrompt(messages: readonly Message[], prompt: string): Message[] {
	let first = true;
	const replaced = messages.map((each) => {
		if ((each as { role: string }).role !== "system") return each;
		const { sections: _sections, ...rest } = each as Message & { sections?: unknown };
		const system = { ...rest, content: first ? prompt : "" } as Message;
		first = false;
		return system;
	});
	return first ? [{ role: "system", content: prompt, timestamp: Date.now() } as unknown as Message, ...replaced] : replaced;
}

type GitHubSource = { owner: string; repo: string; path: string; ref?: string };

/**
 * A GitHub source: `github:owner/repo[/path][@ref]`, or a github.com URL (`https://github.com/owner/repo`, or its
 * `/tree/<ref>/<path>` or `/blob/<ref>/<path>` page). `git:` keeps cloning with git.
 */
export function gitHubSource(source: string): GitHubSource | undefined {
	const short = /^github:([\w.-]+)\/([\w.-]+)(?:\/([^@]*?))?\/?(?:@(.+))?$/.exec(source);
	if (short) return { owner: short[1], repo: short[2].replace(/\.git$/, ""), path: short[3] ?? "", ...(short[4] ? { ref: short[4] } : {}) };
	const page = /^https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+?)(?:\.git)?(?:\/(?:tree|blob)\/([^/]+)(?:\/(.*?))?)?\/?$/.exec(source);
	if (page) return { owner: page[1], repo: page[2], path: page[4] ?? "", ...(page[3] ? { ref: page[3] } : {}) };
	return undefined;
}

/** A source that downloads code (npm, git, GitHub), as opposed to a path on the device. */
function remoteSource(source: string): boolean {
	return /^(npm|git):/.test(source) || gitHubSource(source) !== undefined || /^https?:\/\//.test(source);
}

function canonicalGitHubSource(spec: GitHubSource): string {
	return `github:${spec.owner}/${spec.repo}${spec.path ? `/${spec.path}` : ""}${spec.ref ? `@${spec.ref}` : ""}`;
}
