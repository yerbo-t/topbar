import { Hono } from "hono";
import { basicAuth } from "hono/basic-auth";
import { bodyLimit } from "hono/body-limit";
import { getConnInfo } from "@hono/node-server/conninfo";
import type { Context } from "hono";
import type { Ping, Install, Store } from "./store.ts";

const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

const cut = (value: unknown, max: number): string | null => {
  if (typeof value !== "string") return null;
  const text = value.trim().slice(0, max);
  return text.length ? text : null;
};

/** Проверить тело записи; null — не наше сообщение. */
export function parsePing(body: unknown): Ping | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  if (typeof b.id !== "string" || !UUID.test(b.id)) return null;
  const version = cut(b.version, 32);
  const build = cut(b.build, 32);
  const macos = cut(b.macos, 32);
  if (!version || !build || !macos) return null;
  return { id: b.id.toUpperCase(), name: cut(b.name, 60), version, build, macos, event: cut(b.event, 16) ?? "launch" };
}

const escapeHtml = (text: string): string =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const day = (iso: string): string => iso.slice(0, 10) + " " + iso.slice(11, 16);

export function page(installs: Install[]): string {
  const rows = installs
    .map(
      (i) => `<tr><td>${i.name ? escapeHtml(i.name) : '<span class="muted">без имени</span>'}</td>
<td>${escapeHtml(i.version)} (${escapeHtml(i.build)})</td><td>${escapeHtml(i.macos)}</td>
<td>${day(i.first_seen)}</td><td>${day(i.last_seen)}</td><td class="num">${i.launches}</td>
<td class="muted mono">${escapeHtml(i.id.slice(0, 8))}</td></tr>`,
    )
    .join("\n");
  return `<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Установки topbar</title>
<style>
body{font:15px/1.5 system-ui,sans-serif;margin:32px auto;max-width:980px;padding:0 16px;color:#1d1d1f}
h1{font-size:22px;margin:0 0 4px}p{margin:0 0 20px;color:#6e6e73}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e5e5ea}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#6e6e73}.num{text-align:right}
.muted{color:#8e8e93}.mono{font-family:ui-monospace,monospace;font-size:12px}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}th,td{border-color:#3a3a3c}}
</style>
<h1>Установки topbar</h1>
<p>Всего: ${installs.length}. Здесь только те, кто согласился сообщать: имя (если ввёл), версия, macOS, номер установки.</p>
<table><thead><tr><th>Имя</th><th>Версия</th><th>macOS</th><th>Первый раз</th><th>Последний раз</th><th class="num">Запусков</th><th>Номер</th></tr></thead>
<tbody>
${rows || '<tr><td colspan="7" class="muted">Пока никого.</td></tr>'}
</tbody></table></html>`;
}

export interface Options {
  adminPassword: string;
  /** Записей с одного адреса в минуту. */
  rateLimitPerMinute?: number;
  /** Записей в минуту со всех адресов вместе (защита от «размножения» адресов). */
  globalPerMinute?: number;
  /** Сколько установок хранить; после этого принимаются только записи от уже известных (ограничивает рост базы). */
  maxInstalls?: number;
  /** Сколько прокси стоит перед службой (Coolify/Traefik — 1): адрес клиента берётся из X-Forwarded-For
   *  с конца, потому что левая часть заголовка подделывается клиентом. 0 — заголовку не верить. */
  trustedProxyHops?: number;
}

/** Адрес клиента для ограничения частоты: последний, дописанный доверенным прокси, а не первый, присланный клиентом. */
export function clientIp(c: Context, hops: number): string {
  const forwarded = c.req.header("x-forwarded-for");
  if (hops > 0 && forwarded) {
    const parts = forwarded.split(",").map((part) => part.trim()).filter(Boolean);
    const ip = parts[parts.length - hops];
    if (ip) return ip;
  }
  try {
    return getConnInfo(c).remote.address ?? "unknown";
  } catch {
    return "unknown";
  }
}

export function createApp(store: Store, options: Options): Hono {
  const app = new Hono();
  const hits = new Map<string, number[]>();
  const limit = options.rateLimitPerMinute ?? 30;
  const globalLimit = options.globalPerMinute ?? 600;
  const maxInstalls = options.maxInstalls ?? 5000;
  const hops = options.trustedProxyHops ?? 1;
  let global: number[] = [];

  app.get("/health", (c) => c.json({ ok: true }));

  app.post("/api/ping", bodyLimit({ maxSize: 4 * 1024, onError: (c) => c.json({ error: "too large" }, 413) }), async (c) => {
    // Адрес нужен только для ограничения частоты и нигде не сохраняется.
    const ip = clientIp(c, hops);
    const now = Date.now();
    global = global.filter((t) => now - t < 60_000);
    if (global.length >= globalLimit) return c.json({ error: "slow down" }, 429);
    const recent = (hits.get(ip) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= limit) return c.json({ error: "slow down" }, 429);
    recent.push(now);
    global.push(now);
    hits.set(ip, recent);
    if (hits.size > 5000) hits.clear();

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "bad json" }, 400);
    }
    const ping = parsePing(body);
    if (!ping) return c.json({ error: "bad ping" }, 400);
    // Новых установок принимаем не больше предела: иначе любой мог бы бесконечно раздувать базу выдуманными номерами.
    if (!store.has(ping.id) && store.count() >= maxInstalls) return c.json({ error: "full" }, 503);
    store.record(ping);
    return c.json({ ok: true });
  });

  const auth = basicAuth({ username: "admin", password: options.adminPassword });
  app.get("/admin", auth, (c) => c.html(page(store.list())));
  app.get("/admin.json", auth, (c) => c.json(store.list()));

  return app;
}
