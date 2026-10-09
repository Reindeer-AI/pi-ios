/**
 * `pi.location()` (iOS): the device's location for an extension, once the user allows that extension (the app asks the
 * first time and remembers; `ExtensionPermissions.swift`) and iOS allows pi. An extension's app page has the same
 * `pi.location()`, and getUserMedia for the camera and microphone, asked the same way.
 */
import { request } from "./bridge.ts";

export type DeviceLocation = { latitude: number; longitude: number; accuracy: number; altitude?: number; timestamp: number };

export function locationApi(extension: string): () => Promise<DeviceLocation> {
	return () => request<DeviceLocation>("device", "location", { requester: extension });
}
