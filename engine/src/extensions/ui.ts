/**
 * Extension UI on the app's screen, for pi's `ctx.ui`: dialogs (select, confirm, input, editor) the app shows and
 * answers through `ui.respond`, and notifications, status lines, text widgets, and the session's input text, which it
 * shows as they arrive. A dialog ends with the answer, its `signal`, or its `timeout`, as in pi.
 */
import { emit, onCommand, request } from "../bridge.ts";

export type DialogKind = "select" | "confirm" | "input" | "editor";
export type Dialog = { kind: DialogKind; title: string; message?: string; options?: string[]; placeholder?: string; prefill?: string };

const pending = new Map<string, (value: string | undefined) => void>();
let nextDialog = 0;

/** Shows a dialog in a session and waits for its answer (undefined when dismissed, aborted, or timed out). */
export function ask(sessionId: number, extension: string, dialog: Dialog, options: { signal?: AbortSignal; timeout?: number } = {}): Promise<string | undefined> {
	const id = `dialog-${++nextDialog}`;
	return new Promise((resolve) => {
		let timer: ReturnType<typeof setTimeout> | undefined;
		const abort = () => finish(undefined, true);
		function finish(value: string | undefined, close: boolean) {
			if (!pending.delete(id)) return;
			if (timer !== undefined) clearTimeout(timer);
			options.signal?.removeEventListener("abort", abort);
			// The app closes a dialog it answered itself; one that ended here is withdrawn.
			if (close) emit({ type: "ui_closed", id });
			resolve(value);
		}
		pending.set(id, (value) => finish(value, false));
		if (options.signal?.aborted) return finish(undefined, false);
		options.signal?.addEventListener("abort", abort, { once: true });
		if (options.timeout !== undefined && options.timeout > 0) timer = setTimeout(abort, options.timeout);
		emit({ type: "ui_request", id, sessionId, extension, ...dialog });
	});
}

onCommand("ui.respond", ({ id, value }: { id: string; value?: string | null }) => {
	pending.get(id)?.(value ?? undefined);
	return null;
});

export function notify(sessionId: number, extension: string, message: string, level: "info" | "warning" | "error"): void {
	emit({ type: "ui_notify", sessionId, extension, message: plainText(message), level });
}

/** A status line (undefined removes it); keys are the extension's own. */
export function setStatus(sessionId: number, extension: string, key: string, text: string | undefined): void {
	emit({ type: "ui_status", sessionId, key: `${extension}:${key}`, text: text === undefined ? null : plainText(text) });
}

/** Text lines shown above the input (undefined removes them). */
export function setWidget(sessionId: number, extension: string, key: string, lines: string[] | undefined): void {
	emit({ type: "ui_widget", sessionId, key: `${extension}:${key}`, lines: lines?.map(plainText) ?? null });
}

/** Replaces the session's input text, or appends to it. */
export function setEditorText(sessionId: number, text: string, append = false): void {
	emit({ type: "ui_editor_text", sessionId, text, append });
}

/** Text without terminal escape sequences (colors an extension adds itself), for the app's plain text views. */
function plainText(text: string): string {
	return String(text)
		.replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "")
		.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
		.replace(/\x1b[^[\]]/g, "");
}

/**
 * pi's footer data for a session, which `setFooter` factories get: the extensions' status texts (every `setStatus`
 * goes through `setExtensionStatus`, which a footer may wrap to repaint), the workspace's git branch, and how many
 * providers have credentials.
 */
export class FooterData {
	private readonly statuses = new Map<string, string>();
	private readonly branchListeners = new Set<() => void>();
	private branch: string | null = null;
	private checked = 0;

	constructor(
		private readonly cwd: string,
		private readonly providerCount: () => number,
	) {}

	/** The branch as last read; reading it checks `.git/HEAD` again (at most every 2 seconds). */
	getGitBranch(): string | null {
		if (Date.now() - this.checked > 2000) {
			this.checked = Date.now();
			void gitBranch(this.cwd).then((branch) => {
				if (branch === this.branch) return;
				this.branch = branch;
				for (const listener of this.branchListeners) listener();
			});
		}
		return this.branch;
	}

	getExtensionStatuses(): ReadonlyMap<string, string> {
		return this.statuses;
	}

	getAvailableProviderCount(): number {
		return this.providerCount();
	}

	onBranchChange(callback: () => void): () => void {
		this.branchListeners.add(callback);
		return () => this.branchListeners.delete(callback);
	}

	setExtensionStatus(key: string, text: string | undefined): void {
		if (text === undefined) this.statuses.delete(key);
		else this.statuses.set(key, text);
	}

	clearExtensionStatuses(): void {
		this.statuses.clear();
	}
}

const footers = new Map<number, FooterData>();

export function footerData(sessionId: number, cwd: string, providerCount: () => number): FooterData {
	let footer = footers.get(sessionId);
	if (!footer) {
		footer = new FooterData(cwd, providerCount);
		footers.set(sessionId, footer);
	}
	return footer;
}

/** The checked-out branch of the repository at `cwd` ("detached" for a detached HEAD), or null outside one. */
async function gitBranch(cwd: string): Promise<string | null> {
	try {
		let git = `${cwd}/.git`;
		const stat = await request<{ kind: string }>("fs", "stat", { path: git });
		// A worktree's `.git` is a file naming its git directory.
		if (stat.kind === "file") git = (await request<string>("fs", "readText", { path: git })).replace(/^gitdir:\s*/, "").trim();
		const head = (await request<string>("fs", "readText", { path: `${git}/HEAD` })).trim();
		return head.startsWith("ref: refs/heads/") ? head.slice("ref: refs/heads/".length) : "detached";
	} catch {
		return null;
	}
}
