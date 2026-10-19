import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { Harness, createRegistry } from "@earendil-works/pi-durable";
import { openNodeSqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite/node";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { appendWire, countOf, entriesAfter, hasEntriesAfter, idAt, seqOf, withIds } from "../dist/replica-tests.mjs";

/** A device: its own store. */
async function device(directory, name) {
	const database = await openNodeSqliteDatabase(join(directory, `${name}.sqlite`));
	const harness = await Harness.open(await SqliteStorage.open(database), { models: createModels(), registry: createRegistry() }, context);
	await harness.root(context);
	return harness;
}

const user = (text) => ({ role: "user", content: text, timestamp: 1 });
const assistant = (text) => ({
	role: "assistant",
	content: [{ type: "text", text }],
	api: "test",
	provider: "test",
	model: "test",
	usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "stop",
	timestamp: 2,
});

/** Appends entries; their ids. */
async function append(conversation, drafts) {
	return conversation.commit(async (tx) => {
		const ids = [];
		for (const draft of drafts) ids.push((await tx.appendEntry(conversation.id, typeof draft === "function" ? draft(ids) : draft)).id);
		return ids;
	}, context);
}

/** What one device sends and the other applies; the runs each has after. */
async function sync(from, fromRuns, to, toRuns) {
	const { entries, ids } = await entriesAfter(from, fromRuns, 1000, context);
	const applied = await to.commit((tx) => appendWire(tx, to.id, toRuns, entries), context);
	return { fromRuns: withIds(fromRuns, ids), toRuns: withIds(toRuns, applied), sent: entries.length };
}

const messages = async (conversation) => JSON.parse(JSON.stringify((await conversation.context(context)).messages));

test("runs number a session's entries the same way on every device", () => {
	const runs = withIds([], [5, 6, 7, 12, 13, 40]);
	assert.deepEqual(runs, [[5, 3], [12, 2], [40, 1]]);
	assert.equal(countOf(runs), 6);
	assert.equal(seqOf(runs, 12), 3);
	assert.equal(seqOf(runs, 8), undefined);
	assert.equal(idAt(runs, 5), 40);
	assert.equal(idAt(runs, 6), undefined);
});

test("a session goes to another device and back, compactions and edits included", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-replica-"));
	const [phone, mac] = [await device(directory, "phone"), await device(directory, "mac")];
	try {
		const here = await phone.createConversation({ ownership: { kind: "ownerless" } }, context);
		// Another session's entries in between, so this one's ids aren't consecutive.
		const other = await phone.createConversation({ ownership: { kind: "ownerless" } }, context);
		const [first] = await append(here, [{ kind: "pi.user", model: [user("one")] }, { kind: "pi.assistant", model: [assistant("two")] }]);
		await append(other, [{ kind: "pi.user", model: [user("elsewhere")] }]);
		await append(here, [
			{ kind: "pi.user", model: [user("three")] },
			{ kind: "app.note", data: { seen: true } },
			// Left out of the model's context from here on.
			{ kind: "pi.user", model: [user("four")], edits: [{ target: first, action: "omit" }] },
		]);
		const there = await mac.createConversation({ ownership: { kind: "ownerless" } }, context);
		let step = await sync(here, [], there, []);
		assert.equal(step.sent, 5);
		assert.deepEqual(await messages(there), await messages(here));
		assert.equal(await hasEntriesAfter(there, step.toRuns, context), false);

		// More on the phone, with a compaction whose context starts at "three".
		const three = idAt(step.fromRuns, 2);
		await append(here, [{ kind: "pi.compaction", model: [user("summary")], head: three }, { kind: "pi.assistant", model: [assistant("five")] }]);
		step = await sync(here, step.fromRuns, there, step.toRuns);
		assert.equal(step.sent, 2);
		assert.deepEqual(await messages(there), await messages(here));
		// The summary, then the context from "three" on.
		assert.deepEqual((await messages(there)).slice(0, 2).map((message) => message.content), ["summary", "three"]);

		// The Mac takes the session and adds to it; the phone gets it back.
		await append(there, [{ kind: "pi.user", model: [user("on the mac")] }, { kind: "pi.reset", head: "self" }]);
		assert.equal(await hasEntriesAfter(there, step.toRuns, context), true);
		const back = await sync(there, step.toRuns, here, step.fromRuns);
		assert.equal(back.sent, 2);
		assert.deepEqual(await messages(here), await messages(there));
		assert.equal(countOf(back.fromRuns), countOf(back.toRuns));
	} finally {
		await phone.close(context);
		await mac.close(context);
		await rm(directory, { recursive: true, force: true });
	}
});

test("a fork travels with what it inherited", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-replica-"));
	const [phone, mac] = [await device(directory, "phone"), await device(directory, "mac")];
	try {
		const source = await phone.createConversation({ ownership: { kind: "ownerless" } }, context);
		const [, second] = await append(source, [{ kind: "pi.user", model: [user("a")] }, { kind: "pi.assistant", model: [assistant("b")] }, { kind: "pi.user", model: [user("c")] }]);
		const fork = await source.fork(second, { ownership: { kind: "ownerless" } }, context);
		await append(fork, [{ kind: "pi.user", model: [user("d")] }]);
		const there = await mac.createConversation({ ownership: { kind: "ownerless" } }, context);
		const step = await sync(fork, [], there, []);
		assert.equal(step.sent, 3);
		assert.deepEqual((await messages(there)).map((message) => message.role === "user" ? message.content : message.content[0].text), ["a", "b", "d"]);
	} finally {
		await phone.close(context);
		await mac.close(context);
		await rm(directory, { recursive: true, force: true });
	}
});

test("a long session goes in chunks", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-replica-"));
	const [phone, mac] = [await device(directory, "phone"), await device(directory, "mac")];
	try {
		const here = await phone.createConversation({ ownership: { kind: "ownerless" } }, context);
		await append(here, Array.from({ length: 1203 }, (_, index) => ({ kind: "pi.user", model: [user(`m${index}`)] })));
		const there = await mac.createConversation({ ownership: { kind: "ownerless" } }, context);
		let [fromRuns, toRuns, chunks] = [[], [], 0];
		for (;;) {
			const { entries, ids, more } = await entriesAfter(here, fromRuns, 500, context);
			const applied = await there.commit((tx) => appendWire(tx, there.id, toRuns, entries), context);
			fromRuns = withIds(fromRuns, ids);
			toRuns = withIds(toRuns, applied);
			chunks++;
			if (!more) break;
		}
		assert.equal(chunks, 3);
		assert.equal(countOf(toRuns), 1203);
		assert.deepEqual(await messages(there), await messages(here));
	} finally {
		await phone.close(context);
		await mac.close(context);
		await rm(directory, { recursive: true, force: true });
	}
});
