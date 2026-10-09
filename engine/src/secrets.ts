/**
 * Secrets for extensions (Settings → Extensions → Secrets, kept in the Keychain by the app's native `secrets` service).
 * An extension reads the secrets it may see as `process.env.NAME` (in its child_process and pi.exec commands too) and
 * through `pi.secrets` / `ctx.secrets`, an iOS addition; it can store one for itself. The agent's shell, its prompt, and
 * the session's files never get them.
 */
import { request } from "./bridge.ts";

type Secret = { name: string; value: string; extensions: string[] | null; owner: string | null };

let secrets: Secret[] = [];

export async function refreshSecrets(): Promise<void> {
	secrets = await request<Secret[]>("secrets", "all");
}

/** The extension's own name, from its registry name (`default:name`, `session:7:name`). */
export function extensionOf(registryName: string): string {
	return registryName.replace(/^default:/, "").replace(/^session:\d+:/, "");
}

function visible(secret: Secret, extension: string): boolean {
	return secret.owner === extension || secret.extensions === null || secret.extensions.includes(extension);
}

/** The secrets an extension may read, as environment variables. */
export function secretEnv(extension: string): Record<string, string> {
	const env: Record<string, string> = {};
	for (const secret of secrets) if (visible(secret, extension)) env[secret.name] = secret.value;
	return env;
}

/** An extension's `process.env`: `base` plus the secrets it may read, current as the user changes them. */
export function withSecrets(base: Record<string, string>, extension: string): Record<string, string> {
	const secret = (key: string | symbol) => (typeof key === "string" && !(key in base) ? secretEnv(extension)[key] : undefined);
	return new Proxy(base, {
		get: (target, key) => secret(key) ?? Reflect.get(target, key),
		has: (target, key) => Reflect.has(target, key) || secret(key) !== undefined,
		ownKeys: (target) => [...new Set([...Reflect.ownKeys(target), ...Object.keys(secretEnv(extension))])],
		getOwnPropertyDescriptor: (target, key) => {
			const value = secret(key);
			return value === undefined ? Reflect.getOwnPropertyDescriptor(target, key) : { value, enumerable: true, configurable: true, writable: true };
		},
	});
}

/** `pi.secrets` / `ctx.secrets` for one extension. */
export function secretsApi(extension: string) {
	return {
		/** A secret this extension may read (one the user gave it or all extensions, or one it stored), or undefined. */
		get: async (name: string): Promise<string | undefined> => secrets.find((secret) => secret.name === name && visible(secret, extension))?.value,
		/** Stores a secret for this extension only (the user sees it in Settings, and can remove it). */
		set: async (name: string, value: string): Promise<void> => {
			const existing = secrets.find((secret) => secret.name === name);
			if (existing && existing.owner !== extension && !visible(existing, extension)) throw new Error(`secret ${name} belongs to another extension`);
			await request("secrets", "set", { name, value, extensions: existing?.extensions ?? [extension], owner: existing?.owner ?? extension });
			await refreshSecrets();
		},
		/** Removes a secret this extension stored. */
		delete: async (name: string): Promise<void> => {
			const existing = secrets.find((secret) => secret.name === name);
			if (!existing) return;
			if (existing.owner !== extension) throw new Error(`secret ${name} was not stored by this extension; the user removes it in Settings`);
			await request("secrets", "delete", { name });
			await refreshSecrets();
		},
		/** The names of the secrets this extension may read. */
		list: async (): Promise<string[]> => secrets.filter((secret) => visible(secret, extension)).map((secret) => secret.name),
	};
}
