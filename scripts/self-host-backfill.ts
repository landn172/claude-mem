/**
 * One-shot opt-in for SELF-HOSTED sync deployments: upload the pre-launch
 * local corpus by clearing the launch exclusion ledger (migration v47,
 * SessionStore.initializeSyncHubLaunchBaseline) and re-nulling synced_at on
 * NATIVE rows. The ordinary CloudSync drain then pushes everything.
 *
 * Run it ONCE, on ONE machine only (the one with the fullest history), with
 * the worker stopped. Backfilling from a second machine would upload any
 * overlapping history as distinct entities (stable ids are per-device) and
 * duplicate it everywhere.
 *
 *   bun scripts/self-host-backfill.ts [--db <path>] [--force]
 */

import { Database } from 'bun:sqlite';
import { existsSync, readFileSync } from 'fs';

const TABLES = ['observations', 'session_summaries', 'user_prompts'] as const;

export interface BackfillResult {
  exclusionsCleared: number;
  requeued: Record<(typeof TABLES)[number], number>;
}

/**
 * Rows replicated from other devices (origin_device_id set) are never
 * touched: re-nulling them would re-push foreign entities under this
 * device's push lane and duplicate them hub-wide.
 */
export function backfillPreLaunchHistory(db: Database): BackfillResult {
  const result: BackfillResult = {
    exclusionsCleared: 0,
    requeued: { observations: 0, session_summaries: 0, user_prompts: 0 },
  };
  // COUNT-then-mutate, never `.run().changes`: bun:sqlite over-reports
  // changes on tables carrying FTS triggers (same caveat SyncApply documents
  // for its remap application). Both statements see identical in-transaction
  // state.
  const tx = db.transaction(() => {
    result.exclusionsCleared = (db.prepare(
      'SELECT COUNT(*) AS n FROM sync_launch_exclusions'
    ).get() as { n: number }).n;
    db.prepare('DELETE FROM sync_launch_exclusions').run();
    for (const table of TABLES) {
      result.requeued[table] = (db.prepare(
        `SELECT COUNT(*) AS n FROM ${table}
         WHERE origin_device_id IS NULL AND synced_at IS NOT NULL`
      ).get() as { n: number }).n;
      db.prepare(
        `UPDATE ${table} SET synced_at = NULL
         WHERE origin_device_id IS NULL AND synced_at IS NOT NULL`
      ).run();
    }
  });
  tx();
  return result;
}

async function main(): Promise<void> {
  const { DB_PATH, paths } = await import('../src/shared/paths.js');
  const args = process.argv.slice(2);
  const dbFlag = args.indexOf('--db');
  const dbPath = dbFlag >= 0 ? args[dbFlag + 1] : DB_PATH;
  const force = args.includes('--force');

  if (!dbPath || !existsSync(dbPath)) {
    console.error(`database not found: ${dbPath}`);
    process.exit(1);
  }
  // The worker holds the writable connection and its CloudSync drain must
  // not race the requeue — stop it first (or pass --force if the pid file
  // is stale).
  const pidFile = paths.workerPid();
  if (!force && existsSync(pidFile)) {
    const pid = Number(readFileSync(pidFile, 'utf8').trim());
    if (Number.isFinite(pid) && pid > 0 && processAlive(pid)) {
      console.error(
        `worker appears to be running (pid ${pid}). Stop it first ` +
        `(curl -X POST http://127.0.0.1:$PORT/api/admin/shutdown) or pass --force.`
      );
      process.exit(1);
    }
  }

  const db = new Database(dbPath);
  try {
    const result = backfillPreLaunchHistory(db);
    console.log(`exclusion ledger cleared: ${result.exclusionsCleared} rows`);
    for (const table of TABLES) {
      console.log(`${table}: ${result.requeued[table]} rows requeued for push`);
    }
    console.log('Start the worker to begin the upload; progress is visible at GET /api/sync/status.');
  } finally {
    db.close();
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

if (import.meta.main) {
  await main();
}
