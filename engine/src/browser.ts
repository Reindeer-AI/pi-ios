/**
 * Browser tools: each session's agent drives a real web page in the app, on the session's browser profile (see the
 * native `browser` service, `BrowserService.swift`). Native composes what the model sees; these tools pass the call
 * through with the session id, make each round sequential, and declare which calls are safe to re-run after an
 * interruption: looking is, acting is not. They carry no policy: an extension can wrap them (`wrapTool`) to ask before
 * actions, restrict sites, or add instructions.
 */
import { type Model, Type } from "@earendil-works/pi-ai";
import type { MutableModels } from "@earendil-works/pi-ai/models";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { request } from "./bridge.ts";

type BrowserReply = { text: string; isError?: boolean; image?: string };
type Call = { conversationId: number };
type CallContext = { abortSignal?: AbortSignal };

async function browser(api: Call, context: CallContext, method: string, params: Record<string, unknown> = {}) {
	const reply = await abortable(request<BrowserReply>("browser", method, { sessionId: api.conversationId, ...params }), context);
	const content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[] = [
		{ type: "text", text: reply.text },
	];
	if (reply.image) content.push({ type: "image", data: reply.image, mimeType: "image/jpeg" });
	return { output: content, isError: reply.isError === true };
}

/** Stops waiting when the run is aborted; native finishes the step it is on. */
function abortable<T>(promise: Promise<T>, context: CallContext): Promise<T> {
	const signal = context.abortSignal;
	if (!signal) return promise;
	if (signal.aborted) return Promise.reject(new Error("aborted"));
	return Promise.race([
		promise,
		new Promise<never>((_, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true })),
	]);
}

const Ref = Type.String({ description: "An element's ref from the latest snapshot, such as e12" });

/** The browser tools; `models` tells whether the session's model can see screenshots. */
export function browserTools(models: () => MutableModels) {
	const look = { replay: "safe", executionMode: "sequential" } as const;
	const act = { replay: "unsafe", executionMode: "sequential" } as const;

	return defineExtension({
		name: "browser",
		tools: [
			defineTool({
				name: "browser_navigate",
				description: "Open a web address in the current tab and return a snapshot of the page.",
				parameters: Type.Object({ url: Type.String({ description: "https://… or a domain such as example.com" }) }),
				...look,
				execute: (args, api, context) => browser(api, context, "navigate", args),
			}),
			defineTool({
				name: "browser_snapshot",
				description: "The current page's structure, with refs for the elements you can act on.",
				parameters: Type.Object({}),
				...look,
				execute: (_args, api, context) => browser(api, context, "snapshot"),
			}),
			defineTool({
				name: "browser_read",
				description: "The current page's readable text, 20,000 characters at a time.",
				parameters: Type.Object({ offset: Type.Optional(Type.Number({ minimum: 0, description: "Where to continue from" })) }),
				...look,
				execute: (args, api, context) => browser(api, context, "read", args),
			}),
			defineTool({
				name: "browser_screenshot",
				description: "A screenshot of the visible page, for layout or images that the snapshot can't describe.",
				parameters: Type.Object({}),
				...look,
				execute: async (_args, api, context) => {
					const agent = await api.agent(context);
					const model: Model<any> | undefined = agent.model
						? models().getModels(agent.model.provider).find((each) => each.id === agent.model?.modelId)
						: undefined;
					if (!model?.input.includes("image")) {
						return {
							output: [{ type: "text" as const, text: "Error: this model can't see images. Use browser_snapshot or browser_read." }],
							isError: true,
						};
					}
					return browser(api, context, "screenshot");
				},
			}),
			defineTool({
				name: "browser_click",
				description: "Click an element by ref and return the page afterwards.",
				parameters: Type.Object({ ref: Ref }),
				...act,
				execute: (args, api, context) => browser(api, context, "click", args),
			}),
			defineTool({
				name: "browser_type",
				description:
					"Replace the text in a field by ref, optionally pressing Enter to submit, and return the page afterwards.",
				parameters: Type.Object({
					ref: Ref,
					text: Type.String(),
					submit: Type.Optional(Type.Boolean({ description: "Press Enter after typing" })),
				}),
				...act,
				execute: (args, api, context) => browser(api, context, "type", args),
			}),
			defineTool({
				name: "browser_fill_from_vault",
				description:
					"Fill a field by ref with a value from the user's vault (vault_list names the items and their fields), such as a card number or passport number. The user approves with Face ID; you never see the value, and the page shows it masked. Returns the page afterwards.",
				parameters: Type.Object({
					ref: Ref,
					item: Type.String({ description: "The vault item's id (vault_list)" }),
					field: Type.String({ description: "Which of its fields: number, cvv, …" }),
				}),
				...act,
				execute: (args, api, context) => browser(api, context, "fillSecret", { ...args, requester: "the agent" }),
			}),
			defineTool({
				name: "browser_select",
				description: "Choose an option of a <select> (combobox with options) by its value or label.",
				parameters: Type.Object({ ref: Ref, option: Type.String() }),
				...act,
				execute: (args, api, context) => browser(api, context, "select", args),
			}),
			defineTool({
				name: "browser_press",
				description: "Press a key in the focused element.",
				parameters: Type.Object({
					key: Type.Union(
						["Enter", "Escape", "Tab", "Backspace", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Space"].map(
							(key) => Type.Literal(key),
						),
					),
				}),
				...act,
				execute: (args, api, context) => browser(api, context, "press", args),
			}),
			defineTool({
				name: "browser_scroll",
				description: "Scroll the page up or down by a screen, or bring an element into view, and return the snapshot.",
				parameters: Type.Object({
					direction: Type.Optional(Type.Union([Type.Literal("up"), Type.Literal("down")])),
					ref: Type.Optional(Ref),
				}),
				...look,
				execute: (args, api, context) => browser(api, context, "scroll", args),
			}),
			defineTool({
				name: "browser_wait",
				description: "Wait until text or an element appears on the page (up to 30 s), then return the snapshot.",
				parameters: Type.Object({
					text: Type.Optional(Type.String()),
					ref: Type.Optional(Ref),
					seconds: Type.Optional(Type.Number({ minimum: 1, maximum: 30 })),
				}),
				...look,
				execute: (args, api, context) => browser(api, context, "wait", args),
			}),
			defineTool({
				name: "browser_dialog",
				description:
					"Answer the dialog the page is waiting on (alert, confirm, or prompt): accept is OK, otherwise Cancel. For a prompt, text is the answer.",
				parameters: Type.Object({ accept: Type.Boolean(), text: Type.Optional(Type.String()) }),
				...act,
				execute: (args, api, context) => browser(api, context, "dialog", args),
			}),
			defineTool({
				name: "browser_back",
				description: "Go back one page in the current tab.",
				parameters: Type.Object({}),
				...act,
				execute: (_args, api, context) => browser(api, context, "back"),
			}),
			defineTool({
				name: "browser_forward",
				description: "Go forward one page in the current tab.",
				parameters: Type.Object({}),
				...act,
				execute: (_args, api, context) => browser(api, context, "forward"),
			}),
			defineTool({
				name: "browser_reload",
				description: "Reload the current page.",
				parameters: Type.Object({}),
				...look,
				execute: (_args, api, context) => browser(api, context, "reload"),
			}),
			defineTool({
				name: "browser_tabs",
				description: "List, open, switch to, or close tabs (up to 4). Tabs are numbered from 1.",
				parameters: Type.Object({
					action: Type.Union([Type.Literal("list"), Type.Literal("open"), Type.Literal("select"), Type.Literal("close")]),
					url: Type.Optional(Type.String({ description: "For open: the address to load" })),
					index: Type.Optional(Type.Number({ minimum: 1, description: "For select and close" })),
				}),
				...act,
				execute: (args, api, context) => browser(api, context, "tabs", args),
			}),
		],
	});
}
