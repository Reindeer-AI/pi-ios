import type { Context } from "@earendil-works/chord";
import { AgentDoc, defineDoc, type Conversation, type EntryRecord, type Harness } from "@earendil-works/pi-durable";
import { BASH_ENTRY, CUSTOM_MESSAGE_ENTRY } from "./extensions/session.ts";

/** One user-facing session: an ownerless pi-durable conversation with its own workspace. */
export type SessionMeta = {
	id: number;
	creationRequestId?: string;
	title: string;
	createdAt: number;
	/** When the user last sent the session a message; sessions from before this have none (createdAt stands in). */
	lastActiveAt?: number;
	model: { provider: string; modelId: string };
	/** The browser profile key the session's browser uses, or none. Sessions created before browsers have none. */
	browser?: string | null;
	/** How much its model thinks (pi's levels, off to max, as the model takes them); sessions from before have none: off. */
	thinkingLevel?: string;
	/** The session on every device it syncs to (`replica.ts`); none until it first syncs. */
	syncId?: string;
	/** The device that has the session now, when another one does: here it's read-only until the user continues it here. */
	heldBy?: string;
};

/** The session list, kept as a document on the root conversation so it is as durable as the transcripts. */
export const SessionsDoc = defineDoc<{ sessions: SessionMeta[] }>({
	kind: "pimobile.sessions",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ sessions: [] }),
	checkpointWhen: () => false,
});

// Register metadata with its conversation so retries cannot leave orphan sessions.
export async function createSession(
	root: Conversation,
	options: Omit<SessionMeta, "id" | "createdAt" | "lastActiveAt">,
	context: Context,
): Promise<SessionMeta> {
	return root.commit(async (tx) => {
		const { sessions } = await tx.doc(SessionsDoc, root.id);
		if (options.creationRequestId) {
			const existing = sessions.find((session) => session.creationRequestId === options.creationRequestId);
			if (existing) return { ...existing, model: { ...existing.model } };
		}
		const conversation = await tx.createConversation({ ownership: { kind: "ownerless" } });
		(await tx.doc(AgentDoc, conversation.id)).model = { ...options.model };
		const session = { ...options, id: conversation.id, createdAt: Date.now() };
		sessions.push(session);
		return session;
	}, context);
}

// A newer conversation message may answer a different submission.
export async function submissionReply(harness: Harness, id: number, submissionId: number, context: Context) {
	const submission = await harness.submission(submissionId as Parameters<typeof harness.submission>[0], context);
	if (!submission) throw new Error("Submission no longer exists");
	const record = await submission.status(context);
	if (record.conversationId !== id) throw new Error("Submission belongs to a different session");
	let text = "", error: string | undefined;
	if (record.status === "done" && record.answer !== undefined) {
		const conversation = await harness.conversation(record.conversationId, context);
		if (!conversation) throw new Error("Session no longer exists");
		const page = await conversation.entries({ minEntryId: record.answer, maxEntryId: record.answer }, 1, undefined, context);
		const answer = transcriptOf(page.items).find((item) => item.kind === "assistant");
		if (answer?.kind === "assistant") { text = answer.text; error = answer.error; }
	}
	return { status: record.status, text, error: error ?? null, reason: record.reason ?? null, detail: record.detail ?? null };
}

export type TranscriptItem =
	| { kind: "user"; entryId: number; text: string }
	| {
			kind: "assistant";
			entryId: number;
			text: string;
			thinking: string;
			toolCalls: { id: string; name: string; arguments: string }[];
			error?: string;
	  }
	| { kind: "tool"; entryId: number; toolCallId: string; toolName: string; output: string; isError: boolean }
	/** A message an extension sent with `display: true`. */
	| { kind: "custom"; entryId: number; customType: string; text: string }
	/** Where pi compacted the context: the summary that replaced what came before, and why (manual, threshold, overflow). */
	| { kind: "compaction"; entryId: number; summary: string; reason: string }
	/** A `!command` the user ran. */
	| { kind: "bash"; entryId: number; command: string; output: string; exitCode: number | null };

type Block = { type: string; text?: string; thinking?: string; id?: string; name?: string; arguments?: unknown };

/** A compaction's summary, without the framing the model gets it in. */
function compactionSummary(text: string): string {
	const match = /<summary>\n?([\s\S]*?)\n?<\/summary>/.exec(text);
	return (match?.[1] ?? text).trim();
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as Block[])
		.filter((block) => block.type === "text")
		.map((block) => block.text ?? "")
		.join("");
}

/** Flattens committed entries into what the app renders. Entry records keep their model message in `model[0]`. */
export function transcriptOf(entries: readonly EntryRecord[]): TranscriptItem[] {
	const items: TranscriptItem[] = [];
	for (const entry of entries as unknown as { id: number; kind: string; model?: Record<string, unknown>[]; data?: Record<string, unknown> }[]) {
		const message = entry.model?.[0];
		const data = entry.data ?? {};
		if (entry.kind === BASH_ENTRY) {
			items.push({ kind: "bash", entryId: entry.id, command: String(data.command ?? ""), output: String(data.output ?? ""), exitCode: (data.exitCode as number | null) ?? null });
			continue;
		}
		if (!message) continue;
		switch (entry.kind) {
			case CUSTOM_MESSAGE_ENTRY:
				if (data.display !== false) items.push({ kind: "custom", entryId: entry.id, customType: String(data.customType ?? ""), text: textOf(message.content) });
				break;
			case "pi.user":
				items.push({ kind: "user", entryId: entry.id, text: textOf(message.content) });
				break;
			case "pi.compaction":
				items.push({ kind: "compaction", entryId: entry.id, summary: compactionSummary(textOf(message.content)), reason: String(data.reason ?? "") });
				break;
			case "pi.assistant": {
				const blocks = (message.content as Block[] | undefined) ?? [];
				items.push({
					kind: "assistant",
					entryId: entry.id,
					text: textOf(blocks),
					thinking: blocks
						.filter((block) => block.type === "thinking")
						.map((block) => block.thinking ?? "")
						.join(""),
					toolCalls: blocks
						.filter((block) => block.type === "toolCall")
						.map((block) => ({
							id: block.id ?? "",
							name: block.name ?? "",
							arguments: typeof block.arguments === "string" ? block.arguments : JSON.stringify(block.arguments ?? {}),
						})),
					error:
						message.stopReason === "error" || message.stopReason === "aborted"
							? String(message.errorMessage ?? message.stopReason)
							: message.stopReason === "length"
								? "The reply hit the model's output limit and was cut off. Ask the agent to continue, or choose a model with a larger limit."
								: undefined,
				});
				break;
			}
			case "pi.tool-result":
				items.push({
					kind: "tool",
					entryId: entry.id,
					toolCallId: String(message.toolCallId ?? ""),
					toolName: String(message.toolName ?? ""),
					output: textOf(message.content),
					isError: message.isError === true,
				});
				break;
		}
	}
	return items;
}
