import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export interface Ping {
  id: string;
  name: string | null;
  version: string;
  build: string;
  macos: string;
  event: string;
}

export interface Install {
  id: string;
  name: string | null;
  version: string;
  build: string;
  macos: string;
  first_seen: string;
  last_seen: string;
  launches: number;
}

/** Хранилище на SQLite: одна строка на установку. Адреса (IP) не сохраняются. */
export class Store {
  private db: DatabaseSync;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS installs (
        id TEXT PRIMARY KEY,
        name TEXT,
        version TEXT NOT NULL,
        build TEXT NOT NULL,
        macos TEXT NOT NULL,
        first_seen TEXT NOT NULL,
        last_seen TEXT NOT NULL,
        launches INTEGER NOT NULL DEFAULT 1
      )`);
  }

  /** Записать «пользуюсь»: новая установка добавляется, известная обновляется (имя — только если прислано). */
  record(ping: Ping, now = new Date()): void {
    const at = now.toISOString();
    this.db
      .prepare(
        `INSERT INTO installs (id, name, version, build, macos, first_seen, last_seen, launches)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1)
         ON CONFLICT(id) DO UPDATE SET
           name = COALESCE(excluded.name, installs.name),
           version = excluded.version, build = excluded.build, macos = excluded.macos,
           last_seen = excluded.last_seen, launches = installs.launches + 1`,
      )
      .run(ping.id, ping.name, ping.version, ping.build, ping.macos, at, at);
  }

  list(): Install[] {
    return this.db.prepare("SELECT * FROM installs ORDER BY last_seen DESC").all() as unknown as Install[];
  }

  count(): number {
    return (this.db.prepare("SELECT COUNT(*) AS n FROM installs").get() as { n: number }).n;
  }
}
