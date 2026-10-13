/**
 * Live Activities (iOS): something in progress (a flight, a delivery, a timer, a build) on the Lock Screen and in the
 * Dynamic Island, which an extension starts, updates while it runs, and ends (`pi.liveActivity`). It draws them with
 * the native views of its widgets (widgets.ts); the app shows them with ActivityKit (LiveActivities.swift) and its widget
 * extension draws them. A tap opens the extension's app full screen; a button runs one of its actions
 * (`pi.widget.onAction`) in pi, in the background.
 */
import { request } from "../bridge.ts";
import { checkActions, checkNode, parseWidgetId, pickApp, scopeOf, type WidgetActionHandler, widgetId } from "./widgets.ts";

type Node = Record<string, unknown>;

export type ActivitySpec = {
	/** The app a tap opens (its name); the extension's only app when left out. */
	app?: string;
	/** The Lock Screen's view (and the expanded Dynamic Island's, without expanded). */
	lockScreen: Node;
	/** The Dynamic Island beside the camera: left (the app's icon when left out) and right. */
	compactLeading?: Node;
	compactTrailing?: Node;
	/** The Dynamic Island when another app's activity shares it: a small circle (the app's icon when left out). */
	minimal?: Node;
	/** The Dynamic Island expanded (touch and hold): its regions. */
	expanded?: { leading?: Node; trailing?: Node; center?: Node; bottom?: Node };
	/** Behind the Lock Screen's view: a color or gradient; the system's when left out. */
	background?: unknown;
	/** The Dynamic Island's keyline, and its default icons' color. */
	tint?: unknown;
	/** false: the Lock Screen's view reaches the edges. */
	margins?: boolean;
	/** When what it shows is out of date (iOS marks it so). */
	staleAt?: Date | number | string;
	/** Which of the app's activities iOS shows first when there are several (higher first). */
	relevance?: number;
};

const REGIONS = ["leading", "trailing", "center", "bottom"] as const;

/** `pi.liveActivity`: the extension's Live Activities. `actions`: its instance's button handlers. */
export function liveActivityApi(registryName: string, appNames: () => string[], actions: Map<string, WidgetActionHandler>) {
	const { extension, scope } = scopeOf(registryName);
	const handle = (id: string, app: string) => ({
		id,
		app,
		/** Draws it again (all of it, as start); `alert` lights the screen and expands the Dynamic Island. */
		update: async (spec: ActivitySpec, options: { alert?: { title: string; body: string } } = {}): Promise<void> => {
			await request("activity", "update", { requester: extension, id, ...check(spec), ...(options.alert ? { alert: options.alert } : {}) });
		},
		/** Ends it: with `final`, its last look; `dismiss` "now", a date, or (by default) when iOS decides, up to four hours. */
		end: async (options: { final?: ActivitySpec; dismiss?: "now" | Date | number } = {}): Promise<void> => {
			const dismiss = options.dismiss === "now" ? "now" : options.dismiss === undefined ? undefined : new Date(options.dismiss).getTime();
			await request("activity", "end", { requester: extension, id, ...(options.final ? check(options.final) : {}), ...(dismiss === undefined ? {} : { dismiss }) });
		},
	});
	const check = (spec: ActivitySpec) => {
		const checked = normalizeActivity(spec);
		checkActions("pi.liveActivity", checked.content, actions);
		return checked;
	};
	return {
		/** Starts one (only while pi is open, or from a widget's or Live Activity's button); null when pi can't show one. */
		start: async (spec: ActivitySpec) => {
			const app = pickApp("pi.liveActivity", extension, appNames(), spec?.app);
			const started = await request<{ id: string } | null>("activity", "start", { requester: extension, app: widgetId(extension, app, scope), ...check(spec) });
			return started ? handle(started.id, app) : null;
		},
		/** Its activities iOS still shows (after a relaunch too). */
		list: async () => {
			const listed = await request<{ id: string; app: string }[]>("activity", "list", { requester: extension });
			return listed.map(({ id, app }) => handle(id, parseWidgetId(app).app));
		},
	};
}

/** What the app stores, and ActivityKit's stale date and relevance. */
export function normalizeActivity(spec: ActivitySpec) {
	if (!spec || typeof spec !== "object") throw new Error("pi.liveActivity needs its views: { lockScreen: { type: \"text\", text: \"…\" }, … }");
	if (spec.lockScreen === undefined) throw new Error("pi.liveActivity: lockScreen is required (the Lock Screen's view)");
	const budget = { nodes: 0 };
	const view = (value: unknown, path: string) => (value === undefined ? undefined : checkNode(value, path, budget));
	const expanded: Record<string, Node> = {};
	for (const region of REGIONS) {
		const checked = view(spec.expanded?.[region], `activity.expanded.${region}`);
		if (checked) expanded[region] = checked;
	}
	const content = {
		version: 1,
		lockScreen: view(spec.lockScreen, "activity.lockScreen"),
		compactLeading: view(spec.compactLeading, "activity.compactLeading"),
		compactTrailing: view(spec.compactTrailing, "activity.compactTrailing"),
		minimal: view(spec.minimal, "activity.minimal"),
		expanded,
		background: spec.background ?? null,
		tint: spec.tint ?? null,
		margins: spec.margins !== false,
	};
	throwOnShow(content);
	const staleAt = spec.staleAt === undefined ? undefined : new Date(spec.staleAt).getTime();
	if (staleAt !== undefined && !Number.isFinite(staleAt)) throw new Error("pi.liveActivity: staleAt is not a date");
	return { content: JSON.parse(JSON.stringify(content)) as unknown, ...(staleAt === undefined ? {} : { staleAt }), ...(typeof spec.relevance === "number" ? { relevance: spec.relevance } : {}) };
}

/** A Live Activity has one look: its buttons run actions; `show` is for widgets. */
function throwOnShow(value: unknown): void {
	if (Array.isArray(value)) value.forEach(throwOnShow);
	else if (value && typeof value === "object") {
		const node = value as Node;
		if (node.type === "button" && "show" in node) throw new Error("pi.liveActivity: its buttons run actions (action); show switches a widget's look, not a Live Activity's");
		Object.values(node).forEach(throwOnShow);
	}
}
