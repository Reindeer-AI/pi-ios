/**
 * `pi.location()` (iOS): the device's location for an extension, once the user allows that extension (the app asks the
 * first time and remembers; `ExtensionPermissions.swift`) and iOS allows pi. An extension's app page has the same
 * `pi.location()`, and getUserMedia for the camera and microphone, asked the same way. `pi.notify()` posts a
 * notification, asked the same way.
 */
import { request } from "./bridge.ts";

export type DeviceLocation = { latitude: number; longitude: number; accuracy: number; altitude?: number; timestamp: number };

export function locationApi(extension: string): () => Promise<DeviceLocation> {
	return () => request<DeviceLocation>("device", "location", { requester: extension });
}

/**
 * What tapping it does. `session`: the session it opens, a session's id (from a session, that session unless given), or
 * "new". `prompt`: a message that session gets when the user taps (a new session when there's none to go to, as from a
 * background check).
 */
export type DeviceNotification = { title: string; body?: string; session?: number | "new"; prompt?: string };

/** `pi.notify({ title, body, session?, prompt? })`: a notification from the extension, once the user allows them. */
export function notifyApi(extension: string, conversationId?: number): (notification: DeviceNotification) => Promise<void> {
	return async (notification) => {
		const session = notification?.session === "new" ? undefined : typeof notification?.session === "number" ? notification.session : conversationId;
		const prompt = typeof notification?.prompt === "string" && notification.prompt.trim() ? notification.prompt : undefined;
		await request("device", "notify", {
			requester: extension,
			title: String(notification?.title ?? ""),
			body: String(notification?.body ?? ""),
			...(session !== undefined ? { session } : {}),
			...(prompt ? { prompt } : {}),
		});
	};
}
