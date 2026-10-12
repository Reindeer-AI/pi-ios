/**
 * Runs pi extensions on pi-durable. pi's extensions (pi-coding-agent's format) export a function that receives
 * `pi: ExtensionAPI` and registers tools, event handlers, and commands; this gives them an `ExtensionAPI` and turns
 * what they register into a pi-durable extension. A module that exports a pi-durable extension is used as is.
 *
 * As in pi, an extension's modules load once and its function runs once per session: each conversation gets its own
 * instance (its tools, handlers, and state), created when the conversation first needs it, which delivers
 * `session_start`. `ctx.sessionManager` reads the conversation's history in pi's entry format (`session.ts`).
 *
 * pi's events come from pi-durable's hooks: `tool_call` and `tool_execution_start` from `beforeTool`; `tool_result`,
 * `tool_execution_end`, and the tool result's message events from `afterTool`; `agent_start`, `turn_start`,
 * `context`, and `context_with_system` from `beforeRequest`; the assistant's message events from `afterResponse`;
 * `turn_end` from `afterTools`; `agent_end` (a message sent from it continues the run) and `agent_settled` from
 * `onYield`; `session_before_compact` from `beforeCompact`; `session_compact` when a compaction appears in the history.
 * The engine delivers `input` and `before_agent_start` before it submits a prompt, and `model_select`,
 * `session_info_changed`, and `session_shutdown` itself.
 *
 * A run can resume after the app is killed, so a hook may run again for the same step. Decisions (blocking a tool,
 * continuing a run, replacing a compaction) are kept in the task's memos, so a repeat gives the same answer without
 * calling handlers again; observing events may repeat.
 *
 * What has no counterpart (the terminal UI, commands, providers, other events) is listed in the extension's notes,
 * which the agent sees.
 */
import { keysApi } from "../keys.ts";
import { redact, vaultApi } from "../vault.ts";
import { syncedApi } from "../synced.ts";
import { locationApi, notifyApi } from "../device.ts";
import { mcpApi } from "../mcp.ts";
import { extensionOf, secretEnv, secretsApi } from "../secrets.ts";
import type { JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import * as piAi from "@earendil-works/pi-ai";
import * as piAiCompat from "@earendil-works/pi-ai/compat";
import * as piAiModels from "@earendil-works/pi-ai/models";
import * as piAiProviders from "@earendil-works/pi-ai/providers/all";
import { convertToLlm } from "@earendil-works/pi-coding-agent/dist/core/messages.js";
import { type Message, Type } from "@earendil-works/pi-ai";
import {
	type AgentEvent,
	CompactionTask,
	type Conversation,
	type ConversationId,
	defineExtension,
	defineTool,
	type EntryDraft,
	type EntryId,
	type Extension,
	GenerationTask,
	type Harness,
	type HookApi,
	hook,
	type JsonObject,
	ProviderDoc,
	type Submission,
	type SubmissionDraft,
	type ToolRegistration,
	ToolTask,
	type UserInput,
} from "@earendil-works/pi-durable";
import EventEmitter from "events";
import * as typeboxModule from "typebox";
import * as typeboxCompile from "typebox/compile";
import * as typeboxError from "typebox/error";
import * as typeboxFormat from "typebox/format";
import * as typeboxGuard from "typebox/guard";
import * as typeboxSchema from "typebox/schema";
import * as typeboxSystem from "typebox/system";
import * as typeboxType from "typebox/type";
import * as typeboxValue from "typebox/value";
import { NativeExecutionEnv } from "../env.ts";
import type { NodeContext } from "./node.ts";
import { CONTEXT_EDIT_ENTRY, CUSTOM_ENTRY, CUSTOM_MESSAGE_ENTRY, type Histories, messageOf, type SessionEntry } from "./session.ts";
import { getKeybindings } from "@earendil-works/pi-tui";
import { type AppDefinition, type AppHandle, appKey, openApp, releaseApps, runningApp } from "./apps.ts";
import { htmlPanel } from "./panels.ts";
import { componentTheme } from "./components.ts";
import { piTuiModule, showComponent } from "./tui.ts";
import { ask, type Dialog, footerData, notify, setEditorText, setStatus, setWidget } from "./ui.ts";

/** What extensions reach of the engine. */
export type Host = {
	readonly harness: () => Harness;
	readonly models: () => piAi.Models;
	readonly histories: Histories;
	/** A conversation's workspace and environment. */
	env(conversationId: number): NodeContext;
	sessionName(conversationId: number): Promise<string | undefined>;
	setSessionName(conversationId: number, name: string): Promise<void>;
	setModel(conversationId: number, provider: string, modelId: string): Promise<void>;
	setThinkingLevel(conversationId: number, level: string): Promise<void>;
	/** A prompt an extension submitted, so the app follows it like the user's own. */
	submitted(conversationId: number, submission: Submission): void;
	/** Why a conversation's instances start: a fork of another session, or the app starting. */
	startReason(conversationId: number): { reason: "startup" | "fork"; previousSessionFile?: string };
	/** Delivers an event to every extension of a session (such as `ui_prompt_start`). */
	broadcast(conversationId: number, event: { type: string; [key: string]: unknown }): Promise<void>;
	/** Forks a session at an entry, as "Fork from Here" does; undefined when an extension cancels. */
	fork(conversationId: number, entryId: number): Promise<number | undefined>;
};

/** A loaded extension, as the manager keeps it. */
/**
 * A background check (`pi.registerCheck`, iOS): code that runs when iOS wakes pi, about every `every` minutes at the
 * soonest (iOS decides when), for a few seconds, without a session or the model; it can `pi.notify()`. What `run`
 * returns (a short text) shows in Settings as its last result.
 */
export type CheckDefinition = {
	name: string;
	description?: string;
	every: number;
	run: (context: { signal: AbortSignal }) => unknown;
};

export interface Adapted {
	readonly extension: Extension;
	readonly tools: string[];
	/** The background checks it registered where no session is involved (a default's first instance). */
	readonly checks: CheckDefinition[];
	readonly notes: string[];
	/**
	 * Before a prompt is submitted: `input` handlers may rewrite or take it; `before_agent_start` handlers may add
	 * messages before it and replace the run's system prompt.
	 */
	prompt(conversationId: number, prompt: Prompt): Promise<Prompt>;
	/** Delivers an event to a conversation's instance, if it has one. */
	notify(conversationId: number, event: { type: string; [key: string]: unknown }): Promise<void>;
	/** The conversation's agent events (streaming, message, and compaction events come from them). */
	observe(conversationId: number, events: readonly AgentEvent[]): Promise<void>;
	/** A `!command` the user runs: an extension may run it (`operations`) or answer it (`result`). */
	userBash(conversationId: number, command: string, excludeFromContext: boolean): Promise<UserBash | undefined>;
	/** Before the session is forked at an entry: true when an extension cancels the fork. */
	beforeFork(conversationId: number, entryId: number): Promise<boolean>;
	/** The slash commands this extension registered in a session. */
	commands(conversationId: number): Promise<{ name: string; description?: string }[]>;
	/** Runs a slash command in a session; false when this extension has no such command. */
	runCommand(conversationId: number, name: string, args: string, signal?: AbortSignal): Promise<boolean>;
	/** The apps this extension registered in a session (`pi.registerApp`). */
	apps(conversationId: number): Promise<AppDefinition[]>;
	/** The apps it registers, as its first instance did (for sharing it). */
	readonly offeredApps: { name: string; title: string; icon: string | null }[];
	/** Opens one of them in the session (or shows it, running); undefined when it has no such app. */
	openApp(conversationId: number, name: string, options?: { visible?: boolean }): Promise<AppHandle | undefined>;
	/** `session_shutdown` for one conversation's instance, or every instance, which are then dropped. */
	shutdown(reason: "quit" | "reload", conversationId?: number): Promise<void>;
}

export type CustomMessage = { customType: string; content: UserInput; display?: boolean; details?: unknown };
export type Prompt = { text: string; handled: boolean; messages: CustomMessage[]; systemPrompt: string; replacedSystemPrompt?: string };
export type BashResult = { output: string; exitCode: number | undefined; cancelled: boolean; truncated: boolean };
export type BashOperations = {
	exec(command: string, cwd: string, options: { onData: (data: unknown) => void; signal?: AbortSignal; timeout?: number }): Promise<{ exitCode: number | null }>;
};
export type UserBash = { result?: BashResult; operations?: BashOperations };

type Content = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
type PiTool = {
	name: string;
	label?: string;
	description?: string;
	parameters?: unknown;
	execute: (toolCallId: string, params: unknown, signal: AbortSignal | undefined, onUpdate: (partial: unknown) => void, ctx: unknown) => unknown;
};
// biome-ignore lint/suspicious/noExplicitAny: handlers receive pi's event objects
type Handler = (event: any, ctx: unknown) => unknown;
type PiCommand = { description?: string; handler: (args: string, ctx: unknown) => unknown };

/** The events delivered here; the notes list the others an extension listens to. */
const DELIVERED = new Set([
	"session_start",
	"session_shutdown",
	"session_compact",
	"session_before_compact",
	"session_info_changed",
	"model_select",
	"input",
	"before_agent_start",
	"agent_start",
	"agent_end",
	"agent_settled",
	"turn_start",
	"turn_end",
	"message_start",
	"message_update",
	"message_end",
	"agent_before_settle",
	"session_compact_failed",
	"session_before_fork",
	"user_bash",
	"before_provider_request",
	"before_provider_headers",
	"after_provider_response",
	"provider_stream_event",
	"tool_execution_update",
	"ui_prompt_start",
	"ui_prompt_end",
	"context",
	"context_with_system",
	"tool_call",
	"tool_execution_start",
	"tool_result",
	"tool_execution_end",
]);

/**
 * pi's packages as extension code imports them (pi-coding-agent declares them as peers): the engine's own pi-ai and
 * TypeBox, pi-coding-agent as `coding-agent.ts` provides it, and pi-tui's components as empty classes.
 */
export function hostModules(codingAgent: Record<string, unknown>): Record<string, unknown> {
	const esm = (exports: Record<string, unknown>) => ({ __esModule: true, ...exports, default: exports.default ?? exports });
	const ai = esm({ ...piAi });
	const typebox = esm({ ...typeboxModule });
	const agent = esm({ ...codingAgent, Type });
	const tui = esm({ ...piTuiModule });
	const modules: Record<string, unknown> = {};
	// pi-ai's entry points besides its root: the older global API (`compat`: `stream`, `complete`, the catalog), the
	// models module, and the built-in provider catalog.
	const aiPaths: Record<string, Record<string, unknown>> = { compat: piAiCompat, models: piAiModels, "providers/all": piAiProviders };
	for (const scope of ["@earendil-works", "@mariozechner"]) {
		modules[`${scope}/pi-ai`] = ai;
		for (const [path, exports] of Object.entries(aiPaths)) modules[`${scope}/pi-ai/${path}`] = esm({ ...exports });
		modules[`${scope}/pi-coding-agent`] = agent;
		modules[`${scope}/pi-agent-core`] = esm({});
		modules[`${scope}/pi-tui`] = tui;
	}
	// TypeBox, with its subpaths, is pi-ai's (1.x); extensions written for older pi import it as @sinclair/typebox.
	const typeboxPaths: Record<string, Record<string, unknown>> = {
		compile: typeboxCompile,
		error: typeboxError,
		format: typeboxFormat,
		guard: typeboxGuard,
		schema: typeboxSchema,
		system: typeboxSystem,
		type: typeboxType,
		value: typeboxValue,
	};
	for (const name of ["typebox", "@sinclair/typebox"]) {
		modules[name] = typebox;
		for (const [path, exports] of Object.entries(typeboxPaths)) modules[`${name}/${path}`] = esm({ ...exports });
	}
	return modules;
}

/**
 * Turns loaded modules' exports into one pi-durable extension named `name`. `sessionId` binds a session's own
 * extension to that session; a default one gets an instance per conversation.
 */
export async function adapt(name: string, modules: unknown[], host: Host, sessionId?: number): Promise<Adapted> {
	const factories: ((pi: unknown) => unknown)[] = [];
	const durable: Extension[] = [];
	for (const exported of modules) {
		const value = (exported as { default?: unknown } | undefined)?.default ?? exported;
		if (isDurableExtension(value)) durable.push(value);
		else if (typeof value === "function") factories.push(value as (pi: unknown) => unknown);
		else throw new Error(`${name}: the module's default export is not an extension (a function that receives pi, or a pi-durable extension)`);
	}
	if (factories.length === 0) return durableAdapted(name, durable);
	if (durable.length > 0) throw new Error(`${name}: mixes pi extensions and pi-durable extensions`);
	return PiExtension.create(name, factories, host, sessionId);
}

function durableAdapted(name: string, extensions: Extension[]): Adapted {
	const extension = defineExtension({
		name,
		tools: extensions.flatMap((each) => each.tools ?? []),
		sections: extensions.flatMap((each) => each.sections ?? []),
		hooks: extensions.flatMap((each) => each.hooks ?? []),
		wraps: extensions.flatMap((each) => each.wraps ?? []),
		tasks: extensions.flatMap((each) => each.tasks ?? []),
	});
	return {
		extension,
		tools: (extension.tools ?? []).map((tool) => tool.name),
		notes: [],
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
		checks: [],
		shutdown: async () => {},
	};
}

/** One conversation's instance of an extension: what its functions registered through their `pi`. */
class Instance {
	readonly tools = new Map<string, PiTool>();
	readonly commands = new Map<string, PiCommand>();
	/** Apps it registered (`pi.registerApp`), by name. */
	readonly apps = new Map<string, AppDefinition>();
	/** Background checks it registered (`pi.registerCheck`), by name. */
	readonly checks = new Map<string, CheckDefinition>();
	/** Component widgets on screen, by key. */
	readonly widgets = new Map<string, { close(): void }>();
	readonly handlers = new Map<string, Handler[]>();
	/** While `agent_end` handlers run, a message they send continues the run (the first one). */
	yielding = false;
	continuation: UserInput | undefined;
	turnIndex = 0;
	/** The newest history entry this instance has seen, for `session_compact`. */
	seen = 0;
	/** From the agent events: the assistant message being streamed, and the running tools' arguments and output. */
	partial: { content: Record<string, unknown>[]; [key: string]: unknown } | undefined;
	readonly running = new Map<string, { args: unknown; output: string }>();
	// What `ctx` reports synchronously, read before each call.
	model: piAi.Model<piAi.Api> | undefined;
	thinkingLevel = "off";
	sessionName: string | undefined;

	constructor(readonly conversationId: number | undefined) {}

	has(type: string): boolean {
		return (this.handlers.get(type)?.length ?? 0) > 0;
	}
}

type CallOptions = {
	signal?: AbortSignal;
	cwd?: string;
	idle?: boolean;
	/** Sees each handler's result; returning true skips the remaining handlers. */
	each?: (result: never) => boolean | void;
	/** Lets a handler's error through instead of logging it. */
	rethrow?: boolean;
};

class PiExtension implements Adapted {
	extension!: Extension;
	private template!: Instance;
	private readonly instances = new Map<number, Promise<Instance>>();
	/** Events any instance listens to. */
	private readonly registered = new Set<string>();
	/** The commands any instance registered. */
	private readonly commandNames = new Set<string>();
	/** The apps any instance registered. */
	private readonly appNames = new Set<string>();
	private readonly unsupported = new Set<string>();

	private constructor(
		readonly name: string,
		private readonly factories: ((pi: unknown) => unknown)[],
		private readonly host: Host,
	) {}

	static async create(name: string, factories: ((pi: unknown) => unknown)[], host: Host, sessionId?: number): Promise<PiExtension> {
		const extension = new PiExtension(name, factories, host);
		// The tools' definitions come from a first instance: the session's own, or, for a default, one that serves no
		// conversation.
		extension.template = await extension.instantiate(sessionId);
		if (sessionId !== undefined) extension.instances.set(sessionId, Promise.resolve(extension.template));
		extension.extension = defineExtension({
			name,
			tools: [...extension.template.tools.values()].map((tool) => extension.durableTool(tool)),
			hooks: extension.hooks(),
		});
		return extension;
	}

	get tools(): string[] {
		return [...this.template.tools.keys()];
	}

	get checks(): CheckDefinition[] {
		return [...this.template.checks.values()];
	}

	get offeredApps(): { name: string; title: string; icon: string | null }[] {
		return [...this.template.apps.values()].map((app) => ({ name: app.name, title: app.title ?? app.name, icon: app.icon ?? null }));
	}

	get notes(): string[] {
		const notes: string[] = [];
		const undelivered = [...this.registered].filter((event) => !DELIVERED.has(event));
		if (undelivered.length > 0) notes.push(`events ${undelivered.join(", ")} are not delivered on iOS`);
		if (this.unsupported.size > 0) notes.push(`${[...this.unsupported].join(", ")} have no counterpart on iOS yet`);
		return notes;
	}

	// ---- instances ----

	private instance(conversationId: number): Promise<Instance> {
		let instance = this.instances.get(conversationId);
		if (!instance) {
			instance = this.instantiate(conversationId);
			instance.catch(() => this.instances.delete(conversationId));
			this.instances.set(conversationId, instance);
		}
		return instance;
	}

	private async instantiate(conversationId: number | undefined): Promise<Instance> {
		const instance = new Instance(conversationId);
		for (const factory of this.factories) await factory(this.api(instance));
		if (conversationId === undefined) return instance;
		// Compactions already in the history are part of what session_start finds, not news.
		await this.host.histories.refresh(conversationId);
		instance.seen = Number(this.host.histories.entries(conversationId).at(-1)?.id ?? 0);
		await this.prepare(instance);
		await this.call(instance, "session_start", { type: "session_start", ...this.host.startReason(conversationId) });
		return instance;
	}

	/** Brings what `ctx` reads up to date, and tells the instance about compactions placed since it last looked. */
	private async prepare(instance: Instance): Promise<void> {
		const conversationId = instance.conversationId;
		if (conversationId === undefined) return;
		const { histories } = this.host;
		await histories.refresh(conversationId);
		const conversation = await this.conversation(conversationId);
		const agent = await conversation?.agent(BACKGROUND_CONTEXT);
		instance.model = agent?.model ? this.host.models().getModel(agent.model.provider, agent.model.modelId) : undefined;
		instance.thinkingLevel = agent?.thinkingLevel ?? "off";
		instance.sessionName = await this.host.sessionName(conversationId);
		const entries = histories.entries(conversationId);
		const compactions: SessionEntry[] = [];
		for (let index = entries.length - 1; index >= 0 && Number(entries[index]!.id) > instance.seen; index--) {
			if (entries[index]!.type === "compaction") compactions.unshift(entries[index]!);
		}
		instance.seen = Number(entries.at(-1)?.id ?? instance.seen);
		for (const compactionEntry of compactions) {
			await this.call(instance, "session_compact", { type: "session_compact", compactionEntry, fromExtension: false, reason: "threshold", willRetry: false });
		}
	}

	/** Calls an instance's handlers for an event in order, as pi does: a failing handler is reported and skipped. */
	private async call(instance: Instance, type: string, event: object, options: CallOptions = {}): Promise<void> {
		const handlers = instance.handlers.get(type);
		if (!handlers || handlers.length === 0) return;
		const ctx = this.context(instance, options);
		for (const handler of [...handlers]) {
			let result: unknown;
			try {
				result = await handler(event, ctx);
			} catch (error) {
				if (options.rethrow) throw error;
				console.warn(`[${this.name}] ${type}: ${message(error)}`);
				continue;
			}
			if (result !== undefined && result !== null && options.each?.(result as never) === true) return;
		}
	}

	/** The conversation's instance, up to date, when it listens to any of `types`. */
	private async listening(conversationId: number, ...types: string[]): Promise<Instance | undefined> {
		if (!types.some((type) => this.registered.has(type))) return undefined;
		const instance = await this.instance(conversationId);
		if (!types.some((type) => instance.has(type))) return undefined;
		await this.prepare(instance);
		return instance;
	}

	private conversation(conversationId: number): Promise<Conversation | undefined> {
		return this.host.harness().conversation(conversationId as ConversationId, BACKGROUND_CONTEXT);
	}

	private env(instance: Instance): NodeContext {
		return this.host.env(instance.conversationId ?? -1);
	}

	// ---- pi's API ----

	private api(instance: Instance) {
		const conversationId = instance.conversationId;
		const missing = (what: string) => () => {
			this.unsupported.add(what);
		};
		const submit = (draft: SubmissionDraft) => {
			if (conversationId === undefined) return;
			void this.submit(conversationId, draft);
		};
		const whenBusy = (deliverAs: string | undefined) => (deliverAs === "steer" ? "steer" : "followUp");
		return {
			on: (event: string, handler: Handler) => {
				this.registered.add(event);
				const handlers = instance.handlers.get(event) ?? [];
				handlers.push(handler);
				instance.handlers.set(event, handlers);
				return () => {
					const index = handlers.indexOf(handler);
					if (index >= 0) handlers.splice(index, 1);
				};
			},
			registerTool: (tool: PiTool) => {
				instance.tools.set(tool.name, tool);
			},
			registerCommand: (command: string, options: PiCommand) => {
				this.commandNames.add(command);
				instance.commands.set(command, options);
			},
			// pi on iOS: an app the session keeps (`apps.ts`).
			registerApp: (definition: AppDefinition) => {
				if (!definition || typeof definition.name !== "string" || !definition.name || typeof definition.render !== "function") {
					throw new Error("registerApp needs a name and a render function");
				}
				this.appNames.add(definition.name);
				instance.apps.set(definition.name, definition);
			},
			// pi on iOS: code iOS runs now and then in the background (CheckDefinition).
			registerCheck: (definition: CheckDefinition) => {
				if (!definition || typeof definition.name !== "string" || !definition.name || typeof definition.run !== "function") {
					throw new Error("registerCheck needs a name and a run function");
				}
				const every = Math.max(15, Math.round(Number(definition.every) || 60));
				instance.checks.set(definition.name, { ...definition, every });
			},
			apps: this.appsApi(instance),
			registerShortcut: () => {},
			registerFlag: () => {},
			getFlag: () => undefined,
			registerProvider: missing("registerProvider"),
			unregisterProvider: () => {},
			registerMcpServer: missing("registerMcpServer"),
			registerVirtualModel: missing("registerVirtualModel"),
			registerMessageRenderer: () => {},
			registerMarkdownTransformer: () => {},
			registerEntryRenderer: () => {},
			registerToolRenderer: () => {},
			sendMessage: (custom: CustomMessage, options: { triggerTurn?: boolean; deliverAs?: string } = {}) => {
				if (instance.yielding && (options.triggerTurn || options.deliverAs === "followUp")) {
					instance.continuation ??= custom.content;
				} else if (options.triggerTurn) {
					submit({ type: "input", content: custom.content, whenBusy: whenBusy(options.deliverAs) });
				} else {
					submit({ type: "write", entry: customMessageEntry(custom) });
				}
			},
			sendUserMessage: (content: UserInput, options: { deliverAs?: string } = {}) => {
				if (instance.yielding && options.deliverAs !== "steer") instance.continuation ??= content;
				else submit({ type: "input", content, whenBusy: whenBusy(options.deliverAs) });
			},
			appendEntry: (customType: string, data?: unknown) => {
				submit({ type: "write", entry: { kind: CUSTOM_ENTRY, data: json({ customType, data: data ?? null }) } });
			},
			setSessionName: (name: string) => {
				instance.sessionName = name;
				if (conversationId !== undefined) void this.host.setSessionName(conversationId, name).catch(logError(this.name));
			},
			getSessionName: () => instance.sessionName,
			setLabel: () => {},
			// options.signal: an abort (the user's Stop, passed on) ends the command.
			exec: (command: string, args: string[] = [], options: { cwd?: string; timeout?: number; signal?: AbortSignal } = {}) => {
				const env = this.env(instance);
				const withSecrets = { ...env, env: { ...env.env, ...secretEnv(extensionOf(this.name)) } };
				return runCommand([command, ...args].map(quote).join(" "), options.cwd ?? env.cwd, withSecrets, options.timeout, options.signal);
			},
			// iOS: the Keychain-backed secrets this extension may read, and its own (secrets.ts).
			secrets: secretsApi(extensionOf(this.name)),
			keys: keysApi(extensionOf(this.name)),
			// iOS: the user's vault (vault.ts).
			vault: vaultApi(extensionOf(this.name), conversationId),
			// iOS: values that follow the user to their other devices (synced.ts).
			synced: syncedApi(extensionOf(this.name)),
			// iOS: the device's location, and notifications, once the user allows this extension (device.ts).
			location: locationApi(extensionOf(this.name)),
			notify: notifyApi(extensionOf(this.name), conversationId),
			// iOS: the user's MCP servers, each once the user allows this extension (mcp.ts).
			mcp: mcpApi(extensionOf(this.name)),
			events: eventBus(conversationId),
			getActiveTools: () => [...instance.tools.keys()],
			getAllTools: () => [...instance.tools.values()].map((tool) => ({ name: tool.name, description: tool.description })),
			getSettings: () => ({}),
			setActiveTools: missing("setActiveTools"),
			getCommands: () => [],
			setModel: async (model: { provider: string; id: string }) => {
				if (conversationId === undefined) return false;
				await this.host.setModel(conversationId, model.provider, model.id);
				return true;
			},
			getThinkingLevel: () => instance.thinkingLevel,
			// The session's, as its model takes it (the app shows it in the session's menu).
			setThinkingLevel: (level: string) => {
				if (conversationId === undefined) return;
				instance.thinkingLevel = level;
				void this.host.setThinkingLevel(conversationId, level).catch(logError(this.name));
			},
		};
	}

	private async submit(conversationId: number, draft: SubmissionDraft): Promise<void> {
		try {
			const conversation = await this.conversation(conversationId);
			if (!conversation) return;
			const submission = await conversation.submit(draft, BACKGROUND_CONTEXT);
			// A prompt is followed like the user's own (its run's end settles it); a written entry is not a run.
			if (draft.type === "input") this.host.submitted(conversationId, submission);
		} catch (error) {
			console.warn(`[${this.name}] ${draft.type}: ${message(error)}`);
		}
	}

	/** pi's `ExtensionContext` for an instance. */
	private context(instance: Instance, options: CallOptions) {
		const conversationId = instance.conversationId;
		const cwd = options.cwd ?? this.env(instance).cwd;
		const models = this.host.models();
		const withConversation = (run: (conversation: Conversation) => Promise<unknown>) => {
			if (conversationId === undefined) return;
			void this.conversation(conversationId)
				.then((conversation) => conversation && run(conversation))
				.catch(logError(this.name));
		};
		return {
			cwd,
			hasUI: conversationId !== undefined,
			mode: "rpc",
			signal: options.signal,
			ui: this.ui(instance),
			secrets: secretsApi(extensionOf(this.name)),
			keys: keysApi(extensionOf(this.name)),
			vault: vaultApi(extensionOf(this.name), conversationId),
			synced: syncedApi(extensionOf(this.name)),
			location: locationApi(extensionOf(this.name)),
			notify: notifyApi(extensionOf(this.name), conversationId),
			mcp: mcpApi(extensionOf(this.name)),
			sessionManager:
				conversationId === undefined
					? { getEntries: () => [], getBranch: () => [], getCwd: () => cwd, getSessionId: () => "", getSessionFile: () => undefined, getLeafId: () => null }
					: this.host.histories.manager(conversationId, cwd, () => instance.sessionName),
			modelRegistry: modelRegistry(models, (what) => this.unsupported.add(what)),
			model: instance.model,
			scopedModels: [],
			thinkingLevel: instance.thinkingLevel,
			isIdle: () => options.idle === true,
			isProjectTrusted: () => true,
			abort: () => withConversation((conversation) => conversation.abort(BACKGROUND_CONTEXT)),
			hasPendingMessages: () => false,
			shutdown: () => {},
			getContextUsage: () => undefined,
			compact: (compaction?: { customInstructions?: string }) =>
				withConversation((conversation) => conversation.compact(compaction?.customInstructions, BACKGROUND_CONTEXT)),
			getSystemPrompt: () => (conversationId === undefined ? "" : this.host.histories.systemPrompt(conversationId)),
		};
	}

	/**
	 * pi's `ctx.ui` on the app's screen: dialogs the user answers (each between `ui_prompt_start` and `ui_prompt_end`
	 * for the session's extensions), notifications, status lines, text widgets, and the input text. Components (custom
	 * dialogs, component widgets, footers, headers) and HTML pages show in panels (`tui.ts`, `panels.ts`).
	 */
	private ui(instance: Instance) {
		const sessionId = instance.conversationId;
		// The name people know (the record's), not the registry's `session:<id>:` or `default:` one.
		const name = this.name.replace(/^(default|session:\d+):/, "");
		// Component widgets (and footers and headers) by key, each in its own panel above the message box.
		const widgets = instance.widgets;
		const showWidget = (key: string, factory: ((tui: unknown, theme: unknown, ...rest: unknown[]) => never) | undefined, ...rest: unknown[]) => {
			widgets.get(key)?.close();
			widgets.delete(key);
			if (!factory || sessionId === undefined) return;
			widgets.set(key, showComponent(sessionId, name, "widget", undefined, (tui) => factory(tui, componentTheme, ...rest), 100));
		};
		// pi's footer data: the session's statuses (shared by its extensions), git branch, and provider count.
		const footer = () => (sessionId === undefined ? undefined : footerData(sessionId, this.env(instance).cwd, () => configuredProviders.size));
		const dialog = async (request: Dialog, options?: { signal?: AbortSignal; timeout?: number }) => {
			if (sessionId === undefined) return undefined;
			const event = { reason: "ui_prompt", kind: request.kind, title: request.title };
			await this.host.broadcast(sessionId, { type: "ui_prompt_start", ...event });
			try {
				return await ask(sessionId, name, request, options);
			} finally {
				await this.host.broadcast(sessionId, { type: "ui_prompt_end", ...event });
			}
		};
		type DialogOptions = { signal?: AbortSignal; timeout?: number };
		const ui = {
			select: (title: string, options: string[], opts?: DialogOptions) => dialog({ kind: "select", title, options }, opts),
			confirm: async (title: string, message: string, opts?: DialogOptions) => (await dialog({ kind: "confirm", title, message }, opts)) === "yes",
			input: (title: string, placeholder?: string, opts?: DialogOptions) => dialog({ kind: "input", title, placeholder }, opts),
			editor: (title: string, prefill?: string) => dialog({ kind: "editor", title, prefill }),
			notify: (message: string, type: "info" | "warning" | "error" = "info") => {
				if (sessionId === undefined) console.log(`[${name}] ${message}`);
				else notify(sessionId, name, message, type);
			},
			setStatus: (key: string, text: string | undefined) => {
				if (sessionId === undefined) return;
				footer()?.setExtensionStatus(key, text);
				setStatus(sessionId, name, key, text);
			},
			setWidget: (key: string, content: unknown) => {
				if (typeof content === "function") showWidget(`widget:${key}`, content as never);
				else {
					showWidget(`widget:${key}`, undefined);
					if (sessionId !== undefined) setWidget(sessionId, name, key, Array.isArray(content) ? content.map(String) : undefined);
				}
			},
			setWorkingMessage: () => {},
			setWorkingVisible: () => {},
			setWorkingIndicator: () => {},
			setHiddenThinkingLabel: () => {},
			// The app has no terminal footer or header; they show as widgets.
			setFooter: (factory: unknown) => showWidget("footer", factory as never, footer()),
			setHeader: (factory: unknown) => showWidget("header", factory as never),
			setTitle: () => {},
			// A component in a sheet until it calls done (or the user closes it).
			custom: (factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (result: unknown) => void) => never, options?: { onHandle?: (handle: unknown) => void }) => {
				if (sessionId === undefined) return Promise.resolve(undefined);
				const shown = showComponent(sessionId, name, "sheet", undefined, (tui, done) => factory(tui, componentTheme, getKeybindings(), done));
				options?.onHandle?.({ hide: () => {}, show: () => {}, focus: () => {}, setHidden: () => {}, isHidden: () => false, close: shown.close });
				return shown.result;
			},
			/**
			 * pi on iOS: an HTML page in a sheet or above the message box, talking to the extension (`panels.ts`). With
			 * `persistent: true`, an app (`apps.ts`) for as long as the engine runs: closing the sheet minimizes it to the
			 * session's dock; `closed` resolves when the user closes it from there.
			 */
			panel: (options: {
				html: string;
				title?: string;
				placement?: "sheet" | "widget";
				onMessage?: (data: unknown) => void;
				persistent?: boolean;
				icon?: string;
			}) => {
				if (sessionId === undefined) throw new Error("panels need a session");
				if (!options.persistent) return htmlPanel(sessionId, name, options);
				let html = options.html;
				const opening = openApp(
					sessionId,
					name,
					{
						name: `panel:${options.title ?? "panel"}`,
						title: options.title,
						icon: options.icon,
						render: () => html,
						onMessage: (data) => options.onMessage?.(data),
					},
					this.ui(instance),
					{ durable: false },
				);
				opening.catch((error: unknown) => console.warn(`[${name}] panel: ${error instanceof Error ? error.message : String(error)}`));
				return {
					post: (data: unknown) => void opening.then((app) => app.post(data)),
					update: (next: string) => {
						html = next;
						void opening.then((app) => app.refresh());
					},
					minimize: () => void opening.then((app) => app.minimize()),
					show: () => void opening.then((app) => app.show()),
					close: () => void opening.then((app) => app.close()),
					closed: opening.then((app) => app.closed),
				};
			},
			/** pi on iOS: this session's apps (`pi.apps`). */
			apps: this.appsApi(instance),
			pasteToEditor: (text: string) => {
				if (sessionId !== undefined) setEditorText(sessionId, text, true);
			},
			setEditorText: (text: string) => {
				if (sessionId !== undefined) setEditorText(sessionId, text);
			},
			getEditorText: () => "",
			onTerminalInput: () => () => {},
			addAutocompleteProvider: () => {},
			setEditorComponent: () => {},
			getEditorComponent: () => undefined,
			// Colors show in panels; the app's plain text (status lines, text widgets, notifications) drops them.
			theme: componentTheme,
			getAllThemes: () => [],
			getTheme: () => undefined,
			setTheme: () => ({ success: false, error: "themes are not available on iOS" }),
			getToolsExpanded: () => false,
			setToolsExpanded: () => {},
		};
		return ui;
	}

	/**
	 * `pi.apps` (and `ctx.ui.apps`) in a session: opens its apps (`open(name)`, shown unless `{ visible: false }`), and
	 * finds a running one (`get(name)`) to post to, badge, or close.
	 */
	private appsApi(instance: Instance) {
		const sessionId = instance.conversationId;
		const name = extensionOf(this.name);
		return {
			open: async (app: string, options: { visible?: boolean } = {}): Promise<AppHandle> => {
				if (sessionId === undefined) throw new Error("apps need a session");
				const definition = instance.apps.get(app);
				if (!definition) throw new Error(`no app named ${app} (pi.registerApp)`);
				return openApp(sessionId, name, definition, this.ui(instance), options);
			},
			get: (app: string): AppHandle | undefined => (sessionId === undefined ? undefined : runningApp(sessionId, appKey(name, app))),
			list: () => [...instance.apps.values()].map((app) => ({ name: app.name, title: app.title ?? app.name, running: sessionId !== undefined && runningApp(sessionId, appKey(name, app.name)) !== undefined })),
		};
	}

	// ---- apps ----

	async apps(conversationId: number): Promise<AppDefinition[]> {
		if (this.appNames.size === 0) return [];
		return [...(await this.instance(conversationId)).apps.values()];
	}

	async openApp(conversationId: number, app: string, options: { visible?: boolean } = {}): Promise<AppHandle | undefined> {
		if (!this.appNames.has(app)) return undefined;
		const instance = await this.instance(conversationId);
		const definition = instance.apps.get(app);
		if (!definition) return undefined;
		return openApp(conversationId, extensionOf(this.name), definition, this.ui(instance), options);
	}

	// ---- commands ----

	async commands(conversationId: number): Promise<{ name: string; description?: string }[]> {
		if (this.commandNames.size === 0) return [];
		const instance = await this.instance(conversationId);
		return [...instance.commands].map(([name, command]) => ({ name, description: command.description }));
	}

	async runCommand(conversationId: number, name: string, args: string, signal?: AbortSignal): Promise<boolean> {
		if (!this.commandNames.has(name)) return false;
		const instance = await this.instance(conversationId);
		const command = instance.commands.get(name);
		if (!command) return false;
		await this.prepare(instance);
		const missing = (what: string) => this.unsupported.add(what);
		// pi's `ExtensionCommandContext`: the context plus session operations.
		// ctx.signal: aborted when the user stops the command (Stop).
		const ctx = {
			...this.context(instance, { idle: true, signal }),
			getSystemPromptOptions: () => ({}),
			waitForIdle: async () => (await this.conversation(conversationId))?.waitForIdle(BACKGROUND_CONTEXT),
			fork: async (entryId: string, options?: { withSession?: unknown }) => {
				if (options?.withSession) missing("ctx.fork's withSession");
				return { cancelled: (await this.host.fork(conversationId, Number(entryId))) === undefined };
			},
			newSession: async () => {
				missing("ctx.newSession");
				return { cancelled: true };
			},
			navigateTree: async () => {
				missing("ctx.navigateTree");
				return { cancelled: true };
			},
			switchSession: async () => {
				missing("ctx.switchSession");
				return { cancelled: true };
			},
			reload: async () => {},
		};
		// A command that fails says so in the session (its handler's error), instead of ending silently.
		try {
			await command.handler(args, ctx);
		} catch (error) {
			const text = error instanceof Error ? error.message : String(error);
			notify(conversationId, extensionOf(this.name), `/${name} failed: ${text}`, "error");
			console.warn(`[${this.name}] /${name}: ${text}`);
		}
		return true;
	}

	// ---- tools ----

	private durableTool(tool: PiTool): ToolRegistration {
		return defineTool({
			name: tool.name,
			description: tool.description ?? tool.label ?? tool.name,
			parameters: (tool.parameters ?? Type.Object({})) as ReturnType<typeof Type.Object>,
			// Extension code is opaque: an interrupted call is reported, not repeated.
			replay: "unsafe",
			execute: async (args, api, context) => {
				const instance = await this.instance(Number(api.conversationId));
				await this.prepare(instance);
				const own = instance.tools.get(tool.name) ?? tool;
				const cwd = (api.env as { cwd?: string } | undefined)?.cwd;
				const ctx = this.context(instance, { signal: context.abortSignal, cwd });
				const result = (await own.execute(api.callId, args, context.abortSignal, () => {}, ctx)) as
					| { content?: unknown; details?: unknown; isError?: boolean }
					| string
					| undefined;
				// A vault value the extension was given never reaches the model through its result.
				if (typeof result === "string") return { content: [{ type: "text", text: redact(result) }] };
				const content = contentOf(result?.content).map((part) => (part.type === "text" ? { ...part, text: redact(part.text) } : part));
				const details = json(result?.details ?? null);
				return { content, details: JSON.parse(redact(JSON.stringify(details))), isError: result?.isError === true };
			},
		});
	}

	// ---- hooks ----

	private hooks() {
		const memoKey = (event: string) => `pimobile:${this.name}:${event}`;
		const conversationOf = (api: HookApi) => Number(api.conversationId);

		const tools = hook(ToolTask, {
			beforeTool: async (call, api, context) => {
				const instance = await this.listening(conversationOf(api), "tool_call", "tool_execution_start");
				if (!instance) return undefined;
				type Decision = { block?: string; arguments?: JsonObject };
				let decision = await api.memo<Decision>(memoKey("tool_call"), context);
				const input = structuredClone(decision?.arguments ?? call.arguments) as JsonObject;
				if (!decision) {
					decision = {};
					// Handlers may change `input` in place; the first block wins, and a throw blocks.
					const event = { type: "tool_call", toolCallId: call.id, toolName: call.name, input };
					try {
						await this.call(instance, "tool_call", event, {
							rethrow: true,
							each: (result: { block?: boolean; reason?: string }) => {
								if (!result.block) return false;
								decision = { block: result.reason ?? `Blocked by the ${this.name} extension.` };
								return true;
							},
						});
					} catch (error) {
						decision = { block: `The ${this.name} extension failed: ${message(error)}` };
					}
					if (!decision.block && JSON.stringify(input) !== JSON.stringify(call.arguments)) decision = { arguments: input };
					decision = await api.memo<Decision>(memoKey("tool_call"), decision, context);
				}
				if (!decision.block) {
					await this.call(instance, "tool_execution_start", { type: "tool_execution_start", toolCallId: call.id, toolName: call.name, args: input });
				}
				return decision.block || decision.arguments ? decision : undefined;
			},
			afterTool: async (call, result, api) => {
				const instance = await this.listening(conversationOf(api), "tool_result", "tool_execution_end");
				if (!instance) return undefined;
				// Later handlers see earlier changes.
				const event = {
					type: "tool_result",
					toolCallId: call.id,
					toolName: call.name,
					input: call.arguments,
					content: result.content ?? [],
					details: result.details as unknown,
					isError: result.isError === true,
				};
				let changed = false;
				await this.call(instance, "tool_result", event, {
					each: (change: { content?: Content[]; details?: unknown; isError?: boolean }) => {
						if (change.content !== undefined) event.content = change.content;
						if (change.details !== undefined) event.details = change.details;
						if (change.isError !== undefined) event.isError = change.isError;
						changed ||= change.content !== undefined || change.details !== undefined || change.isError !== undefined;
					},
				});
				const final = changed ? { ...result, content: contentOf(event.content), details: json(event.details ?? null), isError: event.isError } : result;
				await this.call(instance, "tool_execution_end", {
					type: "tool_execution_end",
					toolCallId: call.id,
					toolName: call.name,
					result: { content: final.content ?? [], details: final.details },
					isError: final.isError === true,
				});
				return changed ? final : undefined;
			},
		});

		const generation = hook(GenerationTask, {
			beforeRequest: async (request, api, context) => {
				const conversationId = conversationOf(api);
				const instance = await this.listening(conversationId, "agent_start", "turn_start", "context", "context_with_system", ...PROVIDER_EVENTS);
				if (!instance) return undefined;
				// Once per turn (a generation task), however many attempts it makes.
				if ((await api.memo<boolean>(memoKey("turn"), context)) !== true) {
					await api.memo(memoKey("turn"), true, context);
					const last = [...request.messages].reverse().find((each) => role(each) !== "system");
					if (role(last) === "user") {
						instance.turnIndex = 0;
						await this.call(instance, "agent_start", { type: "agent_start" });
					} else {
						instance.turnIndex++;
					}
					await this.call(instance, "turn_start", { type: "turn_start", turnIndex: instance.turnIndex, timestamp: Date.now() });
				}
				// The provider events of this request: its headers now (they are fixed before the request starts), the
				// rest from the request itself (`wrapModels`).
				if (PROVIDER_EVENTS.some((type) => instance.has(type))) {
					const provider = await api.snapshot(ProviderDoc, api.conversationId, context);
					if (provider) providerSessions.set(provider.sessionId, conversationId);
					const pending = nextRequests.get(conversationId) ?? { extensions: [], headers: {} };
					nextRequests.set(conversationId, pending);
					pending.extensions.push(this);
					// Handlers change `headers` in place; null removes a header.
					await this.call(instance, "before_provider_headers", { type: "before_provider_headers", headers: pending.headers });
				}
				if (!instance.has("context") && !instance.has("context_with_system")) return undefined;
				// `context` sees the conversation without system messages, which stay where they were.
				let messages = request.messages.filter((each) => role(each) !== "system") as Message[];
				let changed = false;
				await this.call(instance, "context", { type: "context", messages: structuredClone(messages) }, {
					each: (result: { messages?: Message[] }) => {
						if (result.messages) {
							messages = result.messages;
							changed = true;
						}
					},
				});
				let full = changed ? withSystemMessages(request.messages, messages) : [...request.messages];
				await this.call(instance, "context_with_system", { type: "context_with_system", messages: structuredClone(full) }, {
					each: (result: { messages?: Message[] }) => {
						if (result.messages) {
							full = result.messages;
							changed = true;
						}
					},
				});
				// Handlers return pi's messages (custom messages, bash runs, summaries); the request gets them as the model's,
				// as pi converts them after its handlers.
				return changed ? { messages: convertToLlm(full as never) as unknown as Message[] } : undefined;
			},
			afterTools: async (assistant, results, api) => {
				const conversationId = conversationOf(api);
				const instance = await this.listening(conversationId, "turn_end");
				if (!instance) return;
				const messageOf = (id: number) => this.host.histories.entry(conversationId, id)?.message;
				const entries: BoundaryDraft[] = [];
				await this.call(instance, "turn_end", turnEnd(instance.turnIndex, messageOf(assistant), results.map(messageOf), String(assistant), results.map(String)), {
					each: (result: BoundaryResult) => {
						entries.push(...(result.entries ?? []));
					},
				});
				// Placed at the boundary after this tool round, as pi places them.
				await this.writeEntries(conversationId, entries, `${memoKey("turn_end")}:${api.taskId}`);
			},
			onYield: async (answer, api, context) => {
				const conversationId = conversationOf(api);
				const instance = await this.listening(conversationId, "turn_end", "agent_end", "agent_before_settle", "agent_settled");
				if (!instance) return undefined;
				type Decision = { continue?: JsonValue };
				let decision = await api.memo<Decision>(memoKey("agent_end"), context);
				if (!decision) {
					// The final turn's `turn_end` and `agent_before_settle` may add entries and ask for another request;
					// a message sent from `agent_end` continues the run too.
					const entries: BoundaryDraft[] = [];
					let more = false;
					const boundary = (result: BoundaryResult) => {
						entries.push(...(result.entries ?? []));
						more ||= result.continue === true;
					};
					await this.call(instance, "turn_end", turnEnd(instance.turnIndex, answer, [], "", []), { each: boundary });
					instance.yielding = true;
					instance.continuation = undefined;
					try {
						await this.call(instance, "agent_end", { type: "agent_end", messages: runMessages(this.host.histories.entries(conversationId), answer) });
					} finally {
						instance.yielding = false;
					}
					await this.call(instance, "agent_before_settle", { ...boundaryState(entries, more), type: "agent_before_settle" }, { each: boundary });
					let next: UserInput | undefined = instance.continuation;
					instance.continuation = undefined;
					if (next === undefined && more) {
						// pi continues with the context as it is; pi-durable continues with a user message, so the
						// added messages become it.
						const messages = entries.filter((entry) => entry.type === "custom_message");
						next = messages.length > 0 ? (messages.flatMap((entry) => contentOf(entry.content)) as UserInput) : "Continue.";
						entries.splice(0, entries.length, ...entries.filter((entry) => entry.type !== "custom_message"));
					}
					await this.writeEntries(conversationId, entries, `${memoKey("agent_end")}:${api.taskId}`);
					decision = await api.memo<Decision>(memoKey("agent_end"), next === undefined ? {} : { continue: json(next) }, context);
					if (decision.continue === undefined) await this.call(instance, "agent_settled", { type: "agent_settled" }, { idle: true });
				}
				return decision.continue === undefined ? undefined : { continue: decision.continue as UserInput };
			},
		});

		const compaction = hook(CompactionTask, {
			beforeCompact: async (request, api, context) => {
				const conversationId = conversationOf(api);
				const instance = await this.listening(conversationId, "session_before_compact");
				if (!instance) return undefined;
				type Decision = { decline?: true; summary?: string };
				let decision = await api.memo<Decision>(memoKey("compact"), context);
				if (!decision) {
					decision = {};
					const tokens = Math.round(JSON.stringify(request.messages).length / 4);
					const event = {
						type: "session_before_compact",
						preparation: {
							firstKeptEntryId: String(request.firstKept),
							messagesToSummarize: request.messages,
							turnPrefixMessages: [],
							isSplitTurn: false,
							tokensBefore: tokens,
							fileOps: { read: new Set(), written: new Set(), edited: new Set() },
							settings: {},
						},
						branchEntries: [...this.host.histories.entries(conversationId)],
						customInstructions: request.instructions,
						reason: request.reason,
						willRetry: request.reason === "overflow",
						signal: new AbortController().signal,
					};
					await this.call(instance, "session_before_compact", event, {
						each: (result: { cancel?: boolean; compaction?: { summary?: string } }) => {
							if (result.cancel) decision = { decline: true };
							else if (typeof result.compaction?.summary === "string") decision = { summary: result.compaction.summary };
							else return false;
							return true;
						},
					});
					decision = await api.memo<Decision>(memoKey("compact"), decision, context);
				}
				if (decision.decline) return { decline: true as const };
				return decision.summary === undefined ? undefined : { summary: decision.summary };
			},
		});

		return [tools, generation, compaction];
	}

	/** Entries a `turn_end` or `agent_before_settle` handler adds, written once (a repeated hook finds them by request). */
	private async writeEntries(conversationId: number, drafts: BoundaryDraft[], request: string): Promise<void> {
		for (const [index, draft] of drafts.entries()) {
			const entry = this.entryOf(conversationId, draft);
			if (entry) await this.submit(conversationId, { type: "write", entry, requestId: `${request}:${index}` });
			else this.unsupported.add(`${draft.type} entries`);
		}
	}

	private entryOf(conversationId: number, draft: BoundaryDraft): EntryDraft | undefined {
		switch (draft.type) {
			case "custom":
				return { kind: CUSTOM_ENTRY, data: json({ customType: draft.customType, data: draft.data ?? null }) };
			case "custom_message":
				return customMessageEntry({ customType: draft.customType ?? "", content: draft.content as UserInput, display: draft.display, details: draft.details });
			case "context_edit": {
				// Hides an earlier entry from the model, or shows it with other content.
				const target = Number(draft.targetId);
				const original = this.host.histories.entry(conversationId, target)?.message as Record<string, unknown> | undefined;
				if (!Number.isFinite(target)) return undefined;
				const replacement = draft.replacement as { content: unknown } | null;
				if (replacement === null || !original) return { kind: CONTEXT_EDIT_ENTRY, edits: [{ target: target as EntryId, action: "omit" }] };
				const messages = [{ ...original, content: replacement.content }] as unknown as Message[];
				return { kind: CONTEXT_EDIT_ENTRY, edits: [{ target: target as EntryId, action: "replace", messages }] };
			}
			case "compaction": {
				// A summary that starts the model's context, keeping the entries from `firstKeptEntryId` on.
				const text = `The conversation history before this point was compacted into the following summary:\n\n<summary>\n${String(draft.summary)}\n</summary>`;
				const head = draft.firstKeptEntryId === null || draft.firstKeptEntryId === undefined ? "self" : (Number(draft.firstKeptEntryId) as EntryId);
				return { kind: "pi.compaction", model: [{ role: "user", content: text, timestamp: Date.now() }], head, data: { reason: "manual" } };
			}
			default:
				return undefined;
		}
	}

	// ---- provider requests (wrapModels) ----

	async providerRequest(conversationId: number, payload: unknown): Promise<unknown> {
		const instance = await this.instances.get(conversationId);
		let current = payload;
		if (instance) {
			await this.call(instance, "before_provider_request", { type: "before_provider_request", payload }, {
				each: (replaced: unknown) => {
					current = replaced;
				},
			});
		}
		return current;
	}

	async providerResponse(conversationId: number, response: { status: number; headers: Record<string, string> }): Promise<void> {
		const instance = await this.instances.get(conversationId);
		if (instance) await this.call(instance, "after_provider_response", { type: "after_provider_response", ...response });
	}

	async providerStreamEvent(conversationId: number, data: unknown, model: piAi.Model<piAi.Api>): Promise<void> {
		const instance = await this.instances.get(conversationId);
		if (instance) await this.call(instance, "provider_stream_event", { type: "provider_stream_event", provider: model.provider, api: model.api, model: model.id, data });
	}

	// ---- agent events (the conversation's event stream) ----

	async observe(conversationId: number, events: readonly AgentEvent[]): Promise<void> {
		if (!STREAM_EVENTS.some((type) => this.registered.has(type))) return;
		const instance = await this.instance(conversationId);
		for (const event of events) {
			switch (event.type) {
				case "snapshot":
					instance.partial = undefined;
					instance.running.clear();
					break;
				case "message_start":
					// Other messages start with their entry, at message_end.
					if (role(event.message) === "assistant") {
						instance.partial = structuredClone(event.message) as unknown as Instance["partial"];
						await this.call(instance, "message_start", { type: "message_start", message: instance.partial });
					}
					break;
				case "message_update": {
					const partial = instance.partial;
					if (!partial) break;
					for (const change of event.changes) {
						const assistantMessageEvent = applyChange(partial, change);
						if (assistantMessageEvent) await this.call(instance, "message_update", { type: "message_update", message: partial, assistantMessageEvent });
					}
					break;
				}
				case "message_end":
				case "entry_appended": {
					const message = messageOf(event.entry);
					if (!message || role(message) === "system") break;
					const streamed = role(message) === "assistant" && instance.partial !== undefined;
					instance.partial = undefined;
					await this.prepare(instance);
					if (!streamed) await this.call(instance, "message_start", { type: "message_start", message });
					await this.call(instance, "message_end", { type: "message_end", message });
					break;
				}
				case "tool_execution_start":
					instance.running.set(event.toolCallId, { args: event.args, output: "" });
					break;
				case "tool_execution_update": {
					const run = instance.running.get(event.toolCallId) ?? { args: {}, output: "" };
					instance.running.set(event.toolCallId, run);
					if (event.output && "set" in event.output) run.output = event.output.set;
					else if (event.output) run.output = run.output.slice(event.output.trimStart ?? 0) + (event.output.append ?? "");
					await this.call(instance, "tool_execution_update", {
						type: "tool_execution_update",
						toolCallId: event.toolCallId,
						toolName: event.toolName,
						args: run.args,
						partialResult: { content: [{ type: "text", text: run.output }], details: event.details },
					});
					break;
				}
				case "tool_execution_end":
					instance.running.delete(event.toolCallId);
					break;
				case "compaction_end": {
					// A summary that was placed arrives as session_compact (from the history); a failure only here.
					const outcome = (await this.host.harness().getTask(event.taskId, BACKGROUND_CONTEXT))?.state;
					const result = outcome?.status === "terminal" ? outcome.outcome : undefined;
					if (result && result.status !== "completed") {
						await this.call(instance, "session_compact_failed", {
							type: "session_compact_failed",
							reason: event.reason,
							errorMessage: result.status === "failed" ? result.error.message : result.reason,
							aborted: result.status === "aborted",
							willRetry: false,
							fromExtension: false,
						});
					}
					break;
				}
			}
		}
	}

	// ---- events the engine delivers ----

	async prompt(conversationId: number, prompt: Prompt): Promise<Prompt> {
		const instance = await this.listening(conversationId, "input", "before_agent_start");
		if (!instance) return prompt;
		const input = { type: "input", text: prompt.text, source: "interactive" };
		let handled = false;
		await this.call(instance, "input", input, {
			idle: true,
			each: (result: { action?: string; text?: string }) => {
				if (result.action === "handled") {
					handled = true;
					return true;
				}
				if (result.action === "transform" && typeof result.text === "string") input.text = result.text;
			},
		});
		if (handled) return { ...prompt, text: input.text, handled };
		const messages = [...prompt.messages];
		let { systemPrompt, replacedSystemPrompt } = prompt;
		// pi's prompt options, which handlers change in place; later handlers see the prompt earlier ones made.
		const options: PromptOptions = {
			cwd: this.env(instance).cwd,
			selectedTools: [],
			toolSnippets: {},
			toolGuidelines: {},
			promptGuidelines: [],
			appendSystemPrompt: "",
			sections: {},
			contextFiles: [],
			skills: [],
		};
		let base = systemPrompt;
		const event = {
			type: "before_agent_start",
			prompt: input.text,
			get systemPrompt() {
				return withPromptOptions(base, options);
			},
			systemPromptOptions: options,
		};
		await this.call(instance, "before_agent_start", event, {
			idle: true,
			each: (result: { message?: CustomMessage; systemPrompt?: string }) => {
				if (result.message) messages.push(result.message);
				if (typeof result.systemPrompt === "string") base = result.systemPrompt;
			},
		});
		const final = withPromptOptions(base, options);
		if (final !== systemPrompt) systemPrompt = replacedSystemPrompt = final;
		return { text: input.text, handled, messages, systemPrompt, replacedSystemPrompt };
	}

	async userBash(conversationId: number, command: string, excludeFromContext: boolean): Promise<UserBash | undefined> {
		const instance = await this.listening(conversationId, "user_bash");
		if (!instance) return undefined;
		let outcome: UserBash | undefined;
		await this.call(instance, "user_bash", { type: "user_bash", command, excludeFromContext, cwd: this.env(instance).cwd }, {
			idle: true,
			each: (result: UserBash) => {
				if (!result.result && !result.operations) return false;
				outcome = result;
				return true;
			},
		});
		return outcome;
	}

	async beforeFork(conversationId: number, entryId: number): Promise<boolean> {
		const instance = await this.listening(conversationId, "session_before_fork");
		if (!instance) return false;
		let cancelled = false;
		await this.call(instance, "session_before_fork", { type: "session_before_fork", entryId: String(entryId), position: "at" }, {
			idle: true,
			each: (result: { cancel?: boolean }) => {
				cancelled ||= result.cancel === true;
				return cancelled;
			},
		});
		return cancelled;
	}

	async notify(conversationId: number, event: { type: string; [key: string]: unknown }): Promise<void> {
		const instance = await this.instances.get(conversationId)?.catch(() => undefined);
		if (!instance?.has(event.type)) return;
		await this.prepare(instance);
		await this.call(instance, event.type, event);
	}

	async shutdown(reason: "quit" | "reload", conversationId?: number): Promise<void> {
		const ids = conversationId === undefined ? [...this.instances.keys()] : [conversationId];
		for (const id of ids) {
			const instance = await this.instances.get(id)?.catch(() => undefined);
			this.instances.delete(id);
			if (!instance) continue;
			await this.call(instance, "session_shutdown", { type: "session_shutdown", reason });
			for (const widget of instance.widgets.values()) widget.close();
			instance.widgets.clear();
		}
		releaseApps(extensionOf(this.name), conversationId);
	}
}

// ---- provider requests ----

const PROVIDER_EVENTS = ["before_provider_request", "before_provider_headers", "after_provider_response", "provider_stream_event"];
const STREAM_EVENTS = ["message_start", "message_update", "message_end", "tool_execution_update", "session_compact_failed"];

/** Which conversation a provider request is for: pi-durable sends the conversation's `pi.provider` session ID. */
const providerSessions = new Map<string, number>();
/** Per conversation, the extensions that listen to its next request's provider events, and the headers they set. */
const nextRequests = new Map<number, { extensions: PiExtension[]; headers: Record<string, string | null> }>();

/** Clears what extensions set up for a conversation's previous request (the first hook of each request calls it). */
export function startRequest(conversationId: number): void {
	nextRequests.delete(conversationId);
}

/**
 * The models pi-durable requests through, with the provider events pi delivers: `before_provider_request` (replace the
 * payload), `before_provider_headers` (from `beforeRequest`), `after_provider_response`, and `provider_stream_event`.
 */
export function wrapModels<M extends piAi.Models>(models: M): M {
	return new Proxy(models, {
		get(target, property) {
			const value = Reflect.get(target, property, target) as unknown;
			if (property !== "streamSimple" || typeof value !== "function") return typeof value === "function" ? value.bind(target) : value;
			return (model: piAi.Model<piAi.Api>, context: unknown, options: piAi.SimpleStreamOptions = {}) => {
				const conversationId = options.sessionId === undefined ? undefined : providerSessions.get(options.sessionId);
				const pending = conversationId === undefined ? undefined : nextRequests.get(conversationId);
				if (conversationId === undefined || !pending) return value.call(target, model, context, options);
				nextRequests.delete(conversationId);
				return value.call(target, model, context, {
					...options,
					headers: { ...options.headers, ...pending.headers },
					onPayload: async (payload: unknown, requestModel: piAi.Model<piAi.Api>) => {
						let current = (await options.onPayload?.(payload, requestModel)) ?? payload;
						for (const extension of pending.extensions) current = (await extension.providerRequest(conversationId, current)) ?? current;
						return current;
					},
					onResponse: async (response: piAi.ProviderResponse, requestModel: piAi.Model<piAi.Api>) => {
						await options.onResponse?.(response, requestModel);
						for (const extension of pending.extensions) await extension.providerResponse(conversationId, response);
					},
					onProviderStreamEvent: async (data: unknown, requestModel: piAi.Model<piAi.Api>) => {
						await options.onProviderStreamEvent?.(data, requestModel);
						for (const extension of pending.extensions) await extension.providerStreamEvent(conversationId, data, requestModel);
					},
				});
			};
		},
	});
}

// ---- helpers ----

const buses = new Map<number | undefined, EventEmitter>();

/** `pi.events`: shared by the extensions of one conversation, as pi's event bus is by those of one session. */
function eventBus(conversationId: number | undefined): EventEmitter {
	let bus = buses.get(conversationId);
	if (!bus) {
		bus = new EventEmitter();
		buses.set(conversationId, bus);
	}
	return bus;
}

/** A custom message as a model-visible entry (pi shows it to the model as user content). */
export function customMessageEntry(custom: CustomMessage) {
	return {
		kind: CUSTOM_MESSAGE_ENTRY,
		model: [{ role: "user" as const, content: custom.content, timestamp: Date.now() }],
		data: json({ customType: custom.customType, display: custom.display !== false, details: custom.details ?? null }) as JsonObject,
	};
}

/** An entry a `turn_end` or `agent_before_settle` handler adds (pi's `SessionBoundaryDraft`). */
type BoundaryDraft = {
	type: "custom" | "custom_message" | "context_edit" | "compaction";
	customType?: string;
	data?: unknown;
	content?: unknown;
	display?: boolean;
	details?: unknown;
	targetId?: string;
	replacement?: unknown;
	summary?: string;
	firstKeptEntryId?: string | null;
};
type BoundaryResult = { entries?: BoundaryDraft[]; continue?: boolean };

function boundaryState(entries: BoundaryDraft[], more: boolean) {
	return {
		entries: [...entries],
		continue: more,
		context: { contextEntries: [], contextMessages: [], llmMessages: [], pendingMessages: [], canContinue: true },
		outcome: "completed",
	};
}

function turnEnd(turnIndex: number, message: unknown, toolResults: unknown[], messageEntryId: string, toolResultEntryIds: string[]) {
	return { type: "turn_end", turnIndex, message, toolResults, messageEntryId, toolResultEntryIds, ...boundaryState([], false) };
}

/**
 * Applies one change of a streamed assistant message (pi-durable's `MessageChange`) to the partial message, and
 * returns pi's `AssistantMessageEvent` for it.
 */
function applyChange(partial: NonNullable<Instance["partial"]>, change: MessageChange): Record<string, unknown> | undefined {
	const content = partial.content;
	const index = "contentIndex" in change ? change.contentIndex : 0;
	switch (change.type) {
		case "text_start":
		case "thinking_start":
		case "toolcall_start":
			content[index] = structuredClone(change.block) as unknown as Record<string, unknown>;
			return { type: change.type, contentIndex: index, partial };
		case "text_delta":
		case "thinking_delta": {
			const key = change.type === "text_delta" ? "text" : "thinking";
			const block = (content[index] ??= { type: key });
			block[key] = `${block[key] ?? ""}${change.delta}`;
			return { type: change.type, contentIndex: index, delta: change.delta, partial };
		}
		case "toolcall_delta": {
			let target = (content[index] ??= { type: "toolCall" }) as Record<string | number, unknown>;
			for (const key of change.path.slice(0, -1)) target = (target[key] ??= {}) as Record<string | number, unknown>;
			const last = change.path.at(-1);
			if (last !== undefined) target[last] = `${target[last] ?? ""}${change.delta}`;
			return { type: "toolcall_delta", contentIndex: index, delta: change.delta, partial };
		}
		case "block": {
			const block = structuredClone(change.block) as unknown as Record<string, unknown>;
			content[index] = block;
			const kind = block.type === "toolCall" ? "toolcall" : String(block.type);
			return { type: `${kind}_end`, contentIndex: index, ...(kind === "toolcall" ? { toolCall: block } : { content: block[kind] }), partial };
		}
		case "message":
			Object.assign(partial, structuredClone(change.message));
			return undefined;
	}
}

type MessageChange = Extract<AgentEvent, { type: "message_update" }>["changes"][number];

/** The messages of the run that is ending: from its user message on, with the answer. */
function runMessages(entries: readonly SessionEntry[], answer: unknown): unknown[] {
	const messages = entries.filter((entry) => entry.type === "message" && role(entry.message) !== "system").map((entry) => entry.message);
	let start = messages.length;
	while (start > 0 && role(messages[start - 1]) !== "user") start--;
	const run = messages.slice(Math.max(0, start - 1));
	const last = run.at(-1) as { timestamp?: number } | undefined;
	if (last?.timestamp !== (answer as { timestamp?: number }).timestamp) run.push(answer);
	return run;
}

/** Puts system messages back where they were among the others after `context` handlers replaced those. */
function withSystemMessages(original: readonly Message[], replaced: readonly Message[]): Message[] {
	const before = new Map<number, Message[]>();
	let position = 0;
	for (const each of original) {
		if (role(each) === "system") before.set(position, [...(before.get(position) ?? []), each]);
		else position++;
	}
	const result: Message[] = [];
	replaced.forEach((each, index) => result.push(...(before.get(index) ?? []), each));
	for (const [index, messages] of before) if (index >= replaced.length) result.push(...messages);
	return result;
}

function role(value: unknown): string | undefined {
	return (value as { role?: string } | undefined)?.role;
}

function contentOf(value: unknown): Content[] {
	if (typeof value === "string") return [{ type: "text", text: value }];
	if (!Array.isArray(value)) return [];
	return value.flatMap((item): Content[] => {
		if (item?.type === "text") return [{ type: "text", text: String(item.text ?? "") }];
		if (item?.type === "image") return [{ type: "image", data: String(item.data), mimeType: String(item.mimeType ?? "image/png") }];
		return [{ type: "text", text: JSON.stringify(item) }];
	});
}

function json(value: unknown): JsonValue {
	return JSON.parse(JSON.stringify(value ?? null)) as JsonValue;
}

function isDurableExtension(value: unknown): value is Extension {
	return (
		!!value &&
		typeof value === "object" &&
		typeof (value as Extension).name === "string" &&
		["tools", "sections", "hooks", "wraps", "tasks"].some((key) => key in (value as object))
	);
}

function quote(word: string): string {
	return /^[\w@%+=:,./-]+$/.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`;
}

/** pi's `systemPromptOptions` as `before_agent_start` handlers get them (the parts that change this app's prompt). */
type PromptOptions = {
	cwd: string;
	forceSystemPrompt?: string;
	selectedTools: string[];
	toolSnippets: Record<string, string>;
	toolGuidelines: Record<string, string[]>;
	promptGuidelines: string[];
	appendSystemPrompt: string;
	sections: Record<string, string>;
	contextFiles: { path: string; content: string }[];
	skills: unknown[];
};

/**
 * A system prompt with what handlers put in pi's prompt options, rendered as pi renders them: guidelines as rules, the
 * added text, then the named sections, each in a tag of its name. `forceSystemPrompt` replaces the prompt.
 */
function withPromptOptions(systemPrompt: string, options: PromptOptions): string {
	if (typeof options.forceSystemPrompt === "string") return options.forceSystemPrompt;
	const tag = (name: string, content: string) => `<${name}>\n${content}\n</${name}>`;
	const blocks = [systemPrompt];
	const guidelines = (options.promptGuidelines ?? []).map((rule) => rule.trim()).filter(Boolean);
	if (guidelines.length > 0) blocks.push(tag("rules", guidelines.map((rule) => `- ${rule}`).join("\n")));
	if (options.appendSystemPrompt) blocks.push(tag("addendum", options.appendSystemPrompt));
	for (const [name, content] of Object.entries(options.sections ?? {})) if (content) blocks.push(tag(name, content));
	return blocks.filter((block) => block.length > 0).join("\n\n");
}

/** How each provider with credentials (or a custom one, which needs none) signs in, as the app last listed them. */
const configuredProviders = new Map<string, "api_key" | "oauth" | "custom">();

/** Called with each provider list the app gets, so the registry can answer pi's synchronous auth questions. */
export function setConfiguredProviders(providers: Iterable<[string, "api_key" | "oauth" | "custom"]>): void {
	configuredProviders.clear();
	for (const [id, type] of providers) configuredProviders.set(id, type);
}

/**
 * pi's `ModelRegistry` (`ctx.modelRegistry`) over the engine's models: lookups, request auth, and requests through
 * the configured providers. Providers come from the app's settings, so registering one is noted as unsupported.
 */
function modelRegistry(models: piAi.Models, missing: (what: string) => void) {
	type Model = piAi.Model<piAi.Api>;
	const configured = (provider: string) => configuredProviders.has(provider);
	return {
		refresh: (options?: piAi.ModelsRefreshOptions) => models.refresh(options),
		getError: () => undefined,
		getAll: () => models.getModels(),
		getAvailable: () => models.getModels().filter((model) => configured(model.provider)),
		find: (provider: string, id: string) => models.getModel(provider, id),
		findOfType: (type: piAi.ModelType, provider: string, id: string) => models.getModelOfType(type, provider, id),
		hasConfiguredAuth: (model: Model) => configured(model.provider),
		getApiKeyAndHeaders: async (model: Model) => {
			try {
				const result = await models.getAuth(model);
				if (result) return { ok: true, apiKey: result.auth.apiKey, headers: result.auth.headers, baseUrl: result.auth.baseUrl, env: result.env };
				return configured(model.provider) ? { ok: true } : { ok: false, error: `${model.provider} has no credentials; add them in the app's settings` };
			} catch (error) {
				return { ok: false, error: message(error) };
			}
		},
		getProviderAuthStatus: (provider: string) => (configured(provider) ? { configured: true, source: "stored" } : { configured: false }),
		getProvider: (provider: string) => models.getProvider(provider),
		stream: (model: Model, context: piAi.Context, options?: piAi.ModelsApiStreamOptions<piAi.Api>) => models.stream(model, context, options),
		streamSimple: (model: Model, context: piAi.Context, options?: piAi.ModelsSimpleStreamOptions) => models.streamSimple(model, context, options),
		complete: (model: Model, context: piAi.Context, options?: piAi.ModelsApiStreamOptions<piAi.Api>) => models.complete(model, context, options),
		completeSimple: (model: Model, context: piAi.Context, options?: piAi.ModelsSimpleStreamOptions) => models.completeSimple(model, context, options),
		getModelsOfType: (type: piAi.ModelType, provider?: string) => models.getModelsOfType(type, provider),
		getAvailableOfType: (type: piAi.ModelType, provider?: string, options?: piAi.AuthOperationOptions) => models.getAvailableOfType(type, provider, options),
		getModelOfType: (type: piAi.ModelType, provider: string, id: string) => models.getModelOfType(type, provider, id),
		classify: (model: piAi.ClassifierModel<piAi.ClassifierApi>, context: piAi.ClassifierContext, options?: piAi.ModelsClassifierOptions) => models.classify(model, context, options),
		generateImages: (model: piAi.ImageModel<piAi.ImageApi>, context: piAi.ImagesContext, options?: piAi.ModelsImagesOptions) => models.generateImages(model, context, options),
		getProviderDisplayName: (provider: string) => models.getProvider(provider)?.name ?? provider,
		getProviderAuth: (provider: string) => models.getAuth(provider),
		getApiKeyForProvider: async (provider: string) => (await models.getAuth(provider))?.auth.apiKey,
		isUsingOAuth: (model: Model) => configuredProviders.get(model.provider) === "oauth",
		registerProvider: () => missing("modelRegistry.registerProvider"),
		unregisterProvider: () => {},
		registerVirtualModel: () => missing("modelRegistry.registerVirtualModel"),
		unregisterVirtualModel: () => {},
		getRegisteredProviderConfig: () => undefined,
		getRegisteredNativeProvider: () => undefined,
		getRegisteredProviderIds: () => [],
	};
}

function message(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function logError(name: string) {
	return (error: unknown) => console.warn(`[${name}] ${message(error)}`);
}

/** `pi.exec`: runs a command in the session's shell, as pi-coding-agent's exec does (output and exit code). */
async function runCommand(command: string, cwd: string, context: NodeContext, timeout?: number, signal?: AbortSignal) {
	const env = new NativeExecutionEnv({ cwd, home: context.home, environment: context.env });
	let stdout = "";
	const running = signal ? withAbortSignal(signal, BACKGROUND_CONTEXT) : BACKGROUND_CONTEXT;
	const result = await env.exec(command, { timeout: timeout ? timeout / 1000 : undefined, onOutput: (text) => (stdout += text) }, running);
	return result.ok
		? { stdout, stderr: "", code: result.value.exitCode, killed: false }
		: { stdout, stderr: result.error.message, code: 1, killed: result.error.code === "timeout" || result.error.code === "aborted" };
}

