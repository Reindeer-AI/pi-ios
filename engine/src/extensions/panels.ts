/**
 * Panels: web views the app shows for a session, the mobile counterpart of pi's terminal UI.
 *
 * A panel shows HTML (an extension's own page) or a view tree (a pi-tui component mapped to native-looking views by
 * `tui.ts`). It sits in a sheet or above the session's message box (a widget), and talks to whoever opened it: its
 * page calls `pi.post(data)`, `pi.close(result)`, and `pi.onMessage(callback)`; tapped views send events. The agent
 * shows interactive HTML in the chat with `show_html`, which the app renders from the call itself, so the card stays in
 * the transcript.
 */
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { emit, onCommand } from "../bridge.ts";

export type Placement = "sheet" | "widget";

/** A node of a view tree (see `tui.ts`); `html` is already escaped and styled. */
export type ViewNode =
	| { id: string; type: "stack"; direction: "vertical" | "horizontal"; children: ViewNode[] }
	| { id: string; type: "html"; html: string; markdown?: boolean }
	| { id: string; type: "lines"; html: string[]; input: boolean }
	| { id: string; type: "spacer"; lines: number }
	| { id: string; type: "divider" }
	| { id: string; type: "select"; items: { label: string; description?: string }[]; selected: number }
	| { id: string; type: "settings"; items: { id: string; label: string; value: string; values?: string[]; description?: string }[] }
	| { id: string; type: "input"; value: string; placeholder?: string }
	| { id: string; type: "editor"; value: string }
	| { id: string; type: "loader"; message: string; cancellable: boolean };

export type PanelContent = { kind: "html"; html: string } | { kind: "view"; root: ViewNode; keys: boolean };
export type PanelEvent = { type: string; [key: string]: unknown };

export type Panel = {
	readonly id: string;
	update(content: PanelContent): void;
	/** Sends a message to the panel's page (`pi.onMessage`). */
	post(data: unknown): void;
	close(): void;
	/** An app's page: back on screen, or off it to the dock (`apps.ts`). */
	show(): void;
	hide(): void;
	/** An app's page: its saved state changed (`pi.state.onChange`). */
	setState(state: unknown): void;
};

type Handlers = {
	event(event: PanelEvent): void;
	dismissed(): void;
	/** An app's page: the user minimized it, opened it again from the dock, or the app unloaded it while minimized. */
	minimized?(): void;
	restored?(): void;
	suspended?(): void;
};

/** What makes a panel an app's page (`apps.ts`): it minimizes instead of closing, and has a saved state. */
export type PanelApp = { key: string; name: string; icon: string | null; shared: boolean; state: unknown };

const open = new Map<string, Handlers>();
let nextPanel = 0;

export function openPanel(
	sessionId: number,
	extension: string,
	placement: Placement,
	title: string | undefined,
	content: PanelContent,
	handlers: Handlers,
	app?: PanelApp,
): Panel {
	const id = `panel-${++nextPanel}`;
	open.set(id, handlers);
	emit({ type: "panel_open", id, sessionId, extension, placement, title: title ?? null, content, app: app ?? null });
	return {
		id,
		update: (next) => {
			if (open.has(id)) emit({ type: "panel_update", id, content: next });
		},
		post: (data) => {
			if (open.has(id)) emit({ type: "panel_message", id, data: data ?? null });
		},
		close: () => {
			if (open.delete(id)) emit({ type: "panel_close", id });
		},
		show: () => {
			if (open.has(id)) emit({ type: "panel_show", id });
		},
		hide: () => {
			if (open.has(id)) emit({ type: "panel_hide", id });
		},
		setState: (state) => {
			if (open.has(id)) emit({ type: "panel_state", id, state: state ?? null });
		},
	};
}

onCommand("panel.event", ({ id, event }: { id: string; event: PanelEvent }) => {
	open.get(id)?.event(event);
	return null;
});

/** The user closed the panel. */
onCommand("panel.dismissed", ({ id }: { id: string }) => {
	const handlers = open.get(id);
	open.delete(id);
	handlers?.dismissed();
	return null;
});

/** An app's page: the user minimized it to the dock. */
onCommand("panel.minimized", ({ id }: { id: string }) => {
	open.get(id)?.minimized?.();
	return null;
});

/** An app's page: the user opened it again from the dock. */
onCommand("panel.restored", ({ id }: { id: string }) => {
	open.get(id)?.restored?.();
	return null;
});

/** An app's page: the app unloaded it while minimized (to save memory); opening the app draws it again. */
onCommand("panel.suspended", ({ id }: { id: string }) => {
	const handlers = open.get(id);
	open.delete(id);
	handlers?.suspended?.();
	return null;
});

/**
 * An extension's HTML page in a panel (`ctx.ui.panel`): a sheet resolves `closed` with what the page passes to
 * `pi.close(result)`, or undefined when the user closes it; a widget stays until closed.
 */
export function htmlPanel(
	sessionId: number,
	extension: string,
	options: { html: string; title?: string; placement?: Placement; onMessage?: (data: unknown) => void },
) {
	let finish!: (result: unknown) => void;
	const closed = new Promise<unknown>((resolve) => (finish = resolve));
	let done = false;
	const end = (result: unknown) => {
		if (done) return;
		done = true;
		panel.close();
		finish(result);
	};
	const panel = openPanel(sessionId, extension, options.placement ?? "sheet", options.title, { kind: "html", html: options.html }, {
		event: (event) => {
			if (event.type === "message") options.onMessage?.(event.data);
			else if (event.type === "close") end(event.result ?? undefined);
		},
		dismissed: () => end(undefined),
	});
	return {
		post: (data: unknown) => panel.post(data),
		update: (html: string) => panel.update({ kind: "html", html }),
		close: () => end(undefined),
		closed,
	};
}

/** The agent's `show_html`: interactive HTML as a card in the chat. */
export const PanelTools = defineExtension({
	name: "panels",
	sections: [
		section(
			"panels",
			() => `To show the user something visual or interactive (a chart, a calculator, a small app, a form, a styled summary), call show_html with a complete HTML document. It appears as a card in the chat, on a phone screen (about 390 points wide; light and dark mode). Keep it self-contained: inline CSS and JavaScript, or libraries from cdnjs.cloudflare.com or cdn.jsdelivr.net. In its script, pi.prompt(text) sends text to you as the user's next message (for example a form's answers).`,
		),
	],
	tools: [
		defineTool({
			name: "show_html",
			description: "Show the user an interactive HTML card in the chat. The card stays in the conversation.",
			parameters: Type.Object({
				title: Type.String({ description: "A short title for the card" }),
				html: Type.String({ description: "A complete HTML document" }),
			}),
			replay: "safe",
			execute: async (args) => ({ content: [{ type: "text", text: `Shown to the user: ${args.title}` }] }),
		}),
	],
});
