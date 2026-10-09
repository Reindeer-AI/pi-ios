/**
 * `pi.synced` (iOS): an extension's small JSON values that follow the user to their other devices, through iCloud
 * Keychain (the app's `synced` service, merged key by key: a value set on one device and another set elsewhere both
 * stay). Synchronous, like the files it replaces. Keep each record under its own key, so devices merge records rather
 * than overwrite each other's lists.
 */
import { syncRequest } from "./sync.ts";

export function syncedApi(extension: string) {
	const call = <T>(method: string, params: Record<string, unknown> = {}) => syncRequest<T>("synced", method, { requester: extension, ...params });
	return {
		/** The value kept under `key`, if any. */
		get<T = unknown>(key: string): T | undefined {
			const text = call<string | null>("get", { key });
			return text == null ? undefined : (JSON.parse(text) as T);
		},
		/** Keeps a JSON value under `key` (on every device). */
		set(key: string, value: unknown): void {
			call("set", { key, value: JSON.stringify(value) });
		},
		/** Removes `key` (on every device). */
		delete(key: string): void {
			call("delete", { key });
		},
		/** The extension's keys. */
		keys(): string[] {
			return call<string[]>("keys");
		},
	};
}
