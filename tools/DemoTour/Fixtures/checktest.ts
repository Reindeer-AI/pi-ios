/**
 * A test extension for testBackgroundCheck: a background check that posts a notification saying when it ran.
 */
export default function (pi: any) {
	pi.registerCheck({
		name: "heartbeat",
		description: "Says when it ran",
		every: 15,
		async run() {
			const time = new Date().toISOString().slice(11, 19);
			await pi.notify({ title: "checktest", body: `Background check ran at ${time}` });
			return `notified at ${time}`;
		},
	});
}
