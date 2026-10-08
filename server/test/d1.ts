/// <reference types="node" />
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

type Value = string | number | null;

/// A minimal D1 stand-in over node:sqlite with every migration applied and
/// foreign keys enforced, as D1 does in production.
export const migrationsDir = join(import.meta.dirname, "..", "migrations");

/// Applies migrations in order; `before` stops ahead of the named file so a
/// test can seed data and then run that migration itself.
export function migratedD1(before?: string): { db: DatabaseSync; d1: D1Database } {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON");
  for (const file of readdirSync(migrationsDir).filter(name => name.endsWith(".sql")).sort()) {
    if (before && file >= before) break;
    db.exec(readFileSync(join(migrationsDir, file), "utf8"));
  }
  const statement = (sql: string, args: Value[] = []) => ({
    bind: (...values: Value[]) => statement(sql, values),
    async first<T>(): Promise<T | null> { return (db.prepare(sql).get(...args) as T | undefined) ?? null; },
    async all<T>(): Promise<{ results: T[] }> { return { results: db.prepare(sql).all(...args) as T[] }; },
    async run() { return { meta: { changes: Number(db.prepare(sql).run(...args).changes) } }; },
  });
  const d1 = {
    prepare: (sql: string) => statement(sql),
    async batch(statements: Array<{ run: () => Promise<unknown> }>) {
      db.exec("BEGIN");
      try {
        const results = [];
        for (const item of statements) results.push(await item.run());
        db.exec("COMMIT");
        return results;
      } catch (cause) { db.exec("ROLLBACK"); throw cause; }
    },
  };
  return { db, d1: d1 as unknown as D1Database };
}
