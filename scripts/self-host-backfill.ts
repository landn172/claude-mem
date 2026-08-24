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
import { homedir } from 'os';
import { join } from 'path';

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

function expandHome(value: string): string {
  if (value === '~') return homedir();
  if (value.startsWith('~/')) return join(homedir(), value.slice(2));
  return value;
}

/**
 * The same resolution order src/shared/paths.ts uses, reimplemented for the
 * standalone repo where that module does not exist: CLAUDE_MEM_DATA_DIR from
 * the environment, then CLAUDE_MEM_DATA_DIR recorded in the default
 * settings.json (flat or under `env`), then ~/.claude-mem.
 */
export function fallbackDataDir(): string {
  const fromEnv = process.env.CLAUDE_MEM_DATA_DIR;
  if (fromEnv) return expandHome(fromEnv);
  const defaultDir = join(homedir(), '.claude-mem');
  try {
    // Strip a BOM the way the plugin's parseJsonWithBom does; JSON.parse
    // rejects one and a BOM'd settings file must not silently relocate the
    // data directory back to the default.
    const raw = readFileSync(join(defaultDir, 'settings.json'), 'utf8').replace(/^\uFEFF/, '');
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const settings = (parsed.env ?? parsed) as Record<string, unknown>;
    const configured = settings.CLAUDE_MEM_DATA_DIR;
    if (typeof configured === 'string' && configured.length > 0) return expandHome(configured);
  } catch {
    // Missing or unparseable settings — the default is the right answer.
  }
  return defaultDir;
}

/**
 * The plugin's paths module is the single source of truth when this runs from
 * inside the claude-mem checkout. This script also ships in the standalone
 * self-host repo, which has no src/ — there the import fails and the fallback
 * above applies. Only a module-resolution failure is caught: an error raised
 * from *inside* paths.ts is a real problem and must not be papered over by
 * silently resolving the data directory a second way.
 */
export async function resolveDataPaths(): Promise<{ dbPath: string; pidFile: string }> {
  try {
    const mod = await import('../src/shared/paths.js');
    return { dbPath: mod.DB_PATH, pidFile: mod.paths.workerPid() };
  } catch (error: unknown) {
    const code = (error as { code?: string } | null)?.code;
    if (code !== 'ERR_MODULE_NOT_FOUND' && code !== 'MODULE_NOT_FOUND') throw error;
    const dataDir = fallbackDataDir();
    return { dbPath: join(dataDir, 'claude-mem.db'), pidFile: join(dataDir, 'worker.pid') };
  }
}

/**
 * worker.pid holds JSON — {pid, port, startedAt, startToken}. Parsing it as a
 * bare integer yields NaN, so the bare-int-only parse this replaced left
 * `Number.isFinite` false and skipped the liveness check ENTIRELY: the guard
 * never fired, and every run raced the CloudSync drain as though --force had
 * been passed. Returns null only when neither shape yields a usable pid.
 */
export function readWorkerPid(raw: string): number | null {
  try {
    const parsed = JSON.parse(raw) as { pid?: unknown } | null;
    const pid = parsed?.pid;
    if (typeof pid === 'number' && Number.isInteger(pid) && pid > 0) return pid;
  } catch {
    // Not JSON — older builds wrote a bare integer.
  }
  const bare = Number(raw.trim());
  return Number.isInteger(bare) && bare > 0 ? bare : null;
}

async function main(): Promise<void> {
  const { dbPath: defaultDbPath, pidFile } = await resolveDataPaths();
  const args = process.argv.slice(2);
  const dbFlag = args.indexOf('--db');
  const dbPath = dbFlag >= 0 ? args[dbFlag + 1] : defaultDbPath;
  const force = args.includes('--force');

  if (!dbPath || !existsSync(dbPath)) {
    console.error(`database not found: ${dbPath}`);
    process.exit(1);
  }
  // The worker holds the writable connection and its CloudSync drain must
  // not race the requeue — stop it first (or pass --force if the pid file
  // is stale).
  if (!force && existsSync(pidFile)) {
    const pid = readWorkerPid(readFileSync(pidFile, 'utf8'));
    if (pid === null) {
      // Refuse rather than warn: an unreadable pid file may well belong to a
      // live worker, and a lost requeue is silent — the drain stamps
      // synced_at on ack, so a row re-nulled here and acked a moment later
      // looks synced and never re-pushes. Being asked for --force costs one
      // flag; guessing wrong costs rows with no way to tell.
      console.error(
        `cannot tell whether the worker is running: ${pidFile} is neither JSON ` +
        `with a "pid" nor a bare pid. Stop the worker and delete the file, or pass --force.`
      );
      process.exit(1);
    }
    if (processAlive(pid)) {
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
