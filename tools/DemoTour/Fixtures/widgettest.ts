/**
 * A test extension for testHomeScreenWidget: an app (Flights) and its Home Screen widget. /widgettest draws the widget
 * (a count of draws in it) and opens the app; the widget's flight is a tap area whose target ("LY315") the app shows
 * (onWidgetOpen). /widgetbad draws a layout pi refuses, and shows the error.
 */
export default function (pi: any) {
	let draws = 0;
	let target = "none";
	const flight = (size: string) => ({ type: "text", text: "TLV → LHR", font: size, weight: "bold", design: "rounded", open: "LY315" });
	const boards = { type: "date", date: Date.now() + 2 * 3600_000, style: "timer", monospacedDigit: true };

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
					{ type: "symbol", name: "airplane.departure", font: "title2" },
					{ type: "spacer" },
					flight("headline"),
					{ type: "hstack", spacing: 4, font: "caption", children: [{ type: "text", text: "Boards in" }, boards] },
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
							{ type: "text", text: `#${draws}`, font: "caption", opacity: 0.8 },
						],
					},
					flight("title"),
					{ type: "hstack", spacing: 4, font: "subheadline", children: [{ type: "text", text: "Boards in" }, boards] },
					{ type: "spacer" },
					{ type: "progress", value: 0.4, tint: "white" },
				],
			},
			rectangular: { type: "vstack", alignment: "leading", children: [flight("headline"), boards] },
			background: { gradient: "linear", colors: ["#0B3D91", "#1E88E5"], from: "topLeading", to: "bottomTrailing" },
		});
	}

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
