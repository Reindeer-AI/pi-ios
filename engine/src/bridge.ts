/**
 * Bridge between the engine (inside WebKit) and the native app.
 *
 * - Engine → native requests: `request(service, method, params)` posts to the `pi` script message handler and
 *   awaits native's reply (WKScriptMessageHandlerWithReply).
 * - Engine → native events: `emit(event)`, fire-and-forget.
 * - Native → engine commands: native calls `window.__pi.command(method, params)` with callAsyncJavaScript and
 *   awaits the returned promise.
 */

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

type NativeMessage = { service: string; method: string; params?: unknown };

type WebKitHandler = { postMessage(message: NativeMessage): Promise<unknown> };

declare global {
	interface Window {
		webkit?: { messageHandlers?: { pi?: WebKitHandler } };
		__pi?: { command(method: string, params: unknown): Promise<unknown> };
	}
}

function handler(): WebKitHandler {
	const pi = window.webkit?.messageHandlers?.pi;
	if (!pi) throw new Error("Native bridge unavailable: no `pi` script message handler");
	return pi;
}

/** Calls a native service and returns its reply. Native rejections arrive as errors with native's message. */
export async function request<T = unknown>(service: string, method: string, params?: unknown): Promise<T> {
	return (await handler().postMessage({ service, method, params: toTransferable(params) })) as T;
}

/** Sends an event to native without waiting for it to be handled. */
export function emit(event: { type: string; [key: string]: unknown }): void {
	handler()
		.postMessage({ service: "events", method: "emit", params: toTransferable(event) })
		.catch(() => {});
}

type CommandHandler = (params: any) => Promise<unknown> | unknown;

const commands = new Map<string, CommandHandler>();
let gate: ((method: string) => Promise<void>) | undefined;

/** Registers a command native can call through `window.__pi.command`. */
export function onCommand(method: string, run: CommandHandler): void {
	commands.set(method, run);
}

/** What every command waits for before it runs (`main.ts`: the store opening). */
export function gateCommands(wait: (method: string) => Promise<void>): void {
	gate = wait;
}

window.__pi = {
	async command(method, params) {
		const run = commands.get(method);
		if (!run) throw new Error(`Unknown engine command: ${method}`);
		await gate?.(method);
		return toTransferable(await run(params));
	},
};

/** Forwards console output and uncaught errors to native, since the engine has no visible console. */
export function forwardConsole(): void {
	for (const level of ["log", "info", "warn", "error", "debug"] as const) {
		const original = console[level].bind(console);
		console[level] = (...args: unknown[]) => {
			original(...args);
			handler()
				.postMessage({ service: "log", method: level, params: args.map(formatLogArg).join(" ") })
				.catch(() => {});
		};
	}
	window.addEventListener("error", (event) => console.error("Uncaught", event.error ?? event.message));
	window.addEventListener("unhandledrejection", (event) => console.error("Unhandled rejection", event.reason));
}

function formatLogArg(arg: unknown): string {
	if (typeof arg === "string") return arg;
	if (arg instanceof Error) return arg.stack ? `${arg.message}\n${arg.stack}` : arg.message;
	try {
		return JSON.stringify(arg);
	} catch {
		return String(arg);
	}
}

/** Message handlers accept JSON-like values only; round-trip through JSON so class instances serialize predictably. */
function toTransferable(value: unknown): unknown {
	return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}
