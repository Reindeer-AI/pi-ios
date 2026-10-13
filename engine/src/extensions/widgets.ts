/**
 * Home Screen widgets (iOS): an extension draws its app's widget as a layout of native views (`pi.widget.update`),
 * which the app saves for its widget extension (HomeScreenWidgets.swift, PiWidgetLayout). The widget shows it as a
 * snapshot, refreshed when the extension draws it again (and at its timeline's dates); no extension code runs in the
 * widget. A tap opens the app full screen; a tap area (`open`) also gives the app's `onWidgetOpen` its target.
 *
 * The app also hears which apps each extension registers (`publishApps`), for the widget's list of apps, and forgets
 * them when the extension is removed.
 */
import { request } from "../bridge.ts";

const SIZES = ["small", "medium", "large", "extraLarge", "circular", "rectangular", "inline"] as const;
const CONTAINERS = new Set(["vstack", "hstack", "zstack"]);
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
};

/** An extension's scope as the app keeps it: "default" (for every session) or "session:<id>" (one session's own). */
export function scopeOf(registryName: string): { extension: string; scope: string } {
	const session = /^session:(\d+):(.*)$/.exec(registryName);
	if (session) return { extension: session[2]!, scope: `session:${session[1]}` };
	return { extension: registryName.replace(/^default:/, ""), scope: "default" };
}

function widgetId(extension: string, app: string, scope: string): string {
	return scope.startsWith("session:") ? `${extension}/${app}@${scope.slice("session:".length)}` : `${extension}/${app}`;
}

/** `pi.widget`: the extension's apps' widgets. `appNames`: the apps it registered, first first. */
export function widgetApi(registryName: string, appNames: () => string[]) {
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
			if (JSON.stringify(content).length > MAX_SIZE) throw new Error(`pi.widget: the widget is over ${MAX_SIZE / 1024 / 1024} MB; use smaller images`);
			const result = await request<{ saved: boolean } | null>("widget", "update", { id: widgetId(extension, app, scope), content });
			return result?.saved ?? false;
		},
		/** Back to the app's icon and name. */
		clear: async (app?: string): Promise<void> => {
			await request("widget", "clear", { id: widgetId(extension, pick(app), scope) });
		},
	};
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
	return { version: 1, updatedAt: Date.now(), entries };
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
