import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { AgentDoc, Harness, createRegistry } from "@earendil-works/pi-durable";
import { openNodeSqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite/node";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { createSession, SessionsDoc, submissionReply } from "../dist/session-tests.mjs";

const options = { title: "Watch task", model: { provider: "test", modelId: "test" }, creationRequestId: "watch-request" };
async function open(directory) {
	const database = await openNodeSqliteDatabase(join(directory, "sessions.sqlite"));
	const storage = await SqliteStorage.open(database);
	const harness = await Harness.open(storage, { models: createModels(), registry: createRegistry() }, context);
	return { database, storage, harness, root: await harness.root(context) };
}

test("concurrent session retries and restart reuse one registered conversation", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-watch-"));
	let state = await open(directory);
	try {
		const [first, retry] = await Promise.all([createSession(state.root, options, context), createSession(state.root, options, context)]);
		assert.equal(first.id, retry.id);
		assert.deepEqual((await state.harness.snapshot(AgentDoc, first.id, context)).model, options.model);
		await state.harness.close(context);
		state = await open(directory);
		assert.deepEqual(await createSession(state.root, options, context), first);
		assert.equal((await state.harness.snapshot(SessionsDoc, state.root.id, context)).sessions.length, 1);
		assert.ok(await state.harness.conversation(first.id, context));
	} finally { await state.harness.close(context); await rm(directory, { recursive: true, force: true }); }
});

test("a failed session metadata write rolls back the conversation on reopen", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-watch-"));
	let state = await open(directory);
	try {
		await state.database.exec(`CREATE TRIGGER fail_session BEFORE INSERT ON documents
			WHEN json_extract(NEW.record, '$.kind') = 'pimobile.sessions'
			BEGIN SELECT RAISE(ABORT, 'interrupted commit'); END`);
		await assert.rejects(createSession(state.root, options, context), /interrupted commit/);
		await state.database.exec("DROP TRIGGER fail_session");
		await state.harness.close(context);
		state = await open(directory);
		assert.equal((await state.harness.snapshot(SessionsDoc, state.root.id, context))?.sessions.length ?? 0, 0);
		const page = await state.storage.scanConversations({}, 100, undefined, context);
		assert.deepEqual(page.items.map((conversation) => conversation.id), [state.root.id]);
		assert.ok(await createSession(state.root, options, context));
	} finally { await state.harness.close(context); await rm(directory, { recursive: true, force: true }); }
});

test("submission lookup returns queued immediately and reads its exact answer", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-watch-"));
	const state = await open(directory);
	try {
		const session = await createSession(state.root, options, context);
		const conversation = await state.harness.conversation(session.id, context);
		const queued = await conversation.commit((tx) => tx.createSubmission({ conversationId: conversation.id, type: "input", status: "queued", requestId: "queued" }), context);
		assert.equal((await submissionReply(state.harness, session.id, queued.id, context)).status, "queued");
		const done = await conversation.commit(async (tx) => {
			const prompt = await tx.appendEntry(conversation.id, { kind: "pi.user", model: [{ role: "user", content: "First prompt" }] });
			const answer = await tx.appendEntry(conversation.id, { kind: "pi.assistant", model: [{ role: "assistant", content: [{ type: "text", text: "First answer" }], stopReason: "stop" }] });
			await tx.appendEntry(conversation.id, { kind: "pi.assistant", model: [{ role: "assistant", content: [{ type: "text", text: "A newer unrelated answer" }], stopReason: "stop" }] });
			return tx.createSubmission({ conversationId: conversation.id, type: "input", status: "done", entry: prompt.id, answer: answer.id });
		}, context);
		assert.equal((await submissionReply(state.harness, session.id, done.id, context)).text, "First answer");
		await assert.rejects(submissionReply(state.harness, state.root.id, done.id, context), /different session/);
		await assert.rejects(submissionReply(state.harness, session.id, 999999, context), /no longer exists/);
	} finally { await state.harness.close(context); await rm(directory, { recursive: true, force: true }); }
});

test("durable input request IDs deduplicate across a phone restart", async () => {
	const directory = await mkdtemp(join(tmpdir(), "pi-watch-"));
	let state = await open(directory);
	try {
		const session = await createSession(state.root, options, context);
		let conversation = await state.harness.conversation(session.id, context);
		const input = { type: "input", content: "Watch prompt", whenBusy: "followUp", requestId: "stable-prompt" };
		const first = await conversation.submit(input, context);
		assert.equal((await conversation.submit(input, context)).id, first.id);
		await state.harness.close(context);
		state = await open(directory);
		conversation = await state.harness.conversation(session.id, context);
		assert.equal((await conversation.submit(input, context)).id, first.id);
	} finally { await state.harness.close(context); await rm(directory, { recursive: true, force: true }); }
});
