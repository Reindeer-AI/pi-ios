/**
 * pi-tui for extension code, and its components on the app's screen.
 *
 * Extensions import pi-tui itself (bundled; its terminal, file, and process parts need Node and fail when used). A
 * component an extension shows (`ctx.ui.custom`, a component widget, a footer or header) becomes a panel. pi-tui's
 * main components map to native-looking views:
 *
 * - SelectList: rows you tap;
 * - SettingsList: rows with their values;
 * - Input and Editor: text fields;
 * - Text and Markdown: styled text;
 * - Loader: a spinner;
 * - Spacer and DynamicBorder: space and dividers;
 * - Container, Box, and the stacks: their children.
 *
 * A tap calls the component's own callback (`onSelect`, `onSubmit`, …). Extensions often wrap their components in an
 * object of their own (`{ render: (w) => container.render(w), handleInput }`); a component whose lines are those of
 * components above shows as them. A component of another kind (or one that overrides `render`) shows the lines it
 * renders. Keys go to the component the extension returned, from a key bar (arrows, Enter, Escape, Tab, and typing)
 * when nothing on screen takes a tap. The view updates whenever the component asks for a render.
 */
import * as piTui from "@earendil-works/pi-tui";
import { Box, CancellableLoader, Container, Editor, HStack, Input, Loader, Markdown, SelectList, SettingsList, Spacer, Text, TruncatedText, VStack } from "@earendil-works/pi-tui";
import { Marked } from "marked";
import { BorderedLoader, DynamicBorder } from "./components.ts";
import { openPanel, type PanelContent, type PanelEvent, type Placement, type ViewNode } from "./panels.ts";

type Component = { render(width: number): string[]; handleInput?(data: string): void; invalidate?(): void; dispose?(): void };
// biome-ignore lint/suspicious/noExplicitAny: components keep their state in fields pi-tui does not expose
type Fields = any;

/** pi-tui as extensions import it. */
export const piTuiModule: Record<string, unknown> = { ...piTui };

/** Key names the app's key bar sends, as the terminal sequences components expect. */
const KEYS: Record<string, string> = {
	up: "\x1b[A",
	down: "\x1b[B",
	right: "\x1b[C",
	left: "\x1b[D",
	enter: "\r",
	escape: "\x1b",
	tab: "\t",
	backspace: "\x7f",
};

/** Columns a component renders at until the app reports its width. */
const DEFAULT_COLUMNS = 44;

/**
 * A component in a panel. `create` receives pi-tui's `TUI` (as far as components use it) and `done`; it resolves with
 * what `done` is called with, or undefined when the user closes the panel.
 */
export function showComponent(
	sessionId: number,
	extension: string,
	placement: Placement,
	title: string | undefined,
	create: (tui: unknown, done: (result: unknown) => void) => Component | Promise<Component>,
	interval = 50,
): { result: Promise<unknown>; close(): void } {
	const view = new ComponentView(interval);
	let finished = false;
	let finish!: (value: unknown) => void;
	const result = new Promise<unknown>((resolve) => (finish = resolve));
	const panel = openPanel(sessionId, extension, placement, title, view.content(), {
		event: (event) => view.handle(event),
		dismissed: () => {
			// As if the user pressed Escape; a component that does not close on it closes with nothing.
			view.key("escape");
			end(undefined);
		},
	});
	const end = (value: unknown) => {
		if (finished) return;
		finished = true;
		panel.close();
		view.dispose();
		finish(value);
	};
	// Spinners ask for a render every frame; only what changed goes to the app.
	let shown = "";
	view.onChange = () => {
		const content = view.content();
		const json = JSON.stringify(content);
		if (json === shown) return;
		shown = json;
		panel.update(content);
	};
	Promise.resolve()
		.then(() => create(view.tui, end))
		.then(
			(component) => {
				if (finished) component?.dispose?.();
				else view.show(component);
			},
			(error: unknown) => {
				console.warn(`[${extension}] ${error instanceof Error ? error.message : String(error)}`);
				end(undefined);
			},
		);
	return { result, close: () => end(undefined) };
}

class ComponentView {
	private root: Component | undefined;
	private columns = DEFAULT_COLUMNS;
	private readonly ids = new WeakMap<object, string>();
	private readonly byId = new Map<string, Component>();
	private nextId = 0;
	/** Whether a component on screen reads keys the views do not send (shown as lines), or takes a tap. */
	private readsKeys = false;
	private tappable = false;
	private scheduled = false;
	onChange?: () => void;

	/** What a component uses of pi-tui's TUI; anything else does nothing. */
	readonly tui: unknown;

	constructor(private readonly interval: number) {
		const view = this;
		const tui = {
			requestRender: () => view.changed(),
			invalidate: () => view.changed(),
			setFocus: () => {},
			terminal: {
				get columns() {
					return view.columns;
				},
				rows: 40,
			},
		};
		this.tui = new Proxy(tui, {
			get: (target, key) => (key in target ? Reflect.get(target, key) : typeof key === "symbol" || key === "then" ? undefined : () => {}),
		});
	}

	show(component: Component): void {
		this.root = component;
		this.changed();
	}

	/** Re-renders soon, at most once per interval (spinners ask for a render every frame). */
	changed(): void {
		if (this.scheduled) return;
		this.scheduled = true;
		setTimeout(() => {
			this.scheduled = false;
			this.onChange?.();
		}, this.interval);
	}

	content(): PanelContent {
		this.byId.clear();
		this.readsKeys = false;
		this.tappable = false;
		const root: ViewNode = this.root ? this.describe(this.root) : { id: "loading", type: "loader", message: "", cancellable: false };
		const keys = this.readsKeys || (!this.tappable && typeof this.root?.handleInput === "function");
		return { kind: "view", root, keys };
	}

	key(name: string): void {
		this.root?.handleInput?.(KEYS[name] ?? name);
		this.changed();
	}

	dispose(): void {
		this.root?.dispose?.();
	}

	handle(event: PanelEvent): void {
		const component = typeof event.id === "string" ? (this.byId.get(event.id) as Fields) : undefined;
		switch (event.type) {
			case "resize":
				this.columns = Math.max(20, Number(event.columns) || DEFAULT_COLUMNS);
				this.root?.invalidate?.();
				break;
			case "key":
				this.key(String(event.key));
				return;
			case "select": {
				if (!(component instanceof SelectList)) break;
				const index = Number(event.index);
				const list = component as Fields;
				list.setSelectedIndex(index);
				// The list's own callback, or Enter for a component that handles keys itself.
				if (list.onSelect) list.onSelect(list.filteredItems[index]);
				else this.root?.handleInput?.(KEYS.enter!);
				break;
			}
			case "setting": {
				if (!(component instanceof SettingsList)) break;
				const settings = component as Fields;
				settings.updateValue(String(event.settingId), String(event.value));
				settings.onChange?.(String(event.settingId), String(event.value));
				break;
			}
			case "change":
				if (component instanceof Input) (component as Fields).setValue(String(event.value));
				else if (component instanceof Editor) (component as Fields).setText(String(event.value));
				break;
			case "submit": {
				const value = String(event.value ?? "");
				if (component instanceof Input) {
					(component as Fields).setValue(value);
					if ((component as Fields).onSubmit) (component as Fields).onSubmit(value);
					else this.root?.handleInput?.(KEYS.enter!);
				} else if (component instanceof Editor) {
					(component as Fields).setText(value);
					if ((component as Fields).onSubmit) (component as Fields).onSubmit(value);
					else this.root?.handleInput?.(KEYS.enter!);
				}
				break;
			}
			case "cancel":
				// A list's or loader's own cancel, else Escape.
				if (component instanceof SelectList && (component as Fields).onCancel) (component as Fields).onCancel();
				else if (typeof (component as Fields)?.handleInput === "function") (component as Component).handleInput!(KEYS.escape!);
				else this.root?.handleInput?.(KEYS.escape!);
				break;
		}
		this.changed();
	}

	/**
	 * A component as views: its own kind of view when one of pi-tui's (and not re-rendered by a subclass), the
	 * components it draws when it only draws those, else its lines.
	 */
	private describe(component: Component): ViewNode {
		let id = this.ids.get(component);
		if (!id) {
			id = String(++this.nextId);
			this.ids.set(component, id);
		}
		this.byId.set(id, component);
		const c = component as Fields;
		const plain = (Class: { prototype: { render: unknown } }) => component instanceof (Class as never) && c.render === Class.prototype.render;

		if (plain(SelectList)) {
			this.tappable = true;
			const items = (c.filteredItems ?? []) as { value: string; label?: string; description?: string }[];
			return { id, type: "select", items: items.map((item) => ({ label: item.label ?? item.value, description: item.description })), selected: c.selectedIndex ?? 0 };
		}
		if (plain(SettingsList)) {
			this.tappable = true;
			const items = (c.items ?? []) as { id: string; label: string; currentValue: string; values?: string[]; description?: string }[];
			return { id, type: "settings", items: items.map((item) => ({ id: item.id, label: item.label, value: item.currentValue, values: item.values, description: item.description })) };
		}
		if (plain(Input)) {
			this.tappable = true;
			return { id, type: "input", value: c.getValue?.() ?? c.value ?? "", placeholder: c.placeholder };
		}
		if (plain(Editor)) {
			this.tappable = true;
			return { id, type: "editor", value: c.getText?.() ?? "" };
		}
		if (plain(Markdown)) return { id, type: "html", html: markdown.parse(String(c.text ?? ""), { async: false }) as string, markdown: true };
		if (plain(CancellableLoader) || plain(Loader) || plain(BorderedLoader)) {
			const cancellable = !plain(Loader);
			this.tappable ||= cancellable;
			return { id, type: "loader", message: ansiToHtml(String(c.message ?? "")), cancellable };
		}
		if (plain(DynamicBorder)) return { id, type: "divider" };
		if (plain(Text) || plain(TruncatedText)) return { id, type: "html", html: ansiToHtml(String(c.text ?? "")) };
		if (plain(Spacer)) return { id, type: "spacer", lines: c.lines ?? 1 };
		if (plain(HStack) || plain(VStack) || plain(Box) || plain(Container)) {
			const children = (c.children ?? []) as Component[];
			return { id, type: "stack", direction: component instanceof HStack ? "horizontal" : "vertical", children: children.map((child) => this.describe(child)) };
		}
		const drawn = draws(component, this.columns);
		if (drawn.components) {
			const children = drawn.components.map((child) => this.describe(child));
			return children.length === 1 ? children[0]! : { id, type: "stack", direction: "vertical", children };
		}
		// Another component: its lines, and keys for it when it reads them (the root's go to the root anyway).
		const input = typeof c.handleInput === "function";
		if (input && component !== this.root) this.readsKeys = true;
		return { id, type: "lines", html: drawn.lines.map(ansiToHtml), input };
	}
}

/** The components drawn as views of their own kind. */
const VIEWS: { prototype: { render(width: number): string[] } }[] = [
	SelectList, SettingsList, Input, Editor, Markdown, CancellableLoader, Loader, Text, TruncatedText, Spacer, HStack, VStack, Box, Container, DynamicBorder, BorderedLoader,
];

/**
 * What a component draws: its lines, and the components of the kinds above whose lines they are, when they are
 * nothing else (an extension's wrapper around its container, say). Found by watching which of those render directly
 * from its `render`, after `invalidate` (so caches render again).
 */
function draws(component: Component, width: number): { lines: string[]; components?: Component[] } {
	const calls: { component: Component; lines: string[] }[] = [];
	let depth = 0;
	const restore: (() => void)[] = [];
	for (const View of VIEWS) {
		const prototype = View.prototype;
		if (!Object.hasOwn(prototype, "render")) continue;
		const render = prototype.render;
		prototype.render = function (this: Component, columns: number) {
			depth++;
			try {
				const lines = render.call(this, columns);
				if (depth === 1) calls.push({ component: this, lines });
				return lines;
			} finally {
				depth--;
			}
		};
		restore.push(() => {
			prototype.render = render;
		});
	}
	let lines: string[];
	try {
		component.invalidate?.();
		lines = component.render(width);
	} catch (error) {
		return { lines: [`(${error instanceof Error ? error.message : String(error)})`] };
	} finally {
		for (const undo of restore) undo();
	}
	const drawn = calls.flatMap((call) => call.lines);
	const only = calls.length > 0 && calls.every((call) => call.component !== component) && drawn.length === lines.length && drawn.every((line, index) => line === lines[index]);
	return only ? { lines, components: calls.map((call) => call.component) } : { lines };
}

/** Markdown as HTML for a panel: raw HTML shows as text, and links only open web pages. */
const markdown = new Marked({
	renderer: {
		html: ({ text }) => escapeHtml(text),
		link({ href, tokens }) {
			const text = this.parser.parseInline(tokens);
			return /^(https?:|mailto:)/i.test(href) ? `<a href="${escapeHtml(href)}">${text}</a>` : text;
		},
	},
});

// ---- ANSI ----

const BASIC = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5"];
const BRIGHT = ["#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"];

/** Terminal text as HTML: escaped, with its SGR styles (colors, bold, italic, …) as spans; other sequences dropped. */
export function ansiToHtml(text: string): string {
	const withoutOther = text
		.replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "")
		.replace(/\x1b\[[0-9;?]*[A-Za-ln-z]/g, "")
		.replace(/\x1b[^[\]]/g, "");
	let html = "";
	let style: Record<string, string> = {};
	let open = false;
	let last = 0;
	const flush = (chunk: string) => {
		if (!chunk) return;
		html += escapeHtml(chunk);
	};
	const pattern = /\x1b\[([0-9;]*)m/g;
	for (let match = pattern.exec(withoutOther); match; match = pattern.exec(withoutOther)) {
		flush(withoutOther.slice(last, match.index));
		last = match.index + match[0].length;
		style = applySgr(style, match[1] ?? "");
		if (open) html += "</span>";
		const css = Object.entries(style)
			.map(([key, value]) => `${key}:${value}`)
			.join(";");
		open = css.length > 0;
		if (open) html += `<span style="${css}">`;
	}
	flush(withoutOther.slice(last));
	if (open) html += "</span>";
	return html;
}

function applySgr(current: Record<string, string>, parameters: string): Record<string, string> {
	const style = { ...current };
	const codes = parameters === "" ? [0] : parameters.split(";").map(Number);
	for (let index = 0; index < codes.length; index++) {
		const code = codes[index]!;
		if (code === 0) for (const key of Object.keys(style)) delete style[key];
		else if (code === 1) style["font-weight"] = "600";
		else if (code === 2) style.opacity = "0.6";
		else if (code === 3) style["font-style"] = "italic";
		else if (code === 4) style["text-decoration"] = "underline";
		else if (code === 9) style["text-decoration"] = "line-through";
		else if (code === 22) {
			delete style["font-weight"];
			delete style.opacity;
		} else if (code === 23) delete style["font-style"];
		else if (code === 24 || code === 29) delete style["text-decoration"];
		else if (code >= 30 && code <= 37) style.color = BASIC[code - 30]!;
		else if (code >= 90 && code <= 97) style.color = BRIGHT[code - 90]!;
		else if (code >= 40 && code <= 47) style.background = BASIC[code - 40]!;
		else if (code >= 100 && code <= 107) style.background = BRIGHT[code - 100]!;
		else if (code === 39) delete style.color;
		else if (code === 49) delete style.background;
		else if (code === 38 || code === 48) {
			const key = code === 38 ? "color" : "background";
			if (codes[index + 1] === 5) {
				style[key] = color256(codes[index + 2] ?? 0);
				index += 2;
			} else if (codes[index + 1] === 2) {
				style[key] = `rgb(${codes[index + 2] ?? 0},${codes[index + 3] ?? 0},${codes[index + 4] ?? 0})`;
				index += 4;
			}
		}
	}
	return style;
}

function color256(index: number): string {
	if (index < 8) return BASIC[index]!;
	if (index < 16) return BRIGHT[index - 8]!;
	if (index >= 232) {
		const level = 8 + (index - 232) * 10;
		return `rgb(${level},${level},${level})`;
	}
	const cube = index - 16;
	const channel = (value: number) => (value === 0 ? 0 : 55 + value * 40);
	return `rgb(${channel(Math.floor(cube / 36))},${channel(Math.floor(cube / 6) % 6)},${channel(cube % 6)})`;
}

function escapeHtml(text: string): string {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
