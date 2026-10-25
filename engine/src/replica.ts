import type { Context, JsonValue } from "@earendil-works/chord";
import type { Message } from "@earendil-works/pi-ai";
import { type Conversation, type ContextEdit, type ConversationId, type Cursor, type EntryId, type EntryRecord, type Tx, defineDoc } from "@earendil-works/pi-durable";

/**
 * Sessions kept in step across the user's devices (the app's `SessionSync`, through iCloud). Every device numbers a
 * session's entries the same way, by their place in its history (`seq`, 0 first), and keeps which of its own entries
 * those are (`ReplicaDoc`). Entries never change, so a device only ever adds the ones after those it has; a compaction's
 * head and an edit's target travel as the seq of the entry they point at, since each store numbers its entries itself.
 */

/** This store's entry ids in a session's order, as runs of consecutive ids: `[first id, count]`. */
export type Runs = [number, number][];

/**
 * A session's entries as every device numbers them (`runs`), and the session's own extensions as another device last
 * sent them, which this device loads once it takes the session (`replica.claim`).
 */
export const ReplicaDoc = defineDoc<{ runs: Runs; extensions: JsonValue }>({
	kind: "pimobile.replica",
	version: 1,
	scope: "conversation",
	history: "latest",
	// A fork is a session of its own: it numbers its entries when it first syncs.
	fork: "initial",
	initial: () => ({ runs: [], extensions: null }),
	checkpointWhen: () => false,
});

/** An entry as it travels between devices: its references by seq. */
export type WireEntry = {
	kind: string;
	model?: Message[];
	data?: JsonValue;
	/** Where the context starts from this entry on: the entry itself, or the seq of an earlier one. */
	head?: number | "self";
	edits?: { target: number; action: string; messages?: readonly Message[] }[];
};

export function countOf(runs: Runs): number {
	return runs.reduce((sum, [, count]) => sum + count, 0);
}

export function lastId(runs: Runs): number | undefined {
	const run = runs.at(-1);
	return run ? run[0] + run[1] - 1 : undefined;
}

/** The runs with `ids` after them. */
export function withIds(runs: Runs, ids: readonly number[]): Runs {
	const next: Runs = runs.map(([first, count]) => [first, count]);
	for (const id of ids) {
		const last = next.at(-1);
		if (last && last[0] + last[1] === id) last[1]++;
		else next.push([id, 1]);
	}
	return next;
}

/** The seq of this store's entry `id`, if the runs have it. */
export function seqOf(runs: Runs, id: number): number | undefined {
	let seq = 0;
	for (const [first, count] of runs) {
		if (id >= first && id < first + count) return seq + id - first;
		seq += count;
	}
	return undefined;
}

/** This store's entry at `seq`, if the runs reach it. */
export function idAt(runs: Runs, seq: number): number | undefined {
	let rest = seq;
	for (const [first, count] of runs) {
		if (rest < count) return first + rest;
		rest -= count;
	}
	return undefined;
}

/** An entry as it travels, its references as seqs (`runs` reach every entry before it). */
function toWire(record: EntryRecord, runs: Runs): WireEntry {
	// A head that can't be placed starts the context at the entry itself rather than at the start of the session.
	const head = record.head === undefined ? undefined : record.head === record.id ? "self" : (seqOf(runs, record.head) ?? "self");
	const edits = record.edits?.flatMap((edit) => {
		const target = seqOf(runs, edit.target);
		return target === undefined ? [] : [{ ...edit, target }];
	});
	return {
		kind: record.kind,
		...(record.model ? { model: [...record.model] } : {}),
		...(record.data !== undefined ? { data: record.data } : {}),
		...(head !== undefined ? { head } : {}),
		...(edits?.length ? { edits } : {}),
	};
}

/** The session's entries after those in `runs`, oldest first, at most `limit`, as they travel; and their ids here. */
export async function entriesAfter(conversation: Conversation, runs: Runs, limit: number, context: Context): Promise<{ entries: WireEntry[]; ids: number[]; more: boolean }> {
	const after = lastId(runs);
	const records: EntryRecord[] = [];
	let cursor: Cursor | undefined;
	do {
		const page = await conversation.entries(
			{ ...(after !== undefined ? { minEntryId: (after + 1) as EntryId } : {}), order: "ascending" },
			Math.min(500, limit + 1 - records.length),
			cursor,
			context,
		);
		records.push(...page.items);
		cursor = page.next;
	} while (cursor && records.length <= limit);
	// Ascending already; sorted anyway, as a compaction's head and an edit's target must come before it.
	records.sort((a, b) => a.id - b.id);
	const more = records.length > limit;
	const sent = records.slice(0, limit);
	let known = runs;
	const entries = sent.map((record) => {
		const wire = toWire(record, known);
		known = withIds(known, [record.id]);
		return wire;
	});
	return { entries, ids: sent.map((record) => record.id), more };
}

/** Whether the session has entries no other device has: added here after the last ones `runs` has. */
export async function hasEntriesAfter(conversation: Conversation, runs: Runs, context: Context): Promise<boolean> {
	const after = lastId(runs);
	const page = await conversation.entries({ ...(after !== undefined ? { minEntryId: (after + 1) as EntryId } : {}), order: "ascending" }, 1, undefined, context);
	return page.items.length > 0;
}

/** Appends entries another device sent, in order, after the ones `runs` has; the ids they got here. */
export async function appendWire(tx: Pick<Tx, "appendEntry">, conversationId: ConversationId, runs: Runs, entries: readonly WireEntry[]): Promise<number[]> {
	let known = runs;
	const ids: number[] = [];
	for (const entry of entries) {
		const head = entry.head === undefined ? undefined : entry.head === "self" ? "self" : (idAt(known, entry.head) ?? "self");
		const edits = entry.edits?.flatMap((edit) => {
			const target = idAt(known, edit.target);
			return target === undefined ? [] : [{ ...edit, target: target as EntryId }];
		});
		const record = await tx.appendEntry(conversationId, {
			kind: entry.kind,
			...(entry.model ? { model: entry.model } : {}),
			...(entry.data !== undefined ? { data: entry.data } : {}),
			...(head !== undefined ? { head: head as EntryId | "self" } : {}),
			...(edits?.length ? { edits: edits as unknown as ContextEdit[] } : {}),
		});
		ids.push(record.id);
		known = withIds(known, [record.id]);
	}
	return ids;
}
