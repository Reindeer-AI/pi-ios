/**
 * The part of node:http pi-ai's OAuth flows use: a loopback server that receives the browser's redirect. Backed by the
 * app's native `loopback` service (`LoopbackService.swift`), which listens on the loopback interface and forwards each
 * request here. Covers every server, request, and response member the flows use (see `auth/oauth/*` in pi-ai).
 */
import { onCommand, request } from "../bridge.ts";

type Listener = (...args: any[]) => void;

export class IncomingMessage {
	constructor(
		readonly method: string,
		readonly url: string,
		readonly headers: Record<string, string>,
	) {}
}

export class ServerResponse {
	private status = 200;
	private readonly headers: Record<string, string> = {};

	constructor(private readonly requestId: string) {}

	writeHead(status: number, headers?: Record<string, string>): this {
		this.status = status;
		Object.assign(this.headers, headers ?? {});
		return this;
	}

	end(body?: string): void {
		void request("loopback", "respond", {
			requestId: this.requestId,
			status: this.status,
			headers: this.headers,
			body: body ?? "",
		}).catch(() => {});
	}
}

const servers = new Map<string, Server>();

onCommand(
	"loopback.request",
	(params: { serverId: string; requestId: string; method: string; url: string; headers: Record<string, string> }) => {
		servers.get(params.serverId)?.receive(params);
	},
);

export class Server {
	private readonly listeners = new Map<string, Set<Listener>>();
	private serverId: string | undefined;
	private port = 0;

	constructor(private readonly handler: (request: IncomingMessage, response: ServerResponse) => void) {}

	on(event: string, listener: Listener): this {
		if (!this.listeners.has(event)) this.listeners.set(event, new Set());
		this.listeners.get(event)!.add(listener);
		return this;
	}

	once(event: string, listener: Listener): this {
		const wrapper: Listener = (...args) => {
			this.off(event, wrapper);
			listener(...args);
		};
		return this.on(event, wrapper);
	}

	off(event: string, listener: Listener): this {
		this.listeners.get(event)?.delete(listener);
		return this;
	}

	addListener(event: string, listener: Listener): this {
		return this.on(event, listener);
	}

	removeListener(event: string, listener: Listener): this {
		return this.off(event, listener);
	}

	/** Each native connection closes after its response, so there is nothing left to close. */
	closeAllConnections(): void {}

	listen(port: number, host: string, callback?: () => void): this {
		request<{ serverId: string; port: number }>("loopback", "listen", { port, host }).then(
			({ serverId, port: boundPort }) => {
				this.serverId = serverId;
				this.port = boundPort;
				servers.set(serverId, this);
				callback?.();
			},
			(error: unknown) => this.emit("error", error instanceof Error ? error : new Error(String(error))),
		);
		return this;
	}

	address(): { address: string; family: string; port: number } | null {
		return this.serverId ? { address: "127.0.0.1", family: "IPv4", port: this.port } : null;
	}

	close(callback?: () => void): this {
		if (this.serverId) {
			servers.delete(this.serverId);
			void request("loopback", "close", { serverId: this.serverId }).catch(() => {});
			this.serverId = undefined;
		}
		callback?.();
		return this;
	}

	receive(params: { requestId: string; method: string; url: string; headers: Record<string, string> }): void {
		this.handler(new IncomingMessage(params.method, params.url, params.headers), new ServerResponse(params.requestId));
	}

	private emit(event: string, ...args: unknown[]): void {
		for (const listener of [...(this.listeners.get(event) ?? [])]) listener(...args);
	}
}

export function createServer(handler: (request: IncomingMessage, response: ServerResponse) => void): Server {
	return new Server(handler);
}

export default { createServer, IncomingMessage, ServerResponse, Server };
