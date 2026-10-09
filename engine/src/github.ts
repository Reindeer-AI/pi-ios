/**
 * The user's GitHub account (Settings → GitHub), held by the app's native `github` service: the agent never sees the
 * token. On the phone, github_api calls api.github.com with it; on a Crabbox box, the app installs it so gh and git
 * push work there (crabbox.ts and CrabboxService).
 */
import { Type } from "@earendil-works/pi-ai";
import type { JsonValue } from "@earendil-works/chord";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { request } from "./bridge.ts";

type Status = { signedIn: boolean; login: string | null; name: string | null; scopes: string[] };

let status: Status = { signedIn: false, login: null, name: null, scopes: [] };

export async function refreshGitHub(): Promise<Status> {
	status = await request<Status>("github", "status");
	return status;
}

/** The signed-in login, or null. */
export function githubLogin(): string | null {
	return status.signedIn ? (status.login ?? "") : null;
}

type Reply = { status: number; body: JsonValue };

const api = defineTool({
	name: "github_api",
	description:
		"Calls the GitHub REST API (api.github.com) as the user, like `gh api`: repositories, issues, pull requests, reviews, workflow runs, file contents. The app adds the user's token; you never see it.",
	parameters: Type.Object({
		method: Type.Optional(Type.String({ description: "GET (default), POST, PATCH, PUT, or DELETE" })),
		path: Type.String({ description: "The path, starting with /, with any query string: /repos/OWNER/REPO/pulls?state=open" }),
		body: Type.Optional(Type.Unknown({ description: "The JSON body, for POST, PATCH, and PUT" })),
	}),
	// A change GitHub made is not made again when the call is resumed: its reply is kept.
	replay: "safe",
	execute: async (args, toolApi, context) => {
		const method = (args.method ?? "GET").toUpperCase();
		let reply = await toolApi.memo<Reply>("reply", context);
		if (!reply) {
			reply = await request<Reply>("github", "request", { method, path: args.path, body: args.body ?? null });
			await toolApi.memo<Reply>("reply", reply, context);
		}
		const text = typeof reply.body === "string" ? reply.body : JSON.stringify(reply.body, null, 1);
		const shown = text.length > 60_000 ? `${text.slice(0, 60_000)}\n… (${text.length - 60_000} more characters; ask for less, with per_page or a narrower path)` : text;
		return { content: [{ type: "text", text: `${method} ${args.path} → ${reply.status}\n${shown}` }], isError: reply.status >= 400 };
	},
});

/** Offered only while the user is signed in to GitHub (main.ts). */
export const GitHubTools = defineExtension({ name: "github", tools: [api] });
