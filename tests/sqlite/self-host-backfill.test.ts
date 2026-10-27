/**
 * scripts/self-host-backfill.ts — one-shot opt-in that uploads a pre-launch
 * local corpus to a SELF-HOSTED hub by clearing the launch exclusion ledger
 * and re-nulling synced_at on NATIVE rows only. Rows replicated from other
 * devices (origin_device_id set) must never be touched: re-nulling them
 * would re-push foreign entities under this device's push lane.
 *
 * The pre-launch state is fabricated the same way the migration fixtures do:
 * seed rows, delete the v47/v48 schema_versions rows, and re-open the store —
 * initializeSyncHubLaunchBaseline recomputes the ledger and stamps synced_at.
 */

import { describe, it, expect } from 'bun:test';
import { Database } from 'bun:sqlite';
import { SessionStore } from '../../src/services/sqlite/SessionStore.js';
import { backfillPreLaunchHistory } from '../../scripts/self-host-backfill.js';

const TABLES = ['observations', 'session_summaries', 'user_prompts'] as const;

function preLaunchDb(): Database {
  const db = new Database(':memory:');
  new SessionStore(db);
  const now = new Date().toISOString();
  const epoch = Date.now();
  db.prepare(`
    INSERT INTO sdk_sessions (content_session_id, memory_session_id, project, started_at, started_at_epoch, status)
    VALUES ('content-1', 'memory-1', 'proj', ?, ?, 'active')
  `).run(now, epoch);
  db.prepare(`
    INSERT INTO sdk_sessions (content_session_id, memory_session_id, project, started_at, started_at_epoch, status)
    VALUES ('content-2', 'memory-2', 'proj', ?, ?, 'active')
  `).run(now, epoch);
  db.prepare(`
    INSERT INTO observations (memory_session_id, project, type, content_hash, created_at, created_at_epoch)
    VALUES ('memory-1', 'proj', 'discovery', 'hash-1', ?, ?)
  `).run(now, epoch);
  db.prepare(`
    INSERT INTO session_summaries (memory_session_id, project, request, created_at, created_at_epoch)
    VALUES ('memory-1', 'proj', 'request', ?, ?)
  `).run(now, epoch);
  db.prepare(`
    INSERT INTO user_prompts (content_session_id, prompt_number, prompt_text, created_at, created_at_epoch)
    VALUES ('content-1', 1, 'prompt', ?, ?)
  `).run(now, epoch);
  // Re-run the launch baseline over the seeded rows (fixture-removal path).
  db.run('DELETE FROM schema_versions WHERE version IN (47, 48)');
  new SessionStore(db);
  // A replicated row from another device, already synced — must stay stamped.
  db.prepare(`
    INSERT INTO observations (
      memory_session_id, project, type, content_hash, created_at, created_at_epoch,
      origin_device_id, origin_local_id, synced_at
    ) VALUES ('memory-2', 'proj', 'discovery', 'hash-foreign', ?, ?, 'other-device', '5', ?)
  `).run(now, epoch, epoch);
  return db;
}

function count(db: Database, sql: string): number {
  return (db.prepare(sql).get() as { n: number }).n;
}

describe('self-host backfill', () => {
  it('starts from a genuinely excluded pre-launch state', () => {
    const db = preLaunchDb();
    expect(count(db, 'SELECT COUNT(*) AS n FROM sync_launch_exclusions')).toBe(3);
    for (const table of TABLES) {
      expect(count(db, `SELECT COUNT(*) AS n FROM ${table} WHERE origin_device_id IS NULL AND synced_at IS NULL`)).toBe(0);
    }
  });

  it('clears the exclusion ledger and requeues every native row', () => {
    const db = preLaunchDb();
    const result = backfillPreLaunchHistory(db);
    expect(count(db, 'SELECT COUNT(*) AS n FROM sync_launch_exclusions')).toBe(0);
    for (const table of TABLES) {
      expect(count(db, `SELECT COUNT(*) AS n FROM ${table} WHERE origin_device_id IS NULL AND synced_at IS NOT NULL`)).toBe(0);
      expect(count(db, `SELECT COUNT(*) AS n FROM ${table} WHERE origin_device_id IS NULL AND synced_at IS NULL`)).toBe(1);
    }
    expect(result.exclusionsCleared).toBe(3);
    expect(result.requeued.observations).toBe(1);
    expect(result.requeued.session_summaries).toBe(1);
    expect(result.requeued.user_prompts).toBe(1);
  });

  it('never touches rows replicated from other devices', () => {
    const db = preLaunchDb();
    backfillPreLaunchHistory(db);
    const foreign = db.prepare(
      "SELECT synced_at FROM observations WHERE origin_device_id = 'other-device'"
    ).get() as { synced_at: number | null };
    expect(foreign.synced_at).not.toBeNull();
  });

  it('is idempotent', () => {
    const db = preLaunchDb();
    backfillPreLaunchHistory(db);
    const second = backfillPreLaunchHistory(db);
    expect(second.exclusionsCleared).toBe(0);
    expect(second.requeued.observations).toBe(0);
  });
});
