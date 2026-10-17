/**
 * A test extension for testLongSessionTyping: /flood N fills the session with N messages (Markdown with a heading,
 * bold, a link, a list, and a code block, as answers have), named "Flood test" to find it again.
 */
export default function (pi: any) {
	pi.registerCommand("flood", {
		description: "Fill the session with N messages",
		handler: async (args: string, ctx: any) => {
			const count = Number(args.trim()) || 2000;
			pi.setSessionName("Flood test");
			for (let index = 0; index < count; index++) {
				pi.sendMessage({
					customType: "flood",
					display: true,
					content:
						`## Entry ${index}\n\nSome **bold** text, a [link](https://example.com), and \`inline code\`, then a list:\n\n` +
						`- the first point, with *emphasis*\n- the second point\n- a third, longer point that wraps onto a second line on a phone\n\n` +
						"```js\nconst total = values.reduce((sum, value) => sum + value, 0);\nconsole.log(total);\n```",
				});
				if (index % 50 === 49) await new Promise((resolve) => setTimeout(resolve, 0));
			}
			ctx.ui.notify(`flooded ${count}`, "info");
		},
	});
}
