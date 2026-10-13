/**
 * A test extension for testHomeScreenWidget: an app (Flights) and its Home Screen widget. /widgettest draws the widget
 * and opens the app; the widget's flight is a tap area whose target ("LY315") the app shows (onWidgetOpen). Its refresh
 * button runs the "refresh" action in pi without opening it, which draws the widget again ("Draw N" counts the draws
 * since the extension loaded); Details shows another look, and Back the main one. /widgetbad draws a layout pi refuses.
 * For testLiveActivity: /activitystart, /activityupdate and /activityend show the flight as a Live Activity, whose
 * refresh button (in the expanded Dynamic Island) runs the "activityRefresh" action in pi.
 */

// One module for every instance of the extension (the sessions' and the one actions run in).
let draws = 0;
let target = "none";
let activityRefreshes = 0;
const boardsAt = Date.now() + 2 * 3600_000;

function activityLook(status: string) {
	return {
		lockScreen: {
			type: "hstack",
			spacing: 12,
			color: "white",
			children: [
				{ type: "symbol", name: "airplane.departure", font: "title2" },
				{
					type: "vstack",
					alignment: "leading",
					children: [
						{ type: "text", text: "LY315 to London", font: "headline" },
						{ type: "text", text: status, font: "subheadline", opacity: 0.85 },
					],
				},
				{ type: "spacer" },
				{ type: "date", date: boardsAt, style: "timer", font: "title3", monospacedDigit: true, align: "trailing", frame: { width: 90 } },
			],
		},
		compactTrailing: { type: "text", text: "B7", font: "caption", weight: "bold", color: "orange" },
		expanded: {
			leading: { type: "hstack", spacing: 6, children: [{ type: "symbol", name: "airplane.departure" }, { type: "text", text: "LY315", font: "headline" }] },
			trailing: { type: "text", text: "Gate B7", font: "headline" },
			bottom: {
				type: "hstack",
				children: [
					{ type: "text", text: status },
					{ type: "spacer" },
					{ type: "button", action: "activityRefresh", accessibility: "Refresh activity", children: [{ type: "symbol", name: "arrow.clockwise", font: "title3" }] },
				],
			},
		},
		background: { gradient: "linear", colors: ["#0B3D91", "#1E88E5"], from: "leading", to: "trailing" },
		tint: "orange",
	};
}

export default function (pi: any) {
	const flight = (size: string) => ({ type: "text", text: "TLV → LHR", font: size, weight: "bold", design: "rounded", open: "LY315" });
	const boards = { type: "date", date: Date.now() + 2 * 3600_000, style: "timer", monospacedDigit: true };
	const refresh = (size: string) => ({
		type: "button",
		action: "refresh",
		value: { from: "widget" },
		accessibility: "Refresh flights",
		children: [{ type: "symbol", name: "arrow.clockwise", font: size, weight: "semibold" }],
	});
	const background = { gradient: "linear", colors: ["#0B3D91", "#1E88E5"], from: "topLeading", to: "bottomTrailing" };

	async function draw() {
		draws += 1;
		return pi.widget.update({
			small: {
				type: "vstack",
				alignment: "leading",
				spacing: 4,
				color: "white",
				frame: { maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" },
				children: [
					{ type: "hstack", children: [{ type: "symbol", name: "airplane.departure", font: "title2" }, { type: "spacer" }, refresh("headline")] },
					{ type: "spacer" },
					flight("headline"),
					{
						type: "hstack",
						font: "caption",
						children: [
							{ type: "text", text: `Draw ${draws}`, loading: true },
							{ type: "spacer" },
							{ type: "button", show: "details", children: [{ type: "text", text: "Details", weight: "bold" }] },
						],
					},
				],
			},
			layout: {
				type: "vstack",
				alignment: "leading",
				spacing: 6,
				color: "white",
				frame: { maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" },
				children: [
					{
						type: "hstack",
						children: [
							{ type: "symbol", name: "airplane.departure", font: "headline" },
							{ type: "text", text: "Next flight", font: "headline" },
							{ type: "spacer" },
							{ type: "text", text: `Draw ${draws}`, font: "caption", opacity: 0.8, loading: true },
							refresh("subheadline"),
						],
					},
					flight("title"),
					{ type: "hstack", spacing: 4, font: "subheadline", children: [{ type: "text", text: "Boards in" }, boards] },
					{ type: "spacer" },
					{ type: "progress", value: 0.4, tint: "white" },
				],
			},
			rectangular: { type: "vstack", alignment: "leading", children: [flight("headline"), boards] },
			background,
			views: {
				details: {
					layout: {
						type: "vstack",
						alignment: "leading",
						spacing: 4,
						color: "white",
						frame: { maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" },
						children: [
							{ type: "text", text: "Gate B7", font: "title2", weight: "bold" },
							{ type: "text", text: "Seat 14A", font: "subheadline" },
							{ type: "spacer" },
							{ type: "button", show: null, children: [{ type: "symbol", name: "chevron.backward" }, { type: "text", text: "Back", weight: "bold" }] },
						],
					},
					background,
				},
			},
		});
	}

	pi.widget.onAction("refresh", async ({ value, signal }: { value: any; signal: AbortSignal }) => {
		if (signal.aborted || value?.from !== "widget") return;
		await draw();
	});

	pi.widget.onAction("activityRefresh", async () => {
		activityRefreshes += 1;
		const [current] = await pi.liveActivity.list();
		await current?.update(activityLook(`Refreshed ${activityRefreshes}`));
	});

	const activityCommand = (name: string, run: () => Promise<string>) =>
		pi.registerCommand(name, {
			description: `Live Activity test: ${name}`,
			handler: async (_args: string, ctx: any) => {
				try {
					ctx.ui.notify(await run(), "info");
				} catch (error) {
					ctx.ui.notify(`activity error: ${(error as Error).message}`, "error");
				}
			},
		});
	activityCommand("activitystart", async () => {
		for (const running of await pi.liveActivity.list()) await running.end({ dismiss: "now" });
		const activity = await pi.liveActivity.start(activityLook("Boarding soon"));
		return activity ? `activity started ${activity.app}` : "activity unavailable";
	});
	activityCommand("activityupdate", async () => {
		const [current] = await pi.liveActivity.list();
		await current.update(activityLook("Boarding now"), { alert: { title: "LY315", body: "Boarding now at gate B7" } });
		return "activity updated";
	});
	activityCommand("activityend", async () => {
		const running = await pi.liveActivity.list();
		for (const each of running) await each.end({ final: activityLook("Departed"), dismiss: "now" });
		return `activity ended ${running.length}`;
	});

	pi.registerApp({
		name: "board",
		title: "Flights",
		icon: "airplane",
		description: "Upcoming flights",
		render: () =>
			`<!doctype html><html><head><meta name="viewport" content="width=device-width"></head>` +
			`<body style="font: 17px -apple-system; padding: 70px 20px; margin: 0"><h1>Flights board</h1>` +
			`<p>target: ${target}</p><p>draws: ${draws}</p></body></html>`,
		onWidgetOpen: async (to: string, app: any) => {
			target = to;
			await app.refresh();
		},
	});

	pi.registerCommand("widgettest", {
		description: "Draw the Flights widget and open the app",
		handler: async (_args: string, ctx: any) => {
			try {
				const saved = await draw();
				ctx.ui.notify(`widget drawn ${draws}${saved ? "" : " (not saved)"}`, "info");
				await pi.apps.open("board");
			} catch (error) {
				ctx.ui.notify(`widget error: ${(error as Error).message}`, "error");
			}
		},
	});

	pi.registerCommand("widgetbad", {
		description: "Draw a layout pi refuses",
		handler: async (_args: string, ctx: any) => {
			try {
				await pi.widget.update({ layout: { type: "vstack", children: [{ type: "txt", text: "typo" }] } });
				ctx.ui.notify("widget error: none", "error");
			} catch (error) {
				ctx.ui.notify(`widget error: ${(error as Error).message}`, "error");
			}
		},
	});
}
