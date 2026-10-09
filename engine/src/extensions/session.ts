/**
 * Session history as pi extensions read it (`ctx.sessionManager`): a conversation's pi-durable entries as pi's session
 * entries. Many extensions rebuild their state from it, for example from their tools' result `details`.
 *
 * pi's session manager is synchronous, so each conversation's entries are mirrored here and brought up to date (only
 * the entries added since) before an extension is called. pi-durable transcripts are linear: each entry's parent is the
 * one before it.
 */
import type { Context } from "@earendil-works/chord";
import type { ConversationId, Cursor, EntryId, EntryRecord, Harness } from "@earendil-works/pi-durable";

export type SessionEntry = { type: string; id: string; parentId: string | null; timestamp: string; [key: string]: unknown };

/** Entry kinds the app writes: for `pi.appendEntry()`, `pi.sendMessage()`, a `!command` the user ran, a system prompt
 * that `before_agent_start` replaced for a run, and a context edit an extension asked for. */
export const CUSTOM_ENTRY = "pimobile.custom";
export const CUSTOM_MESSAGE_ENTRY = "pimobile.custom-message";
export const BASH_ENTRY = "pimobile.bash";
export const SYSTEM_PROMPT_ENTRY = "pimobile.system-prompt";
export const CONTEXT_EDIT_ENTRY = "pimobile.context-edit";

type Mirror = { entries: SessionEntry[]; byId: Map<string, SessionEntry>; last: number; updating?: Promise<void> };

export class Histories {
	private readonly mirrors = new Map<number, Mirror>();

	constructor(
		private readonly harness: () => Harness,
		private readonly context: Context,
	) {}

	/** Brings a conversation's mirror up to date. */
	async refresh(conversationId: number): Promise<void> {
		const mirror = this.mirror(conversationId);
		// One update at a time per conversation; a caller arriving during one waits for it and then checks again.
		while (mirror.updating) await mirror.updating;
		mirror.updating = this.update(conversationId, mirror).finally(() => {
			mirror.updating = undefined;
		});
		await mirror.updating;
	}

	entries(conversationId: number): readonly SessionEntry[] {
		return this.mirror(conversationId).entries;
	}

	entry(conversationId: number, id: string | number): SessionEntry | undefined {
		return this.mirror(conversationId).byId.get(String(id));
	}

	forget(conversationId: number): void {
		this.mirrors.delete(conversationId);
	}

	/** The newest system prompt, as its sections render. */
	systemPrompt(conversationId: number): string {
		const entries = this.mirror(conversationId).entries;
		for (let index = entries.length - 1; index >= 0; index--) {
			const message = entries[index]!.message as { role?: string; content?: unknown; sections?: Record<string, string> } | undefined;
			if (message?.role !== "system") continue;
			const sections = Object.values(message.sections ?? {});
			return [typeof message.content === "string" ? message.content : "", ...sections].filter(Boolean).join("\n\n");
		}
		return "";
	}

	/** pi's `ReadonlySessionManager` for a conversation, reading the mirror as it is when called. */
	manager(conversationId: number, cwd: string, sessionName: () => string | undefined) {
		const mirror = this.mirror(conversationId);
		const branch = (fromId?: string) => {
			if (fromId === undefined) return [...mirror.entries];
			const index = mirror.entries.findIndex((entry) => entry.id === fromId);
			return index < 0 ? [] : mirror.entries.slice(0, index + 1);
		};
		return {
			getCwd: () => cwd,
			getSessionDir: () => cwd,
			getSessionId: () => String(conversationId),
			getSessionFile: () => undefined,
			getLeafId: () => mirror.entries.at(-1)?.id ?? null,
			getLeafEntry: () => mirror.entries.at(-1),
			getEntry: (id: string) => mirror.byId.get(id),
			getLabel: () => undefined,
			getBranch: branch,
			getEntries: () => [...mirror.entries],
			// What the model sees: from the newest compaction (with the entries it keeps) or reset.
			buildContextEntries: () => contextEntries(mirror.entries),
			buildSessionProjection: () => ({ entries: contextEntries(mirror.entries) }),
			getHeader: () => ({ type: "session", version: 3, id: String(conversationId), timestamp: mirror.entries[0]?.timestamp ?? new Date().toISOString(), cwd }),
			getTree: () => tree(mirror.entries),
			getSessionName: sessionName,
		};
	}

	private mirror(conversationId: number): Mirror {
		let mirror = this.mirrors.get(conversationId);
		if (!mirror) {
			mirror = { entries: [], byId: new Map(), last: 0 };
			this.mirrors.set(conversationId, mirror);
		}
		return mirror;
	}

	private async update(conversationId: number, mirror: Mirror): Promise<void> {
		const conversation = await this.harness().conversation(conversationId as ConversationId, this.context);
		if (!conversation) return;
		// Newest first, down to the last entry already mirrored.
		const added: EntryRecord[] = [];
		let cursor: Cursor | undefined;
		do {
			const query = mirror.last > 0 ? { minEntryId: mirror.last as EntryId } : {};
			const page = await conversation.entries(query, 200, cursor, this.context);
			for (const record of page.items) if (record.id > mirror.last) added.push(record);
			cursor = page.next;
		} while (cursor !== undefined);
		for (const record of added.reverse()) {
			const previous = mirror.entries.at(-1);
			const entry = sessionEntry(record, previous?.id ?? null, previous?.timestamp);
			mirror.entries.push(entry);
			mirror.byId.set(entry.id, entry);
			mirror.last = record.id;
		}
	}
}

/** The message pi would show for an entry: pi's own roles for custom messages and user bash, else the model message. */
export function messageOf(record: EntryRecord): Record<string, unknown> | undefined {
	const message = record.model?.[0] as Record<string, unknown> | undefined;
	const data = (record.data ?? {}) as Record<string, unknown>;
	const timestamp = (message?.timestamp as number | undefined) ?? Date.now();
	if (record.kind === CUSTOM_MESSAGE_ENTRY) {
		return { role: "custom", customType: data.customType, content: message?.content ?? "", display: data.display !== false, details: data.details, timestamp };
	}
	if (record.kind === BASH_ENTRY) {
		return {
			role: "bashExecution",
			command: data.command,
			output: data.output,
			exitCode: data.exitCode ?? undefined,
			cancelled: data.cancelled === true,
			truncated: data.truncated === true,
			excludeFromContext: data.excludeFromContext === true,
			timestamp,
		};
	}
	return message;
}

/** One pi-durable entry as pi's session entry. */
function sessionEntry(record: EntryRecord, parentId: string | null, previousTimestamp: string | undefined): SessionEntry {
	const message = record.model?.[0] as { timestamp?: number; content?: unknown } | undefined;
	const timestamp = message?.timestamp ? new Date(message.timestamp).toISOString() : (previousTimestamp ?? new Date().toISOString());
	const base = { id: String(record.id), parentId, timestamp };
	const data = (record.data ?? {}) as Record<string, unknown>;
	switch (record.kind) {
		case "pi.user":
		case "pi.assistant":
		case "pi.tool-result":
		case "pi.system":
			return { ...base, type: "message", message };
		case "pi.reset":
			// A new context, possibly carrying a handoff note to the model.
			return message ? { ...base, type: "message", message } : { ...base, type: "custom", customType: "pi.reset" };
		case "pi.compaction":
			return {
				...base,
				type: "compaction",
				summary: typeof message?.content === "string" ? message.content : JSON.stringify(message?.content ?? ""),
				firstKeptEntryId: String(record.head ?? record.id),
				tokensBefore: 0,
			};
		case CUSTOM_ENTRY:
			return { ...base, type: "custom", customType: data.customType, data: data.data };
		case CUSTOM_MESSAGE_ENTRY:
			return { ...base, type: "custom_message", customType: data.customType, content: message?.content ?? "", display: data.display !== false, details: data.details };
		case BASH_ENTRY:
			return { ...base, type: "message", message: messageOf(record) };
		default:
			return { ...base, type: "custom", customType: record.kind, data: record.data };
	}
}

function contextEntries(entries: readonly SessionEntry[]): SessionEntry[] {
	for (let index = entries.length - 1; index >= 0; index--) {
		const entry = entries[index]!;
		if (entry.type === "compaction") {
			const kept = entries.findIndex((candidate) => candidate.id === entry.firstKeptEntryId);
			return [entry, ...entries.slice(kept < 0 ? index + 1 : kept).filter((candidate) => candidate !== entry)];
		}
		if (entry.type === "custom" && entry.customType === "pi.reset") return entries.slice(index + 1);
	}
	return [...entries];
}

type TreeNode = { entry: SessionEntry; children: TreeNode[] };

function tree(entries: readonly SessionEntry[]): TreeNode[] {
	let root: TreeNode | undefined;
	let parent: TreeNode | undefined;
	for (const entry of entries) {
		const node: TreeNode = { entry, children: [] };
		if (parent) parent.children.push(node);
		else root = node;
		parent = node;
	}
	return root ? [root] : [];
}
