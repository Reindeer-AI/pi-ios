/**
 * A test extension for testExtensionStop: /busywait works for 30 seconds, as a slow command does (asynchronously),
 * unless stopped (it honors ctx.signal); /busyignore does the same but ignores Stop; /busyblock holds the engine itself
 * for 8 seconds (code that never yields). Each says how it ended, as a notice.
 */
export default function (pi: any) {
	pi.registerCommand("busywait", {
		description: "Work for 30 seconds, unless stopped",
		handler: async (_args: string, ctx: any) => {
			await new Promise<void>((resolve) => {
				const timer = setTimeout(resolve, 30000);
				ctx.signal?.addEventListener("abort", () => {
					clearTimeout(timer);
					resolve();
				});
			});
			ctx.ui.notify(ctx.signal?.aborted ? "busywait: stopped" : "busywait: done", "info");
		},
	});
	pi.registerCommand("busyignore", {
		description: "Work for 30 seconds, ignoring Stop",
		handler: async (_args: string, ctx: any) => {
			await new Promise((resolve) => setTimeout(resolve, 30000));
			ctx.ui.notify("busyignore: done", "info");
		},
	});
	pi.registerCommand("busyblock", {
		description: "Hold the engine for 8 seconds",
		handler: async (_args: string, ctx: any) => {
			const end = Date.now() + 8000;
			while (Date.now() < end) {
				// Never yields: nothing else in the engine runs meanwhile.
			}
			ctx.ui.notify("busyblock: done", "info");
		},
	});
}
