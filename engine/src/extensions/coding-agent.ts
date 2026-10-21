/**
 * `@earendil-works/pi-coding-agent` (and `@mariozechner/pi-coding-agent`) as extension code imports it. Every name the
 * package exports exists here (the build checks this against the installed package):
 *
 * - pi's own code where it runs here unchanged: truncation and sizes, message conversion, frontmatter, source info;
 * - small equivalents of helpers that are mixed into Node-only modules: session context, token estimates, the file
 *   mutation queue, language detection, the agent directory, shell operations, the clipboard;
 * - terminal UI (components, themes, key hints), which has no screen here: classes that construct and render
 *   nothing, and styling that returns text unchanged;
 * - pi's CLI and its own agent runtime (sessions, settings, resource loading, built-in tool factories), which extensions
 *   here do not have: functions and classes that throw an error naming what is missing.
 */
import { convertToLlm, createBranchSummaryMessage, createCompactionSummaryMessage, createCustomMessage } from "@earendil-works/pi-coding-agent/dist/core/messages.js";
import { createSyntheticSourceInfo } from "@earendil-works/pi-coding-agent/dist/core/source-info.js";
import { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, formatSize, truncateHead, truncateLine, truncateTail } from "@earendil-works/pi-coding-agent/dist/core/tools/truncate.js";
import { parseFrontmatter, stripFrontmatter } from "@earendil-works/pi-coding-agent/dist/utils/frontmatter.js";
import EventEmitter from "events";
import { BorderedLoader, componentTheme, DynamicBorder, highlightCode, markdownTheme, selectListTheme, settingsListTheme } from "./components.ts";

/** pi's `:start-end` label of a read's line range (its `render-utils.ts`, which needs a terminal). */
function formatReadLineRange(offset: unknown, limit: unknown): string {
	const line = (value: unknown) => {
		if (typeof value === "string" && value.trim() !== "") value = Number(value);
		return typeof value === "number" && Number.isFinite(value) ? value : undefined;
	};
	if (offset == null && limit == null) return "";
	const start = offset == null ? 1 : line(offset);
	if (start === undefined) return "";
	if (limit == null) return `:${start}`;
	const count = line(limit);
	if (count === undefined) return "";
	const end = start + count - 1;
	return `:${start}${end ? `-${end}` : ""}`;
}

/** What the module needs from the engine. */
export type CodingAgentServices = {
	/** pi's agent directory (`~/.pi/agent`): one per app. */
	agentDir: string;
	copyToClipboard(text: string): Promise<void>;
	/** Runs a command in the shell, as pi's local bash operations do. */
	exec(command: string, cwd: string, options: { onData: (data: string) => void; signal?: AbortSignal; timeout?: number }): Promise<{ exitCode: number | null }>;
};

type Entry = { type: string; id: string; parentId?: string | null; timestamp?: string; [key: string]: unknown };
type Message = { role: string; [key: string]: unknown };

/** The component classes of pi's terminal UI, which construct and render nothing here. */
const COMPONENTS = [
	"ArminComponent",
	"AssistantMessageComponent",
	"BashExecutionComponent",
	"BorderedLoader",
	"BranchSummaryMessageComponent",
	"CompactionSummaryMessageComponent",
	"CustomEditor",
	"CustomMessageComponent",
	"DynamicBorder",
	"ExtensionEditorComponent",
	"ExtensionInputComponent",
	"ExtensionSelectorComponent",
	"FooterComponent",
	"LoginDialogComponent",
	"ModelSelectorComponent",
	"OAuthSelectorComponent",
	"SessionSelectorComponent",
	"SettingsSelectorComponent",
	"ShowImagesSelectorComponent",
	"SkillInvocationMessageComponent",
	"ThemeSelectorComponent",
	"ThinkingSelectorComponent",
	"ToolExecutionComponent",
	"TreeSelectorComponent",
	"UserMessageComponent",
	"UserMessageSelectorComponent",
];

/** Parts of pi's CLI and agent runtime, which extensions here do not have, and why. */
const UNAVAILABLE: Record<string, string> = {
	AgentSession: "pi's own agent session",
	AgentSessionRuntime: "pi's own agent session",
	createAgentSession: "pi's own agent session",
	createAgentSessionFromServices: "pi's own agent session",
	createAgentSessionRuntime: "pi's own agent session",
	createAgentSessionServices: "pi's own agent session",
	SessionManager: "pi's session files",
	SettingsManager: "pi's settings files",
	ModelRegistry: "pi's model registry (use ctx.modelRegistry)",
	ModelRuntime: "pi's model runtime",
	readStoredCredential: "pi's credential store",
	resolveCliModel: "pi's CLI",
	resolveModelScopeWithDiagnostics: "pi's CLI",
	parseArgs: "pi's CLI",
	main: "pi's CLI",
	runPrintMode: "pi's CLI",
	runRpcMode: "pi's CLI",
	InteractiveMode: "pi's terminal UI",
	RpcClient: "pi's RPC mode",
	ExtensionRunner: "pi's extension loader",
	createExtensionRuntime: "pi's extension loader",
	discoverAndLoadExtensions: "pi's extension loader",
	wrapRegisteredTool: "pi's extension loader",
	wrapRegisteredTools: "pi's extension loader",
	DefaultResourceLoader: "pi's resource loader",
	DefaultPackageManager: "pi's package manager",
	loadProjectContextFiles: "pi's resource loader",
	loadSkills: "pi's skill loader",
	loadSkillsFromDir: "pi's skill loader",
	formatSkillsForPrompt: "pi's skill loader",
	parseSkillBlock: "pi's skill loader",
	ProjectTrustStore: "pi's project trust",
	hasTrustRequiringProjectResources: "pi's project trust",
	createBashTool: "pi's built-in tools",
	createBashToolDefinition: "pi's built-in tools",
	createCodingTools: "pi's built-in tools",
	createEditTool: "pi's built-in tools",
	createEditToolDefinition: "pi's built-in tools",
	createFindTool: "pi's built-in tools",
	createFindToolDefinition: "pi's built-in tools",
	createGrepTool: "pi's built-in tools",
	createGrepToolDefinition: "pi's built-in tools",
	createLsTool: "pi's built-in tools",
	createLsToolDefinition: "pi's built-in tools",
	createPowerShellTool: "pi's built-in tools",
	createPowerShellToolDefinition: "pi's built-in tools",
	createLocalPowerShellOperations: "PowerShell",
	getPowerShellConfig: "PowerShell",
	createReadOnlyTools: "pi's built-in tools",
	createReadTool: "pi's built-in tools",
	createReadToolDefinition: "pi's built-in tools",
	createWriteTool: "pi's built-in tools",
	createWriteToolDefinition: "pi's built-in tools",
	createCodemodeExtension: "pi's codemode extension",
	createMcpExtension: "pi's MCP extension",
	createToolSearchExtension: "pi's tool search extension",
	compact: "pi's compaction (use ctx.compact)",
	generateSummary: "pi's compaction (use ctx.compact)",
	generateSummaryWithUsage: "pi's compaction (use ctx.compact)",
	generateBranchSummary: "pi's session tree",
	collectEntriesForBranchSummary: "pi's session tree",
	prepareBranchEntries: "pi's session tree",
	findCutPoint: "pi's compaction",
	findTurnStartIndex: "pi's compaction",
	shouldCompact: "pi's compaction",
	migrateSessionEntries: "pi's session files",
	parseSessionEntries: "pi's session files",
	buildSessionProjection: "pi's session files (use ctx.sessionManager)",
	generateDiffString: "pi's edit tool",
	generateUnifiedPatch: "pi's edit tool",
	getPackageDir: "pi's installation",
	getDocsPath: "pi's installation",
	getExamplesPath: "pi's installation",
	getReadmePath: "pi's installation",
	convertToPng: "image conversion",
	resizeImage: "image conversion",
	detectSupportedImageMimeTypeFromFile: "image conversion",
	formatDimensionNote: "image conversion",
};

/** The module, for one engine. */
export function codingAgentModule(services: CodingAgentServices): Record<string, unknown> {
	const module: Record<string, unknown> = {};
	const missing = (name: string, member?: string) =>
		new Error(`pi-coding-agent's ${member ? `${name}.${member}` : name} is not available in pi on iOS (it is part of ${UNAVAILABLE[name]})`);
	for (const name of Object.keys(UNAVAILABLE)) {
		// Constructing or calling one fails with the reason; static calls (`SessionManager.open()`) too.
		module[name] = new Proxy(
			function unavailable() {
				throw missing(name);
			},
			{
				construct: () => {
					throw missing(name);
				},
				get: (target, key) => (key === "name" ? name : key === "prototype" ? target.prototype : typeof key === "symbol" ? undefined : () => {
					throw missing(name, String(key));
				}),
			},
		);
	}
	// An error class still behaves as one.
	module.CredentialSynchronizationError = class CredentialSynchronizationError extends Error {};

	for (const name of COMPONENTS) {
		module[name] = { [name]: class extends InertComponent {} }[name];
	}
	// The two components extensions use most in their own views (the app maps them to a divider and a spinner).
	module.DynamicBorder = DynamicBorder;
	module.BorderedLoader = BorderedLoader;

	Object.assign(module, {
		VERSION: "1.3.0",
		CONFIG_DIR_NAME: ".pi",
		CURRENT_SESSION_VERSION: 3,
		DEFAULT_COMPACTION_SETTINGS: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 },
		VIRTUAL_MODEL_STATE_ENTRY: "pi.virtual-model-state",
		DEFAULT_MAX_BYTES,
		DEFAULT_MAX_LINES,
		formatSize,
		truncateHead,
		truncateTail,
		truncateLine,
		truncateToVisualLines,
		formatReadLineRange,
		convertToLlm,
		parseFrontmatter,
		stripFrontmatter,
		createSyntheticSourceInfo,
		defineTool: <T>(tool: T) => tool,
		createEventBus: () => {
			const emitter = new EventEmitter();
			return {
				emit: (channel: string, data: unknown) => emitter.emit(channel, data),
				on: (channel: string, handler: (data: unknown) => void) => {
					emitter.on(channel, handler);
					return () => emitter.off(channel, handler);
				},
				clear: () => emitter.removeAllListeners(),
			};
		},
		getAgentDir: () => services.agentDir,
		getShellConfig: () => ({ shell: "sh", args: ["-c"] }),
		createLocalBashOperations: () => ({
			exec: (command: string, cwd: string, options: { onData: (data: unknown) => void; signal?: AbortSignal; timeout?: number }) =>
				services.exec(command, cwd, options),
		}),
		copyToClipboard: (text: string) => services.copyToClipboard(text),
		withFileMutationQueue,
		estimateTokens,
		calculateContextTokens: (usage: { totalTokens?: number; input?: number; output?: number; cacheRead?: number; cacheWrite?: number }) =>
			usage.totalTokens || (usage.input ?? 0) + (usage.output ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0),
		getLastAssistantUsage: (entries: Entry[]) => {
			for (let index = entries.length - 1; index >= 0; index--) {
				const message = entries[index]!.message as Message | undefined;
				if (entries[index]!.type === "message" && message?.role === "assistant" && message.stopReason !== "aborted" && message.stopReason !== "error") return message.usage;
			}
			return undefined;
		},
		serializeConversation: (messages: Message[]) => serialize(messages),
		getLatestCompactionEntry: (entries: Entry[]) => [...entries].reverse().find((entry) => entry.type === "compaction"),
		sessionEntryToContextMessages,
		buildContextEntries: (entries: Entry[]) => contextEntries(entries),
		buildSessionContext: (entries: Entry[]) => sessionContext(entries),
		isToolCallEventType: (toolName: string, event: { toolName?: string }) => event.toolName === toolName,
		getLanguageFromPath,
		// pi's theme, as terminal styles panels show in color.
		Theme: StyledText,
		initTheme: () => {},
		getMarkdownTheme: markdownTheme,
		getSelectListTheme: selectListTheme,
		getSettingsListTheme: settingsListTheme,
		highlightCode,
		renderDiff: (diff: string) => diff,
		keyText: (keybinding: string) => keybinding,
		keyHint: (keybinding: string, description: string) => `${keybinding} ${description}`,
		rawKeyHint: (key: string, description: string) => `${key} ${description}`,
	});
	for (const kind of ["Bash", "PowerShell", "Read", "Edit", "Write", "Grep", "Find", "Ls"]) {
		module[`is${kind}ToolResult`] = (event: { toolName?: string }) => event.toolName === kind.toLowerCase();
	}
	return module;
}

class InertComponent {
	constructor(..._args: unknown[]) {}
	render(_width?: number): string[] {
		return [];
	}
	invalidate(): void {}
	handleInput(_data?: string): void {}
	dispose(): void {}
}

/** pi's `Theme` and component themes: every style (`fg(color, text)`, `bold(text)`, …) returns its text. */
/** pi's `Theme`: an instance styles as `ctx.ui.theme` does, whatever colors it is made with. */
class StyledText {
	constructor() {
		// biome-ignore lint/correctness/noConstructorReturn: every property is the shared theme's
		return new Proxy(this, {
			get: (target, key) => (key in target || typeof key === "symbol" ? Reflect.get(target, key) : Reflect.get(componentTheme, key)),
		});
	}
}

function truncateToVisualLines(text: string, maxVisualLines: number, _width: number, _paddingX = 0, keep: "start" | "end" = "end") {
	const lines = text.split("\n");
	if (lines.length <= maxVisualLines) return { visualLines: lines, skippedCount: 0 };
	const visualLines = keep === "start" ? lines.slice(0, maxVisualLines) : lines.slice(-maxVisualLines);
	return { visualLines, skippedCount: lines.length - maxVisualLines };
}

const mutationQueues = new Map<string, Promise<unknown>>();

/** Runs `fn` after earlier mutations of the same file finish, as pi's edit and write tools serialize them. */
async function withFileMutationQueue<T>(filePath: string, fn: () => Promise<T>): Promise<T> {
	const previous = mutationQueues.get(filePath) ?? Promise.resolve();
	const run = previous.then(fn, fn);
	const settled = run.then(
		() => undefined,
		() => undefined,
	);
	mutationQueues.set(filePath, settled);
	try {
		return await run;
	} finally {
		if (mutationQueues.get(filePath) === settled) mutationQueues.delete(filePath);
	}
}

/** pi's token estimate: characters / 4. */
function estimateTokens(message: Message): number {
	const text = (content: unknown): number =>
		typeof content === "string"
			? content.length
			: Array.isArray(content)
				? content.reduce((sum: number, block: { type?: string; text?: string }) => sum + (block.type === "text" ? (block.text?.length ?? 0) : block.type === "image" ? 4800 : 0), 0)
				: 0;
	let chars = 0;
	switch (message.role) {
		case "system":
			chars = text(message.content) + Object.values((message.sections as Record<string, string | null>) ?? {}).reduce((sum, section) => sum + (section?.length ?? 0), 0);
			if (message.toolsAdded) chars += JSON.stringify(message.toolsAdded).length;
			break;
		case "assistant":
			for (const block of (message.content as { type: string; text?: string; thinking?: string; name?: string; arguments?: unknown }[]) ?? []) {
				if (block.type === "text") chars += block.text?.length ?? 0;
				else if (block.type === "thinking") chars += block.thinking?.length ?? 0;
				else if (block.type === "toolCall") chars += (block.name?.length ?? 0) + JSON.stringify(block.arguments ?? {}).length;
			}
			break;
		case "bashExecution":
			chars = String(message.command ?? "").length + String(message.output ?? "").length;
			break;
		case "branchSummary":
		case "compactionSummary":
			chars = String(message.summary ?? "").length;
			break;
		default:
			chars = text(message.content);
	}
	return Math.ceil(chars / 4);
}

function serialize(messages: Message[]): string {
	return (convertToLlm(messages as never) as unknown as Message[])
		.map((message) => {
			const content = message.content;
			const body = typeof content === "string" ? content : Array.isArray(content) ? content.map((block: { type: string; text?: string; name?: string; arguments?: unknown }) => (block.type === "text" ? block.text : block.type === "toolCall" ? `[tool call ${block.name} ${JSON.stringify(block.arguments)}]` : "")).join("\n") : "";
			return `[${message.role}]: ${body}`;
		})
		.join("\n\n");
}

function sessionEntryToContextMessages(entry: Entry): Message[] {
	const timestamp = entry.timestamp ?? new Date().toISOString();
	let message: unknown;
	if (entry.type === "message") message = entry.message;
	else if (entry.type === "custom_message") message = createCustomMessage(entry.customType as string, (entry.content as never) ?? [], entry.display as boolean, entry.details, timestamp);
	else if (entry.type === "branch_summary" && entry.summary) message = createBranchSummaryMessage(entry.summary as string, entry.fromId as string, timestamp);
	else if (entry.type === "compaction") message = createCompactionSummaryMessage(entry.summary as string, (entry.tokensBefore as number) ?? 0, timestamp);
	return message === undefined ? [] : [message as Message];
}

/** The entries the model sees: from the newest compaction (with the entries it keeps) on. */
function contextEntries(entries: Entry[]): Entry[] {
	for (let index = entries.length - 1; index >= 0; index--) {
		const entry = entries[index]!;
		if (entry.type !== "compaction") continue;
		const kept = entries.findIndex((candidate) => candidate.id === entry.firstKeptEntryId);
		return [entry, ...entries.slice(kept < 0 ? index + 1 : kept).filter((candidate) => candidate !== entry)];
	}
	return [...entries];
}

function sessionContext(entries: Entry[]) {
	let thinkingLevel = "off";
	let model: { provider: string; modelId: string } | null = null;
	for (const entry of entries) {
		if (entry.type === "thinking_level_change") thinkingLevel = entry.thinkingLevel as string;
		else if (entry.type === "model_change") model = { provider: entry.provider as string, modelId: entry.modelId as string };
		else if (entry.type === "message" && (entry.message as Message).role === "assistant") {
			const message = entry.message as Message;
			model = { provider: message.provider as string, modelId: message.model as string };
		}
	}
	const messages = contextEntries(entries)
		.flatMap(sessionEntryToContextMessages)
		.filter((message) => message.role !== "system");
	return { messages, thinkingLevel, model };
}

function getLanguageFromPath(filePath: string): string | undefined {
	const ext = filePath.split(".").pop()?.toLowerCase();
	return ext ? LANGUAGES[ext] : undefined;
}

const LANGUAGES: Record<string, string> = {
	ts: "typescript", tsx: "typescript", js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
	py: "python", rb: "ruby", rs: "rust", go: "go", java: "java", kt: "kotlin", swift: "swift", c: "c", h: "c",
	cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", cs: "csharp", php: "php", sh: "bash", bash: "bash", zsh: "bash",
	fish: "fish", ps1: "powershell", sql: "sql", html: "html", htm: "html", css: "css", scss: "scss", sass: "sass",
	less: "less", json: "json", yaml: "yaml", yml: "yaml", toml: "toml", xml: "xml", md: "markdown", markdown: "markdown",
	dockerfile: "dockerfile", makefile: "makefile", cmake: "cmake", lua: "lua", perl: "perl", r: "r", scala: "scala",
	clj: "clojure", ex: "elixir", exs: "elixir", erl: "erlang", hs: "haskell", ml: "ocaml", vim: "vim",
	graphql: "graphql", proto: "protobuf", tf: "hcl", hcl: "hcl",
};
