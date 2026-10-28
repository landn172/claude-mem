import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { ChangesOutcome, PushOutcome, SyncHub } from "../src/do/SyncHub";
import { observationOp } from "./content-v2-helpers";

/**
 * Every call a client makes on each poll must read O(page) rows, not O(log).
 * Free-plan Durable Objects allow 5M rows read per day; a scan over a 20K-op
 * log on each poll exhausts that in about an hour.
 */
const LOG_SIZE = 3_000;
const SEED_BATCH = 500;
const TAIL = 10;
/** Fixed allowance for meta/devices/entity_heads lookups on top of the page. */
const OVERHEAD = 60;

function hub(name: string) {
	return env.SYNC_HUB.getByName(name);
}

function pushed(outcome: PushOutcome): void {
	if ("refused" in outcome) throw new Error(`unexpected refusal: ${outcome.error}`);
}

function opsOf(outcome: ChangesOutcome): unknown[] {
	if ("refused" in outcome) throw new Error(`unexpected refusal: ${outcome.error}`);
	return outcome.ops;
}

async function seed(name: string) {
	const stub = hub(name);
	for (let start = 1; start <= LOG_SIZE; start += SEED_BATCH) {
		const batch = await Promise.all(
			Array.from({ length: SEED_BATCH }, (_, index) => observationOp(String(start + index))),
		);
		pushed(await stub.pushOps("dev-a", batch));
	}
	return stub;
}

/** Sums rowsRead over every statement `run` issues. */
async function rowsReadBy<T>(
	stub: ReturnType<typeof hub>,
	run: (instance: SyncHub) => T | Promise<T>,
): Promise<{ result: T; rowsRead: number }> {
	return runInDurableObject(stub, async (instance: SyncHub, state) => {
		const sql = state.storage.sql;
		const originalExec = sql.exec.bind(sql);
		const cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[] = [];
		(sql as { exec: typeof sql.exec }).exec = ((query: string, ...bindings: unknown[]) => {
			const cursor = originalExec(query, ...bindings);
			cursors.push(cursor);
			return cursor;
		}) as typeof sql.exec;
		try {
			const result = await run(instance);
			return { result, rowsRead: cursors.reduce((sum, cursor) => sum + cursor.rowsRead, 0) };
		} finally {
			(sql as { exec: typeof sql.exec }).exec = originalExec;
		}
	});
}

describe(`rows-read budget on a ${LOG_SIZE}-op log`, () => {
	it("status reads a constant number of rows", async () => {
		const stub = await seed("budget-status");
		const { rowsRead } = await rowsReadBy(stub, (instance) => instance.getStatus("dev-reader"));
		expect(rowsRead).toBeLessThan(OVERHEAD);
	});

	it("pulling the tail reads about the returned page", async () => {
		const stub = await seed("budget-pull");
		const tail = await rowsReadBy(stub, (instance) =>
			instance.getChanges("dev-reader", String(LOG_SIZE - TAIL), 500));
		expect(opsOf(tail.result)).toHaveLength(TAIL);
		expect(tail.rowsRead).toBeLessThan(TAIL * 2 + OVERHEAD);

		const caughtUp = await rowsReadBy(stub, (instance) =>
			instance.getChanges("dev-reader", String(LOG_SIZE), 500));
		expect(opsOf(caughtUp.result)).toHaveLength(0);
		expect(caughtUp.rowsRead).toBeLessThan(OVERHEAD);
	});

	it("pushing one op reads a constant number of rows", async () => {
		const stub = await seed("budget-push");
		const op = await observationOp(String(LOG_SIZE + 1));
		const { result, rowsRead } = await rowsReadBy(stub, (instance) => instance.pushOps("dev-a", [op]));
		pushed(result);
		expect(rowsRead).toBeLessThan(OVERHEAD);
	});

	it("projecting the newest ops reads about the projected page", async () => {
		const stub = await seed("budget-projection");
		const behind = String(LOG_SIZE - TAIL);
		const setup = await stub.acquireProjectionLease(behind);
		await stub.advanceProjectionCheckpoint(setup.lease_token!, setup.epoch, "0", behind);
		await stub.releaseProjectionLease(setup.lease_token!);

		const { result, rowsRead } = await rowsReadBy(stub, (instance) => {
			instance.getProjectionState();
			const lease = instance.acquireProjectionLease(String(LOG_SIZE));
			const page = instance.getProjectionPage(lease.lease_token!, String(LOG_SIZE), "budget-projection");
			instance.advanceProjectionCheckpoint(lease.lease_token!, lease.epoch, behind, page.through_seq);
			instance.releaseProjectionLease(lease.lease_token!);
			return page;
		});
		expect(result.ops).toHaveLength(TAIL);
		expect(rowsRead).toBeLessThan(TAIL * 2 + OVERHEAD);
	});
});
