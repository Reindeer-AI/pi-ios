/**
 * A test extension for testBackgroundCheck and testNotificationTap: a background check that posts a notification saying
 * when it ran; /notifyme posts one that leads back to its session, /notifyask one that sends its session a message, and
 * /notifyprompt one that opens a new session with a message.
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
	pi.registerCommand("notifyme", {
		description: "A notification that leads back to this session",
		// After 8 seconds, so the test has left the session (an alert up while it taps would be dismissed).
		handler: async () => {
			setTimeout(() => void pi.notify({ title: "checktest", body: "Back to the session" }), 8000);
		},
	});
	pi.registerCommand("notifyask", {
		description: "A notification that sends this session a message",
		handler: async () => {
			setTimeout(() => void pi.notify({ title: "checktest", body: "Tap to ask here", prompt: "Reply with exactly the word here, in lowercase, and nothing else." }), 8000);
		},
	});
	pi.registerCommand("notifyprompt", {
		description: "A notification that opens a new session with a message",
		handler: async () => {
			setTimeout(() => void pi.notify({ title: "checktest", body: "Tap to ask pi", session: "new", prompt: "Reply with exactly the word tapped, in lowercase, and nothing else." }), 8000);
		},
	});
}
