/**
 * A test extension for testEngineFreezeOnLoad: loading it holds the engine for 60 seconds (top-level code that never
 * yields), so the app's watchdog replaces the engine's page and turns it off rather than load it again.
 */
const end = Date.now() + 60000;
while (Date.now() < end) {
	// Never yields.
}

export default function (pi: any) {
	pi.registerCommand("loadfreeze", { description: "Loaded at last", handler: async () => {} });
}
