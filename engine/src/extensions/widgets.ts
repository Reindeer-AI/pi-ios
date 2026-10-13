/**
 * Home Screen widgets (iOS): an extension draws its app's widget as a layout of native views (`pi.widget.update`),
 * which the app saves for its widget extension (HomeScreenWidgets.swift, PiWidgetLayout). The widget shows it as a
 * snapshot, refreshed when the extension draws it again (and at its timeline's dates); no extension code runs in the
 * widget. A tap opens the app full screen; a tap area (`open`) also gives the app's `onWidgetOpen` its target.
 *
 * Buttons act without opening pi: a button's `action` runs the extension's handler (`pi.widget.onAction`), which iOS
 * runs in pi's process in the background, starting the engine if it must (`runAction`); the handler draws the widget
 * again. A button's `show` switches the widget to another of its looks (`views`) in the widget itself, with no code.
 *
 * The app also hears which apps each extension registers (`publishApps`), for the widget's list of apps, and forgets
 * them when the extension is removed.
 */
import { request } from "../bridge.ts";

const SIZES = ["small", "medium", "large", "extraLarge", "circular", "rectangular", "inline"] as const;
const CONTAINERS = new Set(["vstack", "hstack", "zstack", "button"]);
const TYPES = new Set([...CONTAINERS, "text", "date", "symbol", "image", "spacer", "divider", "gauge", "progress", "chart"]);
/** As PiWidgetLayout draws them (deeper or more is left out there). */
const MAX_NODES = 600;
const MAX_DEPTH = 24;
const MAX_TIMELINE = 60;
/** Images included (data: URLs); the app keeps the widget itself to 512 KB once it has saved them. */
const MAX_SIZE = 16 * 1024 * 1024;

type Node = Record<string, unknown>;
type Fill = unknown;

/** One look of the widget: a layout for every size (`layout`) and/or one per size. */
export type WidgetLook = {
	layout?: Node;
	small?: Node;
	medium?: Node;
	large?: Node;
	extraLarge?: Node;
	circular?: Node;
	rectangular?: Node;
	inline?: Node;
	/** A color or gradient behind the layout; the system's when left out. */
	background?: Fill;
	/** false: the layout reaches the widget's edges instead of sitting inside the system's margins. */
	margins?: boolean;
};

export type WidgetSpec = WidgetLook & {
	/** The app the widget opens (its name); the extension's only app when left out. */
	app?: string;
	/** Later looks, each from its date on (a schedule, a countdown's end). */
	timeline?: (WidgetLook & { at: Date | number | string })[];
	/** Other looks a button switches to (`show: name`; `show: null` back to the main one), by name. */
	views?: Record<string, WidgetLook>;
};

/** What a widget button's `action` runs: in the background, without a session, within `timeoutMs`; honor `signal`. */
export type WidgetActionHandler = (event: { app: string; value: unknown; signal: AbortSignal }) => unknown;

/** An extension's scope as the app keeps it: "default" (for every session) or "session:<id>" (one session's own). */
export function scopeOf(registryName: string): { extension: string; scope: string } {
	const session = /^session:(\d+):(.*)$/.exec(registryName);
	if (session) return { extension: session[2]!, scope: `session:${session[1]}` };
	return { extension: registryName.replace(/^default:/, ""), scope: "default" };
}

function widgetId(extension: string, app: string, scope: string): string {
	return scope.startsWith("session:") ? `${extension}/${app}@${scope.slice("session:".length)}` : `${extension}/${app}`;
}

/** `pi.widget`: the extension's apps' widgets. `appNames`: the apps it registered, first first; `actions`: its
 * instance's button handlers. */
export function widgetApi(registryName: string, appNames: () => string[], actions: Map<string, WidgetActionHandler>) {
	const { extension, scope } = scopeOf(registryName);
	const pick = (app: unknown): string => {
		const names = appNames();
		if (app !== undefined) {
			if (typeof app !== "string" || !names.includes(app)) {
				throw new Error(`pi.widget: ${extension} has no app named ${JSON.stringify(app)}${names.length ? ` (its apps: ${names.join(", ")})` : ""}`);
			}
			return app;
		}
		if (names.length === 0) throw new Error("pi.widget: a widget opens an app; register one first (pi.registerApp)");
		if (names.length > 1) throw new Error(`pi.widget: ${extension} has several apps; name the widget's app ({ app: "${names[0]}", … })`);
		return names[0]!;
	};
	return {
		/** Draws the app's widget (every size the user put on the Home Screen); resolves to false in a build without widgets. */
		update: async (spec: WidgetSpec): Promise<boolean> => {
			const app = pick(spec?.app);
			const content = normalize(spec);
			for (const action of actionsIn(content)) {
				if (!actions.has(action)) throw new Error(`pi.widget: a button's action "${action}" has no handler: pi.widget.onAction("${action}", async ({ signal }) => { … })`);
			}
			if (JSON.stringify(content).length > MAX_SIZE) throw new Error(`pi.widget: the widget is over ${MAX_SIZE / 1024 / 1024} MB; use smaller images`);
			const result = await request<{ saved: boolean } | null>("widget", "update", { id: widgetId(extension, app, scope), content });
			return result?.saved ?? false;
		},
		/** Back to the app's icon and name. */
		clear: async (app?: string): Promise<void> => {
			await request("widget", "clear", { id: widgetId(extension, pick(app), scope) });
		},
		/** What a button's `action: name` runs (its `value` too); it draws the widget again with update. */
		onAction: (name: string, handler: WidgetActionHandler): void => {
			if (typeof name !== "string" || !name || typeof handler !== "function") throw new Error("pi.widget.onAction needs a name and a function");
			actions.set(name, handler);
		},
	};
}

/** Runs a button's handler within `timeoutMs` (iOS gives a widget's button little time); its signal aborts then. */
export async function runAction(handler: WidgetActionHandler, app: string, value: unknown, timeoutMs: number): Promise<void> {
	const controller = new AbortController();
	const timedOut = new Promise<never>((_, reject) => {
		controller.signal.addEventListener("abort", () => reject(new Error(`didn't finish in ${Math.round(timeoutMs / 1000)} seconds`)));
	});
	const timer = setTimeout(() => controller.abort(), timeoutMs);
	try {
		await Promise.race([Promise.resolve(handler({ app, value, signal: controller.signal })), timedOut]);
	} finally {
		clearTimeout(timer);
	}
}

/** An app's widget id, as its extension, app, and session (for a session's own extension). */
export function parseWidgetId(id: string): { extension: string; app: string; sessionId?: number } {
	const at = /^(.*)@(\d+)$/.exec(id);
	const key = at ? at[1]! : id;
	const slash = key.lastIndexOf("/");
	return { extension: key.slice(0, slash), app: key.slice(slash + 1), ...(at ? { sessionId: Number(at[2]) } : {}) };
}

function actionsIn(value: unknown, found = new Set<string>()): Set<string> {
	if (Array.isArray(value)) for (const each of value) actionsIn(each, found);
	else if (value && typeof value === "object") {
		const node = value as Node;
		if (node.type === "button" && typeof node.action === "string") found.add(node.action);
		for (const each of Object.values(node)) actionsIn(each, found);
	}
	return found;
}

/** Tells the app the apps an extension registers, each time it loads. */
export function publishApps(registryName: string, apps: { name: string; title: string; icon: string | null; description: string | null }[]): void {
	const { extension, scope } = scopeOf(registryName);
	void request("widget", "apps", { extension, scope, apps }).catch((error: unknown) => console.warn(`widget apps of ${extension}: ${String(error)}`));
}

/** An extension removed: the app forgets its apps and their widgets. */
export function forgetApps(registryName: string): void {
	const { extension, scope } = scopeOf(registryName);
	void request("widget", "forget", { extension, scope }).catch((error: unknown) => console.warn(`widget apps of ${extension}: ${String(error)}`));
}

/** How to draw a widget: the environment guide's `widgets` topic. */
export const WIDGETS_GUIDE = `Home Screen widgets for your extensions' apps (iOS). The user puts an app on the Home Screen or Lock Screen as a widget (the app's menu → Add to Home Screen…, or Edit → Add Widget → pi app); tapping it opens just that app, full screen. An app without a widget of its own shows its icon and title.
- Draw it with await pi.widget.update({ app?, layout, small?, medium?, large?, extraLarge?, circular?, rectangular?, inline?, background?, margins?, timeline?, views? }): native views described as JSON, checked when you call it (an error says what is wrong and where). app is the app's name, needed only when the extension has several; layout is for every size; small, medium, large and extraLarge are the Home Screen's sizes, circular, rectangular and inline the Lock Screen's. background is a fill; margins: false lets the layout reach the edges (then pad it yourself). pi.widget.clear(app?) goes back to the icon and title. update resolves to false in a build of pi without widgets.
- It is a snapshot: iOS shows what you drew until you draw it again. Draw it whenever what it shows changes (from a command, the app's onMessage, a tool, a background check, or a button's action), not on a timer. No code runs in the widget, but a date node with style "relative" or "timer" stays live, and timeline: [{ at: Date, layout, … }] adds later looks that show on time without pi running.
- Buttons: { type: "button", action: "refresh", value?: any JSON, children } runs your handler without opening pi: pi.widget.onAction("refresh", async ({ app, value, signal }) => { …; await pi.widget.update({ … }) }). iOS runs it in pi in the background (starting pi's engine if it isn't running, a second or two) and gives it about 20 seconds: keep it short, pass signal to fetch, and draw the widget again at the end; if it fails, the widget keeps its look. Register handlers when the extension loads; an update whose button names an action without a handler is refused. { type: "button", show: "details", children } switches the widget to another look, views: { details: { layout, … } }, at once and with no code; show: null goes back to the main look. All of that app's widgets switch together, and drawing the widget again keeps the view shown if it still exists. loading: true on a node shows a loading effect on it while an action runs. A button's children are laid out in a row (spacing?, alignment?).
- Tap areas: open: "target" on any node opens the app and calls its registerApp onWidgetOpen(target, app), to show that item; the rest of the widget opens the app as it is.
- Nodes: { type: "vstack" | "hstack" | "zstack", children, spacing?, alignment? ("leading", "trailing", "top", "bottom", "topLeading", …) }; { type: "text", text, font? ("largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption", "caption2"), size?, weight? ("light", "medium", "semibold", "bold", "heavy", …), design? ("rounded", "monospaced", "serif"), lineLimit?, minScale?, align?, markdown?, monospacedDigit?, uppercase?, italic? }; { type: "date", date (a Date, ms, or an ISO string), style: "time" | "date" | "relative" | "timer" | "offset" }; { type: "symbol", name (an SF Symbol), size?, mode? ("hierarchical", "palette" with colors, "multicolor"), variable? (0…1) }; { type: "image", src (a data: or https: URL; pi stores it at most 1000 pixels, 24 per widget), fit? ("fill" | "fit") }; { type: "gauge", value, min?, max?, label?, valueLabel?, style? ("circular", "linear", "circularCapacity", "linearCapacity") }; { type: "progress", value, total?, label? }; { type: "chart", kind: "line" | "bar" | "area", values: numbers, min?, max?, axes? }; { type: "button", … }; { type: "spacer", min? }; { type: "divider" }. Children that are false, null or undefined are skipped (ok && { … }).
- Any node also takes color, tint (gauges and progress), padding (a number, or { horizontal, vertical, top, leading, bottom, trailing }), frame ({ width, height, minWidth, maxWidth: "infinity", minHeight, maxHeight, alignment }), background (a fill), cornerRadius, border ({ color, width }), opacity, accent: true (tinted Home Screens color it), accessibility (what VoiceOver says; give a button that shows only a symbol one), and open. Text properties set on a stack apply to what it holds.
- Colors: "primary", "secondary", "accent", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "white", "black", "#RRGGBB" or "#RRGGBBAA", or { light, dark }. A fill is a color or { gradient: "linear" | "radial", colors, from?, to? } (from and to: "top", "bottomTrailing", …).
- Sizes are about 170×170 points (small), 364×170 (medium) and 364×382 (large) on a phone: keep it glanceable, a few lines of large type, the most important thing biggest.`;

// ---- checking a widget ----

/** What the app stores: `{ version, updatedAt, entries: [{ date, layouts, background, margins }] }`, dates in ms. */
export function normalize(spec: WidgetSpec) {
	if (!spec || typeof spec !== "object") throw new Error('pi.widget.update needs a widget: { layout: { type: "text", text: "Hi" } }');
	const budget = { nodes: 0 };
	const entries = [look(spec, "widget", budget, null)];
	if (spec.timeline !== undefined) {
		if (!Array.isArray(spec.timeline)) throw new Error("widget.timeline must be an array of { at, layout, … }");
		if (spec.timeline.length > MAX_TIMELINE) throw new Error(`widget.timeline has over ${MAX_TIMELINE} entries`);
		spec.timeline.forEach((entry, index) => {
			const path = `widget.timeline[${index}]`;
			if (!entry || typeof entry !== "object") throw new Error(`${path} must be { at, layout, … }`);
			entries.push(look(entry, path, budget, dateOf(entry.at, `${path}.at`)));
		});
	}
	const views: Record<string, ReturnType<typeof look>> = {};
	if (spec.views !== undefined) {
		if (!spec.views || typeof spec.views !== "object" || Array.isArray(spec.views)) throw new Error("widget.views must be { name: { layout, … } }");
		for (const [name, view] of Object.entries(spec.views)) {
			if (!view || typeof view !== "object") throw new Error(`widget.views.${name} must be { layout, … }`);
			views[name] = look(view, `widget.views.${name}`, budget, null);
		}
	}
	return { version: 1, updatedAt: Date.now(), entries, views };
}

function look(source: WidgetLook, path: string, budget: { nodes: number }, date: number | null) {
	const layouts: Record<string, Node> = {};
	if (source.layout !== undefined) layouts.default = node(source.layout, `${path}.layout`, 0, budget);
	for (const size of SIZES) if (source[size] !== undefined) layouts[size] = node(source[size], `${path}.${size}`, 0, budget);
	if (Object.keys(layouts).length === 0) throw new Error(`${path} has no layout: give layout (for every size), or small, medium, large, …`);
	return { date, layouts, background: source.background === undefined ? null : json(source.background, `${path}.background`), margins: source.margins !== false };
}

function node(value: unknown, path: string, depth: number, budget: { nodes: number }): Node {
	if (!value || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`${path}: a node is an object with a type, e.g. { type: "text", text: "Hi" }`);
	}
	const source = value as Node;
	const type = source.type;
	if (typeof type !== "string" || !TYPES.has(type)) throw new Error(`${path}: unknown type ${JSON.stringify(type)} (one of ${[...TYPES].join(", ")})`);
	if (++budget.nodes > MAX_NODES) throw new Error(`the widget has over ${MAX_NODES} nodes`);
	if (depth >= MAX_DEPTH) throw new Error(`${path}: nested deeper than ${MAX_DEPTH}`);
	const out: Node = {};
	for (const [key, raw] of Object.entries(source)) {
		if (raw === undefined || key === "children") continue;
		out[key] = key === "date" ? dateOf(raw, `${path}.date`) : json(raw, `${path}.${key}`);
	}
	if (CONTAINERS.has(type)) {
		const children = source.children ?? [];
		if (!Array.isArray(children)) throw new Error(`${path}.children must be an array`);
		// Left-out children (`ok && { … }`) are skipped.
		out.children = children
			.map((child, index) => ({ child, index }))
			.filter(({ child }) => child !== null && child !== undefined && child !== false)
			.map(({ child, index }) => node(child, `${path}.children[${index}]`, depth + 1, budget));
	} else if (source.children !== undefined) {
		throw new Error(`${path}: a ${type} has no children (put them in a vstack, hstack or zstack)`);
	}
	switch (type) {
		case "text":
			if (out.text === undefined || out.text === null) throw new Error(`${path}: a text needs text`);
			out.text = String(out.text);
			break;
		case "symbol":
			if (typeof out.name !== "string") throw new Error(`${path}: a symbol needs name, an SF Symbol ("airplane", "cloud.sun.fill", …)`);
			break;
		case "image":
			if (typeof out.src !== "string" || !/^(data:|https:)/.test(out.src)) throw new Error(`${path}: an image needs src, a data: or https: URL`);
			break;
		case "date":
			if (out.date === undefined) throw new Error(`${path}: a date needs date (a Date, ms, or an ISO string)`);
			break;
		case "gauge":
		case "progress":
			if (typeof out.value !== "number" || !Number.isFinite(out.value)) throw new Error(`${path}: a ${type} needs value, a number`);
			break;
		case "chart":
			if (!Array.isArray(out.values) || !out.values.every((each) => typeof each === "number" && Number.isFinite(each))) {
				throw new Error(`${path}: a chart needs values, an array of numbers`);
			}
			break;
		case "button":
			if ((out.children as unknown[]).length === 0) throw new Error(`${path}: a button needs children, what it shows`);
			if (typeof out.action === "string" ? "show" in out : !("show" in out) || (out.show !== null && typeof out.show !== "string")) {
				throw new Error(`${path}: a button needs action (a handler's name, pi.widget.onAction) or show (a view's name, or null for the main look)`);
			}
			break;
	}
	return out;
}

function dateOf(value: unknown, path: string): number {
	const time = value instanceof Date ? value.getTime() : typeof value === "number" ? value : typeof value === "string" ? Date.parse(value) : Number.NaN;
	if (!Number.isFinite(time)) throw new Error(`${path}: not a date (a Date, ms since 1970, or an ISO string)`);
	return time;
}

function json(value: unknown, path: string): unknown {
	try {
		return JSON.parse(JSON.stringify(value)) as unknown;
	} catch {
		throw new Error(`${path}: not JSON`);
	}
}
