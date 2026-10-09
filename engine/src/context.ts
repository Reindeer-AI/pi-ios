/**
 * How full a session's context is, measured as pi's automatic compaction measures it (pi-durable's `estimateContext`):
 * the newest assistant message since the last compaction counts what its request sent and got (its usage), and what
 * came after it is estimated. Compaction blocks the next request above `contextWindow - reserveTokens` and starts in
 * the background `backgroundTokens` before that.
 */
import type { AssistantMessage, Message } from "@earendil-works/pi-ai";
import { calculateContextTokens, estimateMessageTokens } from "@earendil-works/pi-ai/utils/estimate";
import type { CompactionPolicy, ContextView } from "@earendil-works/pi-durable";

export function contextTokens(view: ContextView): number {
	let measured: Message | undefined;
	const after = view.head?.id ?? Number.NEGATIVE_INFINITY;
	for (let index = view.entries.length - 1; index >= 0 && measured === undefined; index--) {
		if (view.entries[index]!.id <= after) continue;
		measured = view.contributions[index]!.findLast(
			(message) => message.role === "assistant" && calculateContextTokens((message as AssistantMessage).usage) > 0,
		);
	}
	const from = measured === undefined ? 0 : view.messages.lastIndexOf(measured) + 1;
	let tokens = measured === undefined ? 0 : calculateContextTokens((measured as AssistantMessage).usage);
	for (const message of view.messages.slice(from)) tokens += estimateMessageTokens(message);
	return tokens;
}

/** A session's context use for the app: tokens, the model's window, and where compaction starts. */
export function contextUsage(view: ContextView, contextWindow: number, policy: CompactionPolicy) {
	const threshold = Math.max(0, contextWindow - policy.reserveTokens);
	return {
		tokens: contextTokens(view),
		contextWindow,
		autoCompact: policy.enabled && contextWindow > 0,
		threshold,
		backgroundThreshold: policy.backgroundTokens > 0 ? Math.max(0, threshold - policy.backgroundTokens) : threshold,
		keepRecentTokens: policy.keepRecentTokens,
		reserveTokens: policy.reserveTokens,
	};
}
