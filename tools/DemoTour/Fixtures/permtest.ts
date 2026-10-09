/**
 * A test extension for testExtensionPermissions: an app whose page asks for the microphone (getUserMedia) and the
 * location (pi.location()), and shows what it got. /permtest opens it; /permwhere shows the location from the extension's
 * own code.
 */
export default function (pi: any) {
	pi.registerApp({
		name: "permtest",
		title: "Permission test",
		icon: "checkmark.shield",
		description: "Asks for the microphone and the location",
		render: () => `<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<body style="font: 17px -apple-system; padding: 16px">
<button id="mic" style="font-size: 20px">Microphone</button>
<button id="loc" style="font-size: 20px">Location</button>
<p id="out">ready</p>
<script>
const out = document.getElementById("out");
document.getElementById("mic").onclick = async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    out.textContent = "mic: granted " + stream.getAudioTracks().length;
    stream.getTracks().forEach((track) => track.stop());
  } catch (error) {
    out.textContent = "mic: " + error.name + " " + error.message;
  }
};
document.getElementById("loc").onclick = async () => {
  try {
    const where = await pi.location();
    out.textContent = "location: " + where.latitude.toFixed(2) + "," + where.longitude.toFixed(2);
  } catch (error) {
    out.textContent = "location error: " + error.message;
  }
};
</script>`,
	});
	pi.registerCommand("permtest", {
		description: "Open the permission test",
		handler: async () => {
			await pi.apps.open("permtest");
		},
	});
	// The same from the extension's own code (the engine), not its page.
	pi.registerCommand("permwhere", {
		description: "Show the location, from the extension's code",
		handler: async (_args: string, ctx: any) => {
			try {
				const where = await pi.location();
				ctx.ui.notify(`where: ${where.latitude.toFixed(2)},${where.longitude.toFixed(2)}`, "info");
			} catch (error) {
				ctx.ui.notify(`where error: ${(error as Error).message}`, "error");
			}
		},
	});
}
