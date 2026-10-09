import type {
	AuthEvent,
	AuthInteraction,
	AuthPrompt,
	AuthType,
	Credential,
	CredentialInfo,
	CredentialStore,
} from "@earendil-works/pi-ai";
import type { MutableModels } from "@earendil-works/pi-ai/models";
import { emit, onCommand, request } from "./bridge.ts";

/**
 * pi-ai credentials in the iOS Keychain (`keychain` service, `KeychainService.swift`), one item per provider.
 * `modify` is serialized per provider, so a token refresh and a login cannot overwrite each other.
 */
export class NativeCredentialStore implements CredentialStore {
	private readonly queues = new Map<string, Promise<unknown>>();

	async read(providerId: string): Promise<Credential | undefined> {
		const stored = await request<string | null>("keychain", "get", { account: providerId });
		return stored ? (JSON.parse(stored) as Credential) : undefined;
	}

	async list(): Promise<readonly CredentialInfo[]> {
		const accounts = await request<string[]>("keychain", "list");
		const infos: CredentialInfo[] = [];
		for (const providerId of accounts.filter((account) => !account.startsWith("pimobile."))) {
			const credential = await this.read(providerId);
			if (credential) infos.push({ providerId, type: credential.type });
		}
		return infos;
	}

	modify(
		providerId: string,
		fn: (current: Credential | undefined) => Promise<Credential | undefined>,
	): Promise<Credential | undefined> {
		const previous = this.queues.get(providerId) ?? Promise.resolve();
		const next = previous.then(async () => {
			const current = await this.read(providerId);
			const updated = await fn(current);
			if (updated === undefined) return current;
			await request("keychain", "set", { account: providerId, value: JSON.stringify(updated) });
			return updated;
		});
		this.queues.set(
			providerId,
			next.catch(() => {}),
		);
		return next;
	}

	async delete(providerId: string): Promise<void> {
		await request("keychain", "delete", { account: providerId });
	}
}

/** A stable installation ID some login flows send (e.g. OpenAI's agent host ID), kept in the Keychain. */
export async function loadDeviceId(): Promise<string> {
	const account = "pimobile.device-id";
	const stored = await request<string | null>("keychain", "get", { account });
	if (stored) return stored;
	const id = crypto.randomUUID();
	await request("keychain", "set", { account, value: id });
	return id;
}

type PendingPrompt = { resolve: (value: string) => void; reject: (error: Error) => void };

const pendingPrompts = new Map<string, PendingPrompt>();
let activeLogin: AbortController | undefined;
let nextPromptId = 0;

onCommand("auth.respond", ({ promptId, value }: { promptId: string; value?: string }) => {
	const pending = pendingPrompts.get(promptId);
	if (!pending) return;
	pendingPrompts.delete(promptId);
	if (value === undefined) pending.reject(new Error("Cancelled"));
	else pending.resolve(value);
});

onCommand("auth.cancel", () => {
	activeLogin?.abort();
});

/**
 * Runs one of pi-ai's own login flows. Its prompts and events go to the native UI as `auth_prompt` / `auth_event`
 * engine events; native answers prompts with `auth.respond`. Resolves when the login settles (`auth_done` or
 * `auth_failed` is also emitted).
 */
export async function runLogin(
	models: MutableModels,
	providerId: string,
	type: AuthType,
	deviceId: string,
): Promise<{ ok: boolean; message?: string }> {
	activeLogin?.abort();
	const controller = new AbortController();
	activeLogin = controller;
	const interaction: AuthInteraction = {
		signal: controller.signal,
		prompt: (prompt: AuthPrompt) =>
			new Promise<string>((resolve, reject) => {
				const promptId = `prompt-${++nextPromptId}`;
				pendingPrompts.set(promptId, { resolve, reject });
				prompt.signal?.addEventListener("abort", () => {
					if (!pendingPrompts.delete(promptId)) return;
					emit({ type: "auth_prompt_closed", providerId, promptId });
					reject(new Error("Prompt closed"));
				});
				const { signal: _signal, ...shown } = prompt;
				emit({ type: "auth_prompt", providerId, promptId, prompt: shown });
			}),
		notify: (event: AuthEvent) => emit({ type: "auth_event", providerId, event }),
	};
	try {
		await models.login(providerId, type, interaction, { getDeviceId: () => deviceId });
		emit({ type: "auth_done", providerId });
		return { ok: true };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		emit({ type: "auth_failed", providerId, message });
		return { ok: false, message };
	} finally {
		if (activeLogin === controller) activeLogin = undefined;
		for (const [promptId, pending] of pendingPrompts) {
			pending.reject(new Error("Login ended"));
			pendingPrompts.delete(promptId);
		}
	}
}
