import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/pi-durable/storage/sqlite";
import { request } from "./bridge.ts";

/**
 * pi-durable `SqliteDatabase` backed by the app's native SQLite (`sqlite` service, `SQLiteService.swift`).
 *
 * Mirrors pi-durable's Node adapter: operations run in call order, a transaction holds the queue until it commits
 * or rolls back, and transaction handles expire when their callback settles. Native executes statements in arrival
 * order on one connection.
 */

/** Values as they cross the bridge; see `SQLiteService.swift`. */
type WireValue = null | number | string | { $bigint: string } | { $blob: string };

function encode(value: SqliteValue): WireValue {
	if (typeof value === "bigint") return { $bigint: value.toString() };
	if (value instanceof Uint8Array) {
		let binary = "";
		for (const byte of value) binary += String.fromCharCode(byte);
		return { $blob: btoa(binary) };
	}
	return value;
}

function decode(value: WireValue): SqliteValue {
	if (value === null || typeof value !== "object") return value;
	if ("$bigint" in value) return BigInt(value.$bigint);
	return Uint8Array.from(atob(value.$blob), (char) => char.charCodeAt(0));
}

function decodeRow<T>(row: Record<string, WireValue>): T {
	const decoded: Record<string, SqliteValue> = {};
	for (const [column, value] of Object.entries(row)) decoded[column] = decode(value);
	return decoded as T;
}

/**
 * Runs operations in call order; each waits for everything before it, and an operation holds the queue until it
 * settles. Every native call is asynchronous, so this is pi-durable's Node adapter queue without its synchronous
 * fast path.
 */
class SerialOperationQueue {
	private tail: Promise<unknown> = Promise.resolve();

	run<T>(operation: () => Promise<T>): Promise<T> {
		const settled = this.tail.then(operation);
		this.tail = settled.then(
			() => {},
			() => {},
		);
		return settled;
	}
}

class NativeExecutor implements SqliteExecutor {
	constructor(
		protected readonly db: string,
		private readonly guard: <T>(operation: () => Promise<T>) => Promise<T>,
	) {}

	exec(sql: string): Promise<void> {
		return this.guard(() => request("sqlite", "exec", { db: this.db, sql }));
	}

	run(sql: string, ...params: SqliteValue[]): Promise<void> {
		return this.guard(() => request("sqlite", "run", { db: this.db, sql, params: params.map(encode) }));
	}

	get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined> {
		return this.guard(async () => {
			const row = await request<Record<string, WireValue> | null>("sqlite", "get", {
				db: this.db,
				sql,
				params: params.map(encode),
			});
			return row === null ? undefined : decodeRow<T>(row);
		});
	}

	all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]> {
		return this.guard(async () => {
			const rows = await request<Record<string, WireValue>[]>("sqlite", "all", {
				db: this.db,
				sql,
				params: params.map(encode),
			});
			return rows.map((row) => decodeRow<T>(row));
		});
	}
}

export class NativeSqliteDatabase extends NativeExecutor implements SqliteDatabase {
	private readonly access: SerialOperationQueue;
	private closed = false;

	private constructor(db: string, access: SerialOperationQueue) {
		super(db, (operation) => access.run(operation));
		this.access = access;
	}

	/** Opens (or reopens) the named database. Reopening rolls back a transaction a previous engine left open. */
	static async open(name: string): Promise<NativeSqliteDatabase> {
		await request("sqlite", "open", { db: name });
		return new NativeSqliteDatabase(name, new SerialOperationQueue());
	}

	transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
		return this.access.run(async () => {
			await request("sqlite", "exec", { db: this.db, sql: "BEGIN IMMEDIATE" });
			const scope = { active: true };
			const handle = new NativeExecutor(this.db, (operation) => {
				if (!scope.active) return Promise.reject(new Error("SQLite transaction handle is no longer active"));
				return operation();
			});
			try {
				const result = await callback(handle);
				scope.active = false;
				await request("sqlite", "exec", { db: this.db, sql: "COMMIT" });
				return result;
			} catch (error) {
				scope.active = false;
				try {
					await request("sqlite", "exec", { db: this.db, sql: "ROLLBACK" });
				} catch (rollbackError) {
					throw new AggregateError([error, rollbackError], "SQLite transaction failed and rollback failed");
				}
				throw error;
			}
		});
	}

	close(): Promise<void> {
		return this.access.run(async () => {
			if (this.closed) return;
			this.closed = true;
			await request("sqlite", "close", { db: this.db });
		});
	}
}
