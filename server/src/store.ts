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
  model: string;
  chip: string;
  ramGB: number;
  language: string;
}

export interface Install {
  id: string;
  name: string | null;
  version: string;
  build: string;
  macos: string;
  model: string;
  chip: string;
  ram_gb: number;
  language: string;
  ip: string;
  first_seen: string;
  last_seen: string;
  launches: number;
}

/** Сколько устройств сейчас на этой версии программы (последняя версия, которую устройство о себе сообщило). */
export interface VersionCount {
  version: string;
  devices: number;
  last_seen: string;
}

export interface FeedbackIn {
  id: string;
  name: string | null;
  contact: string | null;
  message: string;
  version: string;
  build: string;
}

export interface FeedbackRow extends FeedbackIn {
  rowid: number;
  at: string;
  ip: string;
}

export interface DownloadRow {
  at: string;
  ip: string;
  ua: string;
}

const MAX_DOWNLOAD_ROWS = 20000;

/** Сравнение версий по числам («0.2.10» новее «0.2.9»); не число в части версии сравнивается как текст. Больше нуля — первая новее. */
export function compareVersions(a: string, b: string): number {
  const left = a.split(".");
  const right = b.split(".");
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const x = left[i];
    const y = right[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const nx = Number(x);
    const ny = Number(y);
    const diff = Number.isNaN(nx) || Number.isNaN(ny) ? x.localeCompare(y) : nx - ny;
    if (diff !== 0) return diff;
  }
  return 0;
}

/**
 * Хранилище на SQLite. IP-адрес и модель Mac сохраняются с согласия человека (окно согласия в приложении и README говорят об
 * этом прямо); удалить свои данные можно по просьбе — см. README службы.
 */
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
        model TEXT NOT NULL DEFAULT '',
        chip TEXT NOT NULL DEFAULT '',
        ram_gb INTEGER NOT NULL DEFAULT 0,
        language TEXT NOT NULL DEFAULT '',
        ip TEXT NOT NULL DEFAULT '',
        first_seen TEXT NOT NULL,
        last_seen TEXT NOT NULL,
        launches INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        ip TEXT NOT NULL,
        ua TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS feedback (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        install_id TEXT NOT NULL,
        name TEXT,
        contact TEXT,
        message TEXT NOT NULL,
        version TEXT NOT NULL,
        build TEXT NOT NULL,
        ip TEXT NOT NULL
      );`);
  }

  /** Записать «пользуюсь»: новая установка добавляется, известная обновляется (имя — только если прислано). */
  record(ping: Ping, ip: string, now = new Date()): void {
    const at = now.toISOString();
    this.db
      .prepare(
        `INSERT INTO installs (id, name, version, build, macos, model, chip, ram_gb, language, ip, first_seen, last_seen, launches)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
         ON CONFLICT(id) DO UPDATE SET
           name = COALESCE(excluded.name, installs.name),
           version = excluded.version, build = excluded.build, macos = excluded.macos,
           model = excluded.model, chip = excluded.chip, ram_gb = excluded.ram_gb, language = excluded.language,
           ip = excluded.ip, last_seen = excluded.last_seen, launches = installs.launches + 1`,
      )
      .run(ping.id, ping.name, ping.version, ping.build, ping.macos, ping.model, ping.chip, ping.ramGB, ping.language, ip, at, at);
  }

  list(): Install[] {
    return this.db.prepare("SELECT * FROM installs ORDER BY last_seen DESC").all() as unknown as Install[];
  }

  /** Сводка по версиям: новые выше. */
  versions(): VersionCount[] {
    const rows = this.db
      .prepare("SELECT version, COUNT(*) AS devices, MAX(last_seen) AS last_seen FROM installs GROUP BY version")
      .all() as unknown as VersionCount[];
    return rows.sort((a, b) => compareVersions(b.version, a.version));
  }

  has(id: string): boolean {
    return this.db.prepare("SELECT 1 FROM installs WHERE id = ?").get(id) !== undefined;
  }

  count(): number {
    return (this.db.prepare("SELECT COUNT(*) AS n FROM installs").get() as { n: number }).n;
  }

  /** Удалить всё, что известно об установке (по просьбе человека). */
  forget(id: string): void {
    this.db.prepare("DELETE FROM installs WHERE id = ?").run(id);
    this.db.prepare("DELETE FROM feedback WHERE install_id = ?").run(id);
  }

  addDownload(ip: string, ua: string, now = new Date()): void {
    this.db.prepare("INSERT INTO downloads (at, ip, ua) VALUES (?, ?, ?)").run(now.toISOString(), ip, ua.slice(0, 200));
    // Таблица не растёт без предела: хранятся последние записи.
    this.db.prepare("DELETE FROM downloads WHERE id <= (SELECT MAX(id) FROM downloads) - ?").run(MAX_DOWNLOAD_ROWS);
  }

  downloads(limit = 200): DownloadRow[] {
    return this.db.prepare("SELECT at, ip, ua FROM downloads ORDER BY id DESC LIMIT ?").all(limit) as unknown as DownloadRow[];
  }

  downloadCount(): number {
    return (this.db.prepare("SELECT COUNT(*) AS n FROM downloads").get() as { n: number }).n;
  }

  addFeedback(feedback: FeedbackIn, ip: string, now = new Date()): void {
    this.db
      .prepare("INSERT INTO feedback (at, install_id, name, contact, message, version, build, ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .run(now.toISOString(), feedback.id, feedback.name, feedback.contact, feedback.message, feedback.version, feedback.build, ip);
  }

  feedback(limit = 200): FeedbackRow[] {
    return this.db
      .prepare("SELECT id AS rowid, at, install_id AS id, name, contact, message, version, build, ip FROM feedback ORDER BY rowid DESC LIMIT ?")
      .all(limit) as unknown as FeedbackRow[];
  }

  feedbackCount(): number {
    return (this.db.prepare("SELECT COUNT(*) AS n FROM feedback").get() as { n: number }).n;
  }
}
