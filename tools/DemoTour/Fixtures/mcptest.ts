/**
 * A test extension for testExtensionMCP: /mcptest calls an MCP server's echo tool from the extension's code (pi.mcp),
 * the mock server unless named ("/mcptest other"); /mcpservers lists the servers with this extension's permission. Each
 * shows what it got, or the error, as a notice.
 */
export default function (pi: any) {
	pi.registerCommand("mcptest", {
		description: "Call an MCP server's echo tool from code",
		handler: async (args: string, ctx: any) => {
			const server = args.trim() || "mock";
			try {
				const result = await pi.mcp.call(server, "echo", { text: "hello from code" });
				const text = (result.content ?? []).map((part: any) => part.text ?? "").join(" ");
				ctx.ui.notify(`mcp: ${text}`, "info");
			} catch (error) {
				ctx.ui.notify(`mcp error: ${(error as Error).message}`, "error");
			}
		},
	});
	pi.registerCommand("mcpservers", {
		description: "List the MCP servers with this extension's permission",
		handler: async (_args: string, ctx: any) => {
			const servers = await pi.mcp.servers();
			ctx.ui.notify(`servers: ${servers.map((server: any) => `${server.name}=${server.permission}:${server.tools.length}`).join(", ")}`, "info");
		},
	});
}
