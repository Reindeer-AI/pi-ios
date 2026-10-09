/**
 * pi-durable's coding tools with a `read` that also looks at images, as pi's does: an image (JPEG, PNG, GIF, WebP, or
 * HEIC and anything else iOS decodes) comes back as image content, scaled natively to 2048 pixels at most (pi-durable's
 * own `read` refuses images). pi-ai shows it to a model that takes images, and tells one that doesn't.
 */
import { defineExtension, type ToolRegistration } from "@earendil-works/pi-durable";
import { getOrThrow } from "@earendil-works/pi-durable/env";
import { createBashTool, createEditTool, createReadTool, createWriteTool } from "@earendil-works/pi-durable/tools";
import { request } from "./bridge.ts";

type Prepared = { data: string; mimeType: string; width: number; height: number; originalWidth: number; originalHeight: number };

/** Images pi-durable's `read` doesn't recognize but iOS decodes (its own check covers JPEG, PNG, GIF and WebP). */
const OTHER_IMAGES = /\.(heic|heif|avif|tiff?|bmp)$/i;

function readWithImages(): ToolRegistration {
	const read = createReadTool() as ToolRegistration;
	return {
		...read,
		description: `${read.description} Images (JPEG, PNG, GIF, WebP, HEIC) are shown to you, scaled to 2048 pixels at most.`,
		async execute(args: { path: string; offset?: number; limit?: number }, api, context) {
			const image = OTHER_IMAGES.test(args.path);
			const result = image ? undefined : await read.execute(args as never, api, context);
			if (result && !(result.isError && result.diagnostics?.some((diagnostic) => diagnostic.code === "unsupported_image"))) return result;
			if (!api.env) throw new Error("No execution environment is configured");
			const path = getOrThrow(await api.env.absolutePath(args.path.replace(/^@/, ""), context));
			const prepared = await request<Prepared>("images", "prepare", { path, maxPixels: 2048 });
			const scaled = prepared.width !== prepared.originalWidth ? `, shown at ${prepared.width}×${prepared.height}` : "";
			return {
				content: [
					{ type: "text", text: `${args.path}: an image, ${prepared.originalWidth}×${prepared.originalHeight}${scaled}.` },
					{ type: "image", data: prepared.data, mimeType: prepared.mimeType },
				],
			};
		},
	} as ToolRegistration;
}

/** `read` (with images), `write`, `edit` and `bash`. */
export const CodingTools = defineExtension({
	name: "coding-tools",
	tools: [readWithImages(), createWriteTool(), createEditTool(), createBashTool()],
});
