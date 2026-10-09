/**
 * Session apps: an extension's page that lives with a session (`pi.registerApp`, `pi.apps`, and
 * `ctx.ui.panel({ persistent: true })`), the way an app lives on the phone.
 *
 * An app opens in a sheet like a panel, but closing the sheet minimizes it: it waits in the session's dock above the
 * message box, its page still running, and opens again as it was. Only Close (in the sheet's menu, or holding its dock
 * entry) ends it. Its record (title, icon, badge) and the state its page (`pi.state`) or extension (`app.setState`)
 * saves live in the session (`SessionAppsDoc`), so after a relaunch the dock is the same and an app opens again from
 * its saved state: the extension's `render` draws its page anew; one that was on screen opens again when the app shows
 * its session (`open`, kept per session). A shared app (`shared: true`) keeps one record and one
 * state for every session (`SharedAppsDoc`, on the root conversation), and shows in every session's dock; each session
 * still draws its own page.
 *
 * The app keeps a page only while it is on screen or minimized recently: it may unload a minimized page to save
 * memory (`panel.suspended`), and the app opens again by drawing it.
 */
import type { JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type ConversationId, defineDoc, type Harness } from "@earendil-works/pi-durable";
import { emit } from "../bridge.ts";
import { openPanel, type Panel } from "./panels.ts";

export type AppDefinition = {
	/** Unique among the extension's apps. */
	name: string;
	title?: string;
	/** An SF Symbol name, for the dock and the launcher ("airplane", "envelope", …). */
	icon?: string;
	/** What it is for: the launcher and the agent (`apps_list`) show it. */
	description?: string;
	/** One app for every session: one dock entry and one saved state; each session draws its own page. */
	shared?: boolean;
	/** The page (a complete HTML document), drawn when the app opens and when it opens again after a relaunch. */
	render: (app: AppHandle) => string | Promise<string>;
	/** What the page sent with `pi.post(data)`. */
	onMessage?: (data: unknown, app: AppHandle) => unknown;
	onOpen?: (app: AppHandle) => unknown;
	onMinimize?: (app: AppHandle) => unknown;
	onRestore?: (app: AppHandle) => unknown;
	onClose?: (app: AppHandle) => unknown;
};

/** A running app, as its extension holds it. */
export type AppHandle = {
	readonly name: string;
	readonly sessionId: number;
	/** What the page (`pi.state.set`) or the extension saved last, or null. */
	readonly state: JsonValue | null;
	/** Saves the app's state (JSON) and gives it to the page (`pi.state.onChange`). */
	setState(value: unknown): void;
	/** Sends the page a message (`pi.onMessage`); dropped while no page runs (it draws from the state when it opens). */
	post(data: unknown): void;
	/** Draws the page again with `render`. */
	refresh(): Promise<void>;
	/** A short text on its dock entry (a count); undefined or "" clears it. */
	setBadge(badge: string | number | undefined): void;
	setTitle(title: string): void;
	/** Puts it on screen. */
	show(): Promise<void>;
	/** Takes it off screen, to the dock. */
	minimize(): void;
	/** Ends it: off the dock; its saved state stays for the next time it opens. */
	close(): void;
	/** On screen. */
	readonly visible: boolean;
	/** Not closed. */
	readonly running: boolean;
	/** Resolves when the app is closed. */
	readonly closed: Promise<void>;
	/** The session's `ctx.ui` (notify, setEditorText, …), for what the page's messages lead to. */
	readonly ui: unknown;
};

/** An app in a session's dock, as the app shows it. */
export type DockApp = {
	key: string;
	extension: string;
	name: string;
	title: string;
	icon: string | null;
	badge: string | null;
	shared: boolean;
	/** Its page while one runs (the panel to show again), else null: opening draws it. */
	panelId: string | null;
	visible: boolean;
	/** On screen, or (with no page, after a relaunch) on screen when the app last showed it: opens again with its session. */
	open: boolean;
};

/** An app the session's extensions offer, for the launcher and `apps_list`. */
export type CatalogApp = { key: string; extension: string; name: string; title: string; icon: string | null; description: string | null; shared: boolean; running: boolean };

type AppRecord = { extension: string; name: string; title: string; icon: string | null; badge: string | null; openedAt: number };
/** `open` (in a session's doc only): the apps on screen in the session (a shared app's too), to open again after a relaunch. */
type AppsDoc = { apps: Record<string, AppRecord>; states: Record<string, JsonValue>; open?: Record<string, boolean> };

/** A session's running apps, and the state each app saved (kept after it closes). */
export const SessionAppsDoc = defineDoc<AppsDoc>({
	kind: "pimobile.apps.session",
	version: 1,
	scope: "conversation",
	history: "latest",
	// A fork has the session's apps, as it has its workspace.
	fork: "current",
	initial: () => ({ apps: {}, states: {} }),
});

/** Shared apps (in every session's dock) and their state, on the root conversation. */
export const SharedAppsDoc = defineDoc<AppsDoc>({
	kind: "pimobile.apps.shared",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ apps: {}, states: {} }),
});

export type AppsHost = { harness(): Harness; rootId(): ConversationId };

let host: AppsHost | undefined;

/** The engine apps keep their records in (set when the store opens). */
export function configureApps(next: AppsHost): void {
	host = next;
	// Pages belonged to the engine that opened them.
	live.clear();
}

export const appKey = (extension: string, name: string) => `${extension}/${name}`;

type Live = {
	readonly sessionId: number;
	readonly key: string;
	readonly extension: string;
	readonly definition: AppDefinition;
	readonly ui: unknown;
	/** Recorded in the session (false: an ad hoc persistent panel, gone with the engine). */
	readonly durable: boolean;
	readonly shared: boolean;
	title: string;
	badge: string | null;
	state: JsonValue | null;
	panel: Panel | undefined;
	visible: boolean;
	opened: boolean;
	running: boolean;
	handle: AppHandle;
	finish: () => void;
	saving: ReturnType<typeof setTimeout> | undefined;
};

/** Running apps by session and key. */
const live = new Map<string, Live>();
const liveId = (sessionId: number, key: string) => `${sessionId} ${key}`;

function requireHost(): AppsHost {
	if (!host) throw new Error("apps: the store is not open");
	return host;
}

function json(value: unknown): JsonValue | null {
	return value === undefined ? null : (JSON.parse(JSON.stringify(value)) as JsonValue);
}

const call = (what: string, run: () => unknown) => {
	void Promise.resolve()
		.then(run)
		.catch((error: unknown) => console.warn(`app ${what}: ${error instanceof Error ? error.message : String(error)}`));
};

async function commitApps(sessionId: number, shared: boolean, change: (doc: AppsDoc) => void): Promise<void> {
	const { harness, rootId } = requireHost();
	const id = shared ? rootId() : (sessionId as ConversationId);
	const conversation = await harness().conversation(id, BACKGROUND_CONTEXT);
	if (!conversation) return;
	await conversation.commit(async (tx) => change(await tx.doc(shared ? SharedAppsDoc : SessionAppsDoc, id)), BACKGROUND_CONTEXT);
}

/** Records whether an app is on screen in its session (for after a relaunch). */
function markOpen(app: Live, open: boolean): void {
	if (!app.durable) return;
	void commitApps(app.sessionId, false, (doc) => {
		if (open) (doc.open ??= {})[app.key] = true;
		else if (doc.open) delete doc.open[app.key];
	}).catch((error: unknown) => console.warn(`app ${app.key}: ${error instanceof Error ? error.message : String(error)}`));
}

async function snapshot(sessionId: number, shared: boolean): Promise<AppsDoc> {
	const { harness, rootId } = requireHost();
	const doc = shared
		? await harness().snapshot(SharedAppsDoc, rootId(), BACKGROUND_CONTEXT)
		: await harness().snapshot(SessionAppsDoc, sessionId as ConversationId, BACKGROUND_CONTEXT);
	return doc ?? { apps: {}, states: {} };
}

/** Tells the app a session's dock changed (null: every session's, for a shared app). */
function changed(sessionId: number | null): void {
	emit({ type: "apps_changed", sessionId });
}

/** The live apps of a key: a shared app's in every session, else the one in this session. */
function siblings(app: Live): Live[] {
	return app.shared ? [...live.values()].filter((other) => other.key === app.key) : [app];
}

function record(app: Live): AppRecord {
	return { extension: app.extension, name: app.definition.name, title: app.title, icon: app.definition.icon ?? null, badge: app.badge, openedAt: Date.now() };
}

/**
 * Opens an app in a session, or finds it running: on screen unless `visible` is false (then it waits in the dock, with
 * no page until it opens). `durable: false` is an ad hoc persistent panel, not recorded.
 */
export async function openApp(
	sessionId: number,
	extension: string,
	definition: AppDefinition,
	ui: unknown,
	options: { visible?: boolean; durable?: boolean } = {},
): Promise<AppHandle> {
	const key = appKey(extension, definition.name);
	let app = live.get(liveId(sessionId, key));
	if (!app) app = await start(sessionId, extension, definition, ui, options.durable ?? true);
	if (options.visible !== false) await show(app);
	return app.handle;
}

async function start(sessionId: number, extension: string, definition: AppDefinition, ui: unknown, durable: boolean): Promise<Live> {
	const key = appKey(extension, definition.name);
	const shared = durable && definition.shared === true;
	const saved = durable ? await snapshot(sessionId, shared) : { apps: {}, states: {} };
	// A shared app running in another session has the newest state (saved a moment later).
	const sibling = shared ? [...live.values()].find((other) => other.key === key) : undefined;
	let finish!: () => void;
	const closed = new Promise<void>((resolve) => (finish = resolve));
	const app: Live = {
		sessionId,
		key,
		extension,
		definition,
		ui,
		durable,
		shared,
		title: sibling?.title ?? saved.apps[key]?.title ?? definition.title ?? definition.name,
		badge: sibling ? sibling.badge : (saved.apps[key]?.badge ?? null),
		state: sibling ? sibling.state : (saved.states[key] ?? null),
		panel: undefined,
		visible: false,
		opened: false,
		running: true,
		handle: undefined as unknown as AppHandle,
		finish,
		saving: undefined,
	};
	app.handle = {
		name: definition.name,
		sessionId,
		get state() {
			return app.state;
		},
		setState: (value) => setState(app, value, false),
		post: (data) => app.panel?.post(data),
		refresh: async () => {
			if (app.panel) app.panel.update({ kind: "html", html: await definition.render(app.handle) });
		},
		setBadge: (badge) => {
			app.badge = badge === undefined || badge === "" ? null : String(badge);
			void remember(app);
		},
		setTitle: (title) => {
			app.title = title;
			void remember(app);
		},
		show: () => show(app),
		minimize: () => {
			if (app.panel && app.visible) {
				app.visible = false;
				app.panel.hide();
				markOpen(app, false);
				call("minimize", () => definition.onMinimize?.(app.handle));
				changed(app.sessionId);
			}
		},
		close: () => close(app),
		get visible() {
			return app.visible;
		},
		get running() {
			return app.running;
		},
		closed,
		ui,
	};
	live.set(liveId(sessionId, key), app);
	if (durable && !saved.apps[key]) await commitApps(sessionId, shared, (doc) => (doc.apps[key] = record(app)));
	changed(shared ? null : sessionId);
	return app;
}

/** Puts an app on screen: its running page again, or a page drawn now. */
async function show(app: Live): Promise<void> {
	if (!app.running) return;
	if (app.panel) {
		if (!app.visible) {
			app.visible = true;
			app.panel.show();
			markOpen(app, true);
			call("restore", () => app.definition.onRestore?.(app.handle));
			changed(app.sessionId);
		}
		return;
	}
	const html = await app.definition.render(app.handle);
	if (!app.running || app.panel) return;
	app.visible = true;
	markOpen(app, true);
	app.panel = openPanel(
		app.sessionId,
		app.extension,
		"sheet",
		app.title,
		{ kind: "html", html },
		{
			event: (event) => {
				if (event.type === "message") call("message", () => app.definition.onMessage?.(event.data, app.handle));
				else if (event.type === "state") setState(app, event.value, true);
				else if (event.type === "close") close(app);
			},
			dismissed: () => close(app),
			minimized: () => {
				if (!app.visible) return;
				app.visible = false;
				markOpen(app, false);
				call("minimize", () => app.definition.onMinimize?.(app.handle));
				changed(app.sessionId);
			},
			restored: () => {
				if (app.visible) return;
				app.visible = true;
				markOpen(app, true);
				call("restore", () => app.definition.onRestore?.(app.handle));
				changed(app.sessionId);
			},
			suspended: () => {
				app.panel = undefined;
				app.visible = false;
				changed(app.sessionId);
			},
		},
		{ key: app.key, name: app.definition.name, icon: app.definition.icon ?? null, shared: app.shared, state: app.state },
	);
	if (!app.opened) {
		app.opened = true;
		call("open", () => app.definition.onOpen?.(app.handle));
	}
	changed(app.sessionId);
}

/** Saves an app's state (soon, once for a burst of changes) and gives it to its pages, except the one that sent it. */
function setState(app: Live, value: unknown, fromPage: boolean): void {
	const state = json(value);
	for (const each of siblings(app)) {
		each.state = state;
		if (each !== app || !fromPage) each.panel?.setState(state);
	}
	if (!app.durable) return;
	clearTimeout(app.saving);
	app.saving = setTimeout(() => {
		app.saving = undefined;
		void commitApps(app.sessionId, app.shared, (doc) => {
			if (state === null) delete doc.states[app.key];
			else doc.states[app.key] = state;
		}).catch((error: unknown) => console.warn(`app ${app.key}: saving its state: ${error instanceof Error ? error.message : String(error)}`));
	}, 250);
}

/** Records an app's title and badge, and shows them on its dock entries. */
async function remember(app: Live): Promise<void> {
	for (const each of siblings(app)) {
		each.title = app.title;
		each.badge = app.badge;
	}
	if (app.durable) {
		await commitApps(app.sessionId, app.shared, (doc) => {
			const current = doc.apps[app.key];
			doc.apps[app.key] = { ...record(app), openedAt: current?.openedAt ?? Date.now() };
		}).catch((error: unknown) => console.warn(`app ${app.key}: ${error instanceof Error ? error.message : String(error)}`));
	}
	changed(app.shared ? null : app.sessionId);
}

/** Ends an app (a shared one in every session): off the dock, its pages closed; its saved state stays. */
function close(app: Live): void {
	if (!app.running) return;
	const closing = siblings(app);
	for (const each of closing) {
		each.running = false;
		each.visible = false;
		live.delete(liveId(each.sessionId, each.key));
		each.panel?.close();
		each.panel = undefined;
		call("close", () => each.definition.onClose?.(each.handle));
		each.finish();
	}
	const pending = app.saving !== undefined;
	clearTimeout(app.saving);
	app.saving = undefined;
	const state = app.state;
	void (async () => {
		// Off the record (with the state it closed with, if not saved yet) before the dock asks again.
		if (app.durable) {
			await commitApps(app.sessionId, app.shared, (doc) => {
				if (pending && state === null) delete doc.states[app.key];
				else if (pending) doc.states[app.key] = state as JsonValue;
				delete doc.apps[app.key];
			}).catch((error: unknown) => console.warn(`app ${app.key}: ${error instanceof Error ? error.message : String(error)}`));
			for (const sessionId of new Set(closing.map((each) => each.sessionId))) {
				await commitApps(sessionId, false, (doc) => {
					if (doc.open) delete doc.open[app.key];
				}).catch(() => {});
			}
		}
		changed(app.shared ? null : app.sessionId);
	})();
}

/** Closes a session's app by key, running or only recorded (after a relaunch). */
export async function closeApp(sessionId: number, key: string): Promise<void> {
	const app = live.get(liveId(sessionId, key));
	if (app) return close(app);
	for (const shared of [false, true]) {
		const doc = await snapshot(sessionId, shared);
		if (doc.apps[key] || doc.open?.[key]) {
			await commitApps(sessionId, shared, (draft) => {
				delete draft.apps[key];
				if (draft.open) delete draft.open[key];
			});
		}
	}
	changed(null);
}

/**
 * An extension's instance ended (reloaded, updated, removed, or its session deleted): its apps' pages close, and their
 * records stay, so an app opens again with the extension's new instance (or leaves the dock with the extension).
 */
export function releaseApps(extension: string, sessionId?: number): void {
	const sessions = new Set<number>();
	for (const app of [...live.values()]) {
		if (app.extension !== extension || (sessionId !== undefined && app.sessionId !== sessionId)) continue;
		live.delete(liveId(app.sessionId, app.key));
		app.running = false;
		app.panel?.close();
		app.panel = undefined;
		if (!app.durable) app.finish();
		sessions.add(app.sessionId);
	}
	for (const id of sessions) changed(id);
}

/** A session's running app by key, if its page or record is live in this engine. */
export function runningApp(sessionId: number, key: string): AppHandle | undefined {
	return live.get(liveId(sessionId, key))?.handle;
}

/**
 * A session's dock and launcher: the apps it runs (recorded in the session or shared, whose extension still offers
 * them, and ad hoc persistent panels), and the apps its extensions offer.
 */
export async function listApps(
	sessionId: number,
	offered: { extension: string; definition: Pick<AppDefinition, "name" | "title" | "icon" | "description" | "shared"> }[],
): Promise<{ running: DockApp[]; available: CatalogApp[] }> {
	const catalog = new Map(offered.map((each) => [appKey(each.extension, each.definition.name), each]));
	const own = await snapshot(sessionId, false);
	const shared = await snapshot(sessionId, true);
	const running: DockApp[] = [];
	const seen = new Set<string>();
	const add = (key: string, entry: AppRecord, isShared: boolean) => {
		const offer = catalog.get(key);
		if (!offer || seen.has(key) || Boolean(offer.definition.shared) !== isShared) return;
		seen.add(key);
		const app = live.get(liveId(sessionId, key));
		running.push({
			key,
			extension: entry.extension,
			name: entry.name,
			title: app?.title ?? entry.title,
			icon: entry.icon ?? offer.definition.icon ?? null,
			badge: app?.badge ?? entry.badge,
			shared: isShared,
			panelId: app?.panel?.id ?? null,
			visible: app?.visible ?? false,
			open: app ? app.visible : own.open?.[key] === true,
		});
	};
	const byOpening = (doc: AppsDoc) => Object.entries(doc.apps).sort(([, a], [, b]) => a.openedAt - b.openedAt);
	for (const [key, entry] of byOpening(own)) add(key, entry, false);
	for (const [key, entry] of byOpening(shared)) add(key, entry, true);
	// Ad hoc persistent panels (not recorded), while they run.
	for (const app of live.values()) {
		if (app.sessionId !== sessionId || app.durable || seen.has(app.key)) continue;
		seen.add(app.key);
		running.push({
			key: app.key,
			extension: app.extension,
			name: app.definition.name,
			title: app.title,
			icon: app.definition.icon ?? null,
			badge: app.badge,
			shared: false,
			panelId: app.panel?.id ?? null,
			visible: app.visible,
			open: app.visible,
		});
	}
	const available = offered.map(({ extension, definition }) => {
		const key = appKey(extension, definition.name);
		return {
			key,
			extension,
			name: definition.name,
			title: definition.title ?? definition.name,
			icon: definition.icon ?? null,
			description: definition.description ?? null,
			shared: definition.shared === true,
			running: seen.has(key),
		};
	});
	return { running, available };
}
