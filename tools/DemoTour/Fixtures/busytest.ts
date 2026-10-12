/**
 * A test extension for testExtensionStop: /busywait works for 30 seconds, as a slow command does (asynchronously),
 * unless stopped (it honors ctx.signal); /busyignore does the same but ignores Stop; /busyexec runs sleep 30 through
 * pi.exec with ctx.signal; /busyblock holds the engine itself for 8 seconds (code that never yields), /busyfreeze for 60
 * (the app's watchdog replaces the engine's page and turns busytest off). Each says how it ended, as a notice.
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
	pi.registerCommand("busyexec", {
		description: "Run sleep 30 through pi.exec, passing Stop on",
		handler: async (_args: string, ctx: any) => {
			const result = await pi.exec("sleep", ["30"], { signal: ctx.signal });
			ctx.ui.notify(result.killed ? "busyexec: stopped" : `busyexec: exited ${result.code}`, "info");
		},
	});
	pi.registerCommand("busyfreeze", {
		description: "Hold the engine for 60 seconds",
		handler: async (_args: string, ctx: any) => {
			const end = Date.now() + 60000;
			while (Date.now() < end) {
				// Never yields: the app's watchdog replaces the engine's page.
			}
			ctx.ui.notify("busyfreeze: done", "info");
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
