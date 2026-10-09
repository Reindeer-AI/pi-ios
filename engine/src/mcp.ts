/**
 * MCP servers (Settings → MCP servers) in every session, over pi's MCP client (`@earendil-works/pi-mcp`): Streamable
 * HTTP, OAuth with dynamic client registration and PKCE, tokens refreshed as they expire. The app's native `mcp`
 * service holds the server list (pi's `mcpServers` shape) and the secrets: header values, and the OAuth state pi-mcp
 * keeps; the agent never sees them.
 *
 * Tools are named as in pi, `mcp__<server>__<tool>`, and exposed as pi's `exposure` says: `direct` tools are declared to
 * the model; `deferred` ones are found with mcp_search_tools and called with mcp_call_tool, which keeps a large server
 * out of the model's tool list; `auto` (the app's default) is direct for a server with a few tools, else deferred.
 * Signing in runs pi-mcp's OAuth flow as pi's own MCP extension does: dynamic client registration, or the client of an
 * app the user registered with the server (Slack, HubSpot: client ID, secret, scopes, and the redirect URL it has).
 * A loopback redirect (pi's default, http://127.0.0.1:33418/callback, or the app's own) is served by pi-mcp's callback
 * server through the app's `loopback` service, the page in a Safari sheet; any other redirect (https, a custom scheme)
 * is caught by the app's own sign-in view before it loads, and handed back (`mcp.authorizationResponse`), as pasting
 * the redirect URL does in pi.
 *
 * A phone drops connections: in the background, on a network change, when a server's session expires. Nothing stays
 * open between calls (no server-to-client stream); a server whose connection closed reconnects on its next call, and
 * when the app comes back to the foreground (`mcp.resume`). A call is retried once on a fresh connection only when the
 * server refused it (an expired session); a call cut off midway is reported, since it may have run.
 */
import { Type } from "@earendil-works/pi-ai";
import { oauthErrorHtml, oauthSuccessHtml } from "@earendil-works/pi-ai/utils/oauth-page";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { Extension } from "@earendil-works/pi-durable";
import { McpClient, McpSessionExpiredError, StreamableHttpTransport, toLlmContent, type CallToolResult, type Tool } from "@earendil-works/pi-mcp";
import {
	adaptOAuthProvider,
	authorizeMcp,
	McpOAuthAuthorizationRequiredError,
	McpOAuthProvider,
	OAuthCallbackServer,
	type McpOAuthState,
} from "@earendil-works/pi-mcp/oauth";
import { emit, type JsonValue, request } from "./bridge.ts";

type Exposure = "auto" | "direct" | "deferred" | "hidden";
type OAuthApp = { clientId?: string; clientSecret?: string; scope?: string; redirectUrl?: string };
type Config = {
	name: string;
	url: string;
	enabled: boolean;
	exposure: Exposure;
	description: string | null;
	headers: Record<string, string>;
	oauth: OAuthApp | null;
};
type State = "disabled" | "connecting" | "connected" | "disconnected" | "sign-in" | "error";
type ToolInfo = Pick<Tool, "name" | "title" | "description" | "inputSchema">;

/** Fixed, so the client a server registered for us keeps a redirect URI that works. */
const CALLBACK_PORT = 33418;
const DEFAULT_REDIRECT = `http://127.0.0.1:${CALLBACK_PORT}/callback`;
/** `auto`: up to this many tools are declared to the model, more are deferred. */
const DIRECT_LIMIT = 20;
/** A connection unused this long is checked (a ping) before a call, since the phone may have dropped it. */
const IDLE_CHECK_MS = 60_000;

class Server {
	client: McpClient | undefined;
	tools: ToolInfo[] = [];
	state: State = "disconnected";
	error: string | undefined;
	connecting: Promise<McpClient> | undefined;
	lastUsed = 0;
	constructor(public config: Config) {}

	get exposure(): Exclude<Exposure, "auto"> {
		if (this.config.exposure !== "auto") return this.config.exposure;
		return this.tools.length <= DIRECT_LIMIT ? "direct" : "deferred";
	}
}

const servers = new Map<string, Server>();
let listener: ((extension: Extension) => void) | undefined;
let current: Extension = build();

/** The "mcp" extension, as of now: rebuilt when the servers' tools change. */
export function mcpExtension(): Extension {
	return current;
}

/** Called with the rebuilt extension (main.ts installs it in the registry). */
export function onMcpExtensionChange(callback: (extension: Extension) => void): void {
	listener = callback;
}

// ---- servers ----

/** Reads the server list from the app and connects what is new or changed; unchanged servers keep their connection. */
export async function refreshMcp(): Promise<void> {
	const configs = await request<Config[]>("mcp", "servers");
	const cached = await request<Record<string, ToolInfo[]>>("mcp", "cachedTools").catch(() => ({}) as Record<string, ToolInfo[]>);
	const names = new Set(configs.map((config) => config.name));
	for (const [name, server] of servers) {
		if (!names.has(name)) {
			servers.delete(name);
			void server.client?.close().catch(() => {});
		}
	}
	for (const config of configs) {
		const existing = servers.get(config.name);
		const same =
			existing &&
			existing.config.url === config.url &&
			JSON.stringify(existing.config.headers) === JSON.stringify(config.headers) &&
			JSON.stringify(existing.config.oauth) === JSON.stringify(config.oauth);
		if (existing && same) {
			existing.config = config;
			if (!config.enabled) disable(existing);
			else if (existing.state === "disabled") connectInBackground(existing);
			continue;
		}
		if (existing) void existing.client?.close().catch(() => {});
		const server = new Server(config);
		// The tools it had: sessions keep them (and resumed runs can call them) while it connects.
		server.tools = cached[config.name] ?? [];
		servers.set(config.name, server);
		if (config.enabled) connectInBackground(server);
		else disable(server);
	}
	rebuild();
	changed();
}

function disable(server: Server) {
	void server.client?.close().catch(() => {});
	server.client = undefined;
	server.state = "disabled";
	server.error = undefined;
}

function connectInBackground(server: Server) {
	void connect(server).catch(() => {});
}

const store = (name: string) => ({
	load: async () => (await request<McpOAuthState | null>("mcp", "loadAuth", { server: name })) ?? undefined,
	save: (state: McpOAuthState) => request<void>("mcp", "saveAuth", { server: name, state }),
});

const isLoopback = (url: URL) => url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);

/** The redirect URL the server knows: the app's own, else pi's; a loopback one without a port gets ours (RFC 8252). */
function redirectOf(config: Config): URL {
	const url = new URL(config.oauth?.redirectUrl || DEFAULT_REDIRECT);
	if (isLoopback(url) && !url.port) url.port = String(CALLBACK_PORT);
	return url;
}

function provider(config: Config, onRedirect: (url: URL) => void = () => {}) {
	const app = config.oauth;
	return new McpOAuthProvider({
		serverUrl: config.url,
		redirectUrl: redirectOf(config).href,
		clientMetadata: { client_name: "pi", ...(app?.scope ? { scope: app.scope } : {}) },
		...(app?.clientId ? { clientId: app.clientId, ...(app.clientSecret ? { clientSecret: app.clientSecret } : {}) } : {}),
		store: store(config.name),
		onRedirect,
	});
}

/** Connects (again), lists the tools, and keeps the client; at most one attempt at a time per server. */
function connect(server: Server, oauth?: McpOAuthProvider): Promise<McpClient> {
	if (server.connecting && !oauth) return server.connecting;
	const self: { attempt?: Promise<McpClient> } = {};
	const attempt = (async () => {
		const previous = server.client;
		server.client = undefined;
		void previous?.close().catch(() => {});
		server.state = "connecting";
		changed();
		const client = new McpClient({ name: "pi-mobile", version: "1.0.0" });
		const transport = new StreamableHttpTransport({
			url: server.config.url,
			headers: server.config.headers,
			authProvider: adaptOAuthProvider(oauth ?? provider(server.config)),
			// Nothing held open between calls: iOS closes it in the background anyway.
			openGetStream: false,
		});
		try {
			await withTimeout(client.connect(transport), 30_000, "connecting");
			const tools = (await withTimeout(client.listTools(), 30_000, "listing tools")).map(({ name, title, description, inputSchema }) => ({ name, title, description, inputSchema }));
			client.onClose(() => {
				if (server.client !== client) return;
				server.client = undefined;
				if (server.state === "connected") server.state = "disconnected";
				changed();
			});
			server.client = client;
			server.state = "connected";
			server.error = undefined;
			server.lastUsed = Date.now();
			const toolsChanged = JSON.stringify(tools) !== JSON.stringify(server.tools);
			server.tools = tools;
			if (toolsChanged) {
				void request("mcp", "cacheTools", { server: server.config.name, tools }).catch(() => {});
				rebuild();
			}
			return client;
		} catch (error) {
			void client.close().catch(() => {});
			if (error instanceof McpOAuthAuthorizationRequiredError) {
				server.state = "sign-in";
				server.error = undefined;
			} else {
				server.state = "error";
				server.error = describe(error);
			}
			throw error;
		} finally {
			if (server.connecting === self.attempt) server.connecting = undefined;
			changed();
		}
	})();
	self.attempt = attempt;
	server.connecting = attempt;
	return attempt;
}

/** A live client for a call: reconnecting a dropped connection, and checking one that sat idle. */
async function ready(server: Server, signal?: AbortSignal): Promise<McpClient> {
	if (server.state === "disabled") throw new Error(`MCP server ${server.config.name} is turned off (Settings → MCP servers)`);
	if (server.state === "sign-in") throw new Error(`MCP server ${server.config.name} needs the user to sign in: Settings → MCP servers → ${server.config.name} → Sign in`);
	let client = server.client;
	if (client && Date.now() - server.lastUsed > IDLE_CHECK_MS) {
		try {
			await withTimeout(client.ping({ signal }), 8_000, "checking the connection");
		} catch {
			client = undefined;
		}
	}
	return client ?? (await connect(server));
}

async function call(server: Server, tool: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<CallToolResult> {
	for (let attempt = 0; ; attempt++) {
		const client = await ready(server, signal);
		try {
			const result = await client.callTool(tool, args, { signal });
			server.lastUsed = Date.now();
			return result;
		} catch (error) {
			// The server refused the call (its session expired): nothing ran, so a fresh connection may try again.
			if (error instanceof McpSessionExpiredError && attempt === 0) {
				server.client = undefined;
				continue;
			}
			if (signal?.aborted) throw error;
			throw new Error(
				`${describe(error)}. The connection to ${server.config.name} dropped during the call, so it may or may not have run on the server: check before calling it again.`,
			);
		}
	}
}

// ---- sign-in ----

let signingIn: { name: string; callback?: OAuthCallbackServer; reject: (error: Error) => void; respond?: (url: string) => void } | undefined;

/**
 * Signs in to a server: pi-mcp's OAuth flow, its authorization page shown by the app (`mcp_auth_url`, with `redirect`
 * when the app's sign-in view is to catch it). Resolves once connected.
 */
export async function signInMcp(name: string): Promise<void> {
	const server = servers.get(name);
	if (!server) throw new Error(`No MCP server named ${name}`);
	await cancelMcpSignIn();
	const config = server.config;
	const redirect = redirectOf(config);
	let authorizationUrl: URL | undefined;
	const oauth = provider(config, (url) => {
		authorizationUrl = url;
	});
	// Signed in already, or no sign-in needed.
	try {
		await connect(server, oauth);
		return;
	} catch (error) {
		if (!(error instanceof McpOAuthAuthorizationRequiredError)) throw error;
	}
	// Scopes the user set are asked for as such, as pi does (the connection attempt asked for the server's).
	const scope = config.oauth?.scope || undefined;
	if (scope && (await authorizeMcp(oauth, { serverUrl: config.url, scope })) !== "REDIRECT") return void (await connect(server, provider(config)));
	if (!authorizationUrl) throw new Error(`${name} asked for a sign-in but gave no authorization page`);
	const state = await oauth.state();

	let callback: OAuthCallbackServer | undefined;
	try {
		let response: Promise<{ code: string; iss?: string }>;
		if (isLoopback(redirect)) {
			callback = await OAuthCallbackServer.listen({
				host: "127.0.0.1",
				redirectHost: redirect.hostname,
				port: Number(redirect.port),
				path: redirect.pathname,
				renderPage: (page) => (page.ok ? oauthSuccessHtml("Signed in. You can go back to pi.") : oauthErrorHtml(page.message, page.details)),
			});
			response = callback.waitForCallback(state, redirect.pathname);
			signingIn = { name, callback, reject: () => {} };
			emit({ type: "mcp_auth_url", server: name, url: authorizationUrl.href });
		} else {
			response = new Promise((resolve, reject) => {
				const respond = (raw: string) => {
					try {
						const url = new URL(raw);
						if (url.searchParams.get("state") !== state) throw new Error("the sign-in came back for another request (state mismatch)");
						const failure = url.searchParams.get("error");
						if (failure) throw new Error(`${failure}${url.searchParams.get("error_description") ? `: ${url.searchParams.get("error_description")}` : ""}`);
						const code = url.searchParams.get("code");
						if (!code) throw new Error("the sign-in came back without an authorization code");
						resolve({ code, iss: url.searchParams.get("iss") ?? undefined });
					} catch (error) {
						reject(error instanceof Error ? error : new Error(String(error)));
					}
				};
				signingIn = { name, reject, respond };
			});
			emit({ type: "mcp_auth_url", server: name, url: authorizationUrl.href, redirect: redirect.href });
		}
		// `iss` too (RFC 9207): a server that sends it (Fireflies) is checked against it, and refused without it.
		const { code, iss } = await withTimeout(response, 10 * 60_000, "waiting for the sign-in");
		await authorizeMcp(oauth, { serverUrl: config.url, authorizationCode: code, iss, ...(scope ? { scope } : {}) });
		await connect(server, provider(config));
	} finally {
		if (signingIn?.name === name) signingIn = undefined;
		await callback?.close().catch(() => {});
		emit({ type: "mcp_auth_done", server: name });
	}
}

/** The app's sign-in view caught the redirect: the URL it was sent to. */
export function mcpAuthorizationResponse(url: string): void {
	signingIn?.respond?.(url);
}

/** The user closed the authorization page. */
export async function cancelMcpSignIn(): Promise<void> {
	const pending = signingIn;
	signingIn = undefined;
	pending?.reject(new Error("sign-in cancelled"));
	await pending?.callback?.close().catch(() => {});
}

/** After the app forgot a server's sign-in: drop its connection; the next attempt shows that it needs one. */
export async function signedOutMcp(name: string): Promise<void> {
	const server = servers.get(name);
	if (!server) return;
	void server.client?.close().catch(() => {});
	server.client = undefined;
	server.state = "sign-in";
	changed();
}

export function reconnectMcp(name: string): Promise<unknown> {
	const server = servers.get(name);
	if (!server) throw new Error(`No MCP server named ${name}`);
	return connect(server).then(
		() => null,
		() => null,
	);
}

/** The app is in the foreground again: reconnect what dropped, check what claims to be connected. */
export function resumeMcp(): void {
	for (const server of servers.values()) {
		if (server.state === "disconnected" || (server.state === "error" && server.client === undefined)) connectInBackground(server);
		else if (server.state === "connected" && server.client) {
			const client = server.client;
			void withTimeout(client.ping(), 8_000, "checking the connection").then(
				() => {
					server.lastUsed = Date.now();
				},
				() => {
					if (server.client === client) connectInBackground(server);
				},
			);
		}
	}
}

/** For Settings → MCP servers. */
export function listMcp() {
	return [...servers.values()].map((server) => ({
		name: server.config.name,
		url: server.config.url,
		enabled: server.config.enabled,
		exposure: server.config.exposure,
		effectiveExposure: server.exposure,
		state: server.state,
		error: server.error ?? null,
		tools: server.tools.map((tool) => ({ name: tool.name, description: tool.description ?? "" })),
		instructions: server.client?.instructions ?? null,
	}));
}

function changed() {
	emit({ type: "mcp_status" });
}

// ---- tools and the prompt ----

const safe = (value: string) => value.replace(/[^A-Za-z0-9_-]/g, "_");
/** pi's tool name: `mcp__<server>__<tool>`, `-` as `_`, at most 64 characters. */
const toolName = (server: string, tool: string) => `mcp__${safe(server).replace(/-/g, "_")}__${safe(tool)}`.slice(0, 64);

function result(server: Server, tool: string, outcome: CallToolResult) {
	const content = toLlmContent(outcome);
	return { content: content.length ? content : [{ type: "text" as const, text: `${server.config.name}.${tool}: no content` }], isError: outcome.isError === true };
}

function directTool(server: Server, tool: ToolInfo) {
	const schema = tool.inputSchema as Record<string, unknown> | undefined;
	return defineTool({
		name: toolName(server.config.name, tool.name),
		description: `${tool.description ?? tool.title ?? tool.name} (MCP server ${server.config.name})`.slice(0, 1024),
		// Providers want an object schema, some with properties.
		parameters: Type.Unsafe<Record<string, unknown>>({ ...(schema ?? {}), type: "object", properties: (schema?.properties as object) ?? {} }),
		// A call is not made again when a run resumes: its result is kept.
		replay: "safe",
		execute: async (args, toolApi, context) => {
			let outcome = (await toolApi.memo<JsonValue>("result", context)) as CallToolResult | undefined;
			if (!outcome) {
				outcome = await call(server, tool.name, (args ?? {}) as Record<string, unknown>, context.abortSignal);
				await toolApi.memo<JsonValue>("result", outcome as unknown as JsonValue, context);
			}
			return result(server, tool.name, outcome);
		},
	});
}

const searchTools = defineTool({
	name: "mcp_search_tools",
	description:
		"Finds tools of the MCP servers listed as on demand in mcp_servers: their names, what they do, and their parameters. Then call one with mcp_call_tool.",
	parameters: Type.Object({
		server: Type.Optional(Type.String({ description: "Only this server's tools" })),
		query: Type.Optional(Type.String({ description: "Words to look for in tool names and descriptions; empty lists them all" })),
	}),
	execute: async (args) => {
		const words = (args.query ?? "").toLowerCase().split(/\s+/).filter(Boolean);
		const found: { server: string; tool: ToolInfo }[] = [];
		for (const server of servers.values()) {
			if (server.exposure !== "deferred" || server.state === "disabled") continue;
			if (args.server && server.config.name !== args.server) continue;
			for (const tool of server.tools) {
				const text = `${tool.name} ${tool.title ?? ""} ${tool.description ?? ""}`.toLowerCase();
				if (words.every((word) => text.includes(word))) found.push({ server: server.config.name, tool });
			}
		}
		if (!found.length) return { content: [{ type: "text", text: "No matching tools." }] };
		const withSchemas = found.length <= 8;
		const text = found
			.slice(0, 40)
			.map(({ server, tool }) =>
				[`${server} · ${tool.name}: ${(tool.description ?? tool.title ?? "").slice(0, 300)}`, withSchemas ? `  parameters: ${JSON.stringify(tool.inputSchema)}` : ""].filter(Boolean).join("\n"),
			)
			.join("\n");
		const more = found.length > 40 ? `\n… ${found.length - 40} more: narrow the query` : withSchemas ? "" : "\n(Search with fewer matches to see parameters.)";
		return { content: [{ type: "text", text: text + more }] };
	},
});

const callTool = defineTool({
	name: "mcp_call_tool",
	description: "Calls a tool of an MCP server listed as on demand in mcp_servers (find it with mcp_search_tools first).",
	parameters: Type.Object({
		server: Type.String(),
		tool: Type.String({ description: "The tool's name as mcp_search_tools gives it" }),
		arguments: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
	}),
	replay: "safe",
	execute: async (args, toolApi, context) => {
		const server = servers.get(args.server);
		if (!server) throw new Error(`No MCP server named ${args.server}`);
		let outcome = (await toolApi.memo<JsonValue>("result", context)) as CallToolResult | undefined;
		if (!outcome) {
			outcome = await call(server, args.tool, args.arguments ?? {}, context.abortSignal);
			await toolApi.memo<JsonValue>("result", outcome as unknown as JsonValue, context);
		}
		return result(server, args.tool, outcome);
	},
});

function renderSection(): string | undefined {
	if (!servers.size) return undefined;
	const lines = [...servers.values()].map((server) => {
		const name = server.config.name;
		const about = (server.config.description ?? server.client?.instructions ?? "").split("\n")[0].slice(0, 200);
		if (server.state === "disabled") return undefined;
		if (server.state === "sign-in") return `- ${name}: needs the user to sign in (Settings → MCP servers → ${name} → Sign in).`;
		if (!server.tools.length) return `- ${name}: ${server.state === "error" ? `unavailable (${server.error})` : "connecting"}.`;
		const how =
			server.exposure === "deferred"
				? `${server.tools.length} tools, on demand: find them with mcp_search_tools, call them with mcp_call_tool`
				: server.exposure === "direct"
					? `${server.tools.length} tools, named ${toolName(name, "<tool>")}`
					: "hidden";
		return `- ${name}: ${how}.${about ? ` ${about}` : ""}`;
	});
	const shown = lines.filter(Boolean);
	if (!shown.length) return undefined;
	return `MCP servers the user connected (their sign-ins and keys stay in the app):\n${shown.join("\n")}`;
}

function build(): Extension {
	const tools = [];
	let deferred = false;
	for (const server of servers.values()) {
		if (server.state === "disabled") continue;
		if (server.exposure === "direct") tools.push(...server.tools.map((tool) => directTool(server, tool)));
		else if (server.exposure === "deferred") deferred ||= server.tools.length > 0;
	}
	if (deferred) tools.push(searchTools, callTool);
	return defineExtension({ name: "mcp", tools, sections: [section("mcp_servers", () => renderSection())] });
}

function rebuild() {
	current = build();
	listener?.(current);
}

// ---- helpers ----

function describe(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return message.length > 300 ? `${message.slice(0, 300)}…` : message;
}

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
	let timer: ReturnType<typeof setTimeout>;
	return Promise.race([
		promise,
		new Promise<never>((_, reject) => {
			timer = setTimeout(() => reject(new Error(`timed out ${what} after ${ms / 1000} s`)), ms);
		}),
	]).finally(() => clearTimeout(timer));
}
