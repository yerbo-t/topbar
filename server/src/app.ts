import { Hono } from "hono";
import { basicAuth } from "hono/basic-auth";
import { bodyLimit } from "hono/body-limit";
import { getConnInfo } from "@hono/node-server/conninfo";
import { serveStatic } from "@hono/node-server/serve-static";
import { isIP } from "node:net";
import type { Context, MiddlewareHandler } from "hono";
import type { Download, GithubAsset } from "./github.ts";
import type { FeedbackIn, FeedbackRow, Install, Ping, Store, VersionCount } from "./store.ts";

const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

const cut = (value: unknown, max: number): string | null => {
  if (typeof value !== "string") return null;
  const text = value.trim().slice(0, max);
  return text.length ? text : null;
};

const installId = (value: unknown): string | null => (typeof value === "string" && UUID.test(value) ? value.toUpperCase() : null);

/** Проверить тело записи «пользуюсь»; null — не наше сообщение. */
export function parsePing(body: unknown): Ping | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const id = installId(b.id);
  if (!id) return null;
  const version = cut(b.version, 32);
  const build = cut(b.build, 32);
  const macos = cut(b.macos, 32);
  if (!version || !build || !macos) return null;
  const ram = typeof b.ramGB === "number" && Number.isFinite(b.ramGB) ? Math.min(Math.max(Math.round(b.ramGB), 0), 4096) : 0;
  return {
    id,
    name: cut(b.name, 60),
    version,
    build,
    macos,
    event: cut(b.event, 16) ?? "launch",
    model: cut(b.model, 40) ?? "",
    chip: cut(b.chip, 60) ?? "",
    ramGB: ram,
    language: cut(b.language, 20) ?? "",
  };
}

/** Проверить тело отзыва; null — не наше сообщение или пустой текст. */
export function parseFeedback(body: unknown): FeedbackIn | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const id = installId(b.id);
  const message = cut(b.message, 4000);
  const version = cut(b.version, 32);
  const build = cut(b.build, 32);
  if (!id || !message || !version || !build) return null;
  return { id, name: cut(b.name, 60), contact: cut(b.contact, 100), message, version, build };
}

const escapeHtml = (text: string): string =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const day = (iso: string): string => iso.slice(0, 10) + " " + iso.slice(11, 16);
const none = '<span class="muted">—</span>';

export interface PageData {
  installs: Install[];
  versions: VersionCount[];
  feedback: FeedbackRow[];
  downloads: { at: string; ip: string; ua: string }[];
  downloadTotal: number;
  github: Download[] | null;
}

export function page(data: PageData): string {
  const total = data.installs.length;
  const versions = data.versions
    .map(
      (v) => `<tr><td>${escapeHtml(v.version)}</td><td class="num">${v.devices}</td><td class="num">${Math.round((v.devices / total) * 100)}%</td>
<td>${day(v.last_seen)}</td></tr>`,
    )
    .join("\n");
  const installs = data.installs
    .map((i) => {
      const mac = [i.model, i.chip, i.ram_gb ? `${i.ram_gb} ГБ` : ""].filter(Boolean).map(escapeHtml).join(" · ");
      return `<tr><td>${i.name ? escapeHtml(i.name) : '<span class="muted">без имени</span>'}</td>
<td>${mac || none}</td><td>${escapeHtml(i.macos)}</td><td>${escapeHtml(i.version)} (${escapeHtml(i.build)})</td>
<td>${i.language ? escapeHtml(i.language) : none}</td><td class="mono">${i.ip ? escapeHtml(i.ip) : none}</td>
<td>${day(i.first_seen)}</td><td>${day(i.last_seen)}</td><td class="num">${i.launches}</td>
<td class="muted mono">${escapeHtml(i.id.slice(0, 8))}</td></tr>`;
    })
    .join("\n");
  const feedback = data.feedback
    .map(
      (f) => `<tr><td>${day(f.at)}</td><td>${f.name ? escapeHtml(f.name) : none}</td><td>${f.contact ? escapeHtml(f.contact) : none}</td>
<td>${escapeHtml(f.version)}</td><td class="msg">${escapeHtml(f.message)}</td><td class="mono">${escapeHtml(f.ip)}</td></tr>`,
    )
    .join("\n");
  const downloads = data.downloads
    .map((d) => `<tr><td>${day(d.at)}</td><td class="mono">${escapeHtml(d.ip)}</td><td class="muted">${escapeHtml(d.ua)}</td></tr>`)
    .join("\n");
  const github = data.github
    ? `<table><thead><tr><th>Релиз</th><th>Файл</th><th class="num">Скачиваний с GitHub</th></tr></thead><tbody>${data.github
        .flatMap((r) => r.assets.map((a: GithubAsset) => `<tr><td>${escapeHtml(r.tag)}</td><td>${escapeHtml(a.name)}</td><td class="num">${a.downloads}</td></tr>`))
        .join("") || '<tr><td colspan="3" class="muted">Релизов пока нет.</td></tr>'}</tbody></table>`
    : '<p class="muted">Счётчики GitHub не подключены (переменная GITHUB_REPO).</p>';
  return `<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>topbar: установки и отзывы</title>
<style>
body{font:15px/1.5 system-ui,sans-serif;margin:32px auto;max-width:1200px;padding:0 16px;color:#1d1d1f}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:32px 0 8px}p{margin:0 0 12px;color:#6e6e73}
.scroll{overflow-x:auto}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e5e5ea;vertical-align:top}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#6e6e73;white-space:nowrap}.num{text-align:right}
.msg{white-space:pre-wrap;max-width:460px}.muted{color:#8e8e93}.mono{font-family:ui-monospace,monospace;font-size:12px}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}th,td{border-color:#3a3a3c}}
</style>
<h1>topbar: установки и отзывы</h1>
<p>Установок с согласием: ${data.installs.length}. Отзывов: ${data.feedback.length}. Скачиваний по ссылке службы: ${data.downloadTotal}.</p>
<h2>Версии программы (сводно)</h2>
<p>Сколько устройств на какой версии. Считаются только те, кто согласился на отправку данных, поэтому настоящих пользователей может быть больше: цифры — минимум, который известен. Версия — последняя, о которой устройство сообщило: обновившееся, но ещё не запущенное числится на старой.</p>
<div class="scroll"><table><thead><tr><th>Версия</th><th class="num">Устройств</th><th class="num">Доля</th><th>Последний раз</th></tr></thead>
<tbody>
${versions || '<tr><td colspan="4" class="muted">Пока никого.</td></tr>'}
</tbody></table></div>
<h2>Устройства (детально)</h2>
<div class="scroll"><table><thead><tr><th>Имя</th><th>Mac</th><th>macOS</th><th>Версия</th><th>Язык</th><th>IP</th><th>Первый раз</th><th>Последний раз</th><th class="num">Запусков</th><th>Номер</th></tr></thead>
<tbody>
${installs || '<tr><td colspan="10" class="muted">Пока никого.</td></tr>'}
</tbody></table></div>
<h2>Отзывы</h2>
<div class="scroll"><table><thead><tr><th>Когда</th><th>Имя</th><th>Как ответить</th><th>Версия</th><th>Текст</th><th>IP</th></tr></thead>
<tbody>
${feedback || '<tr><td colspan="6" class="muted">Отзывов пока нет.</td></tr>'}
</tbody></table></div>
<h2>Скачивания по ссылке службы (последние)</h2>
<div class="scroll"><table><thead><tr><th>Когда</th><th>IP</th><th>Программа</th></tr></thead>
<tbody>
${downloads || '<tr><td colspan="3" class="muted">Пока никто не скачивал по этой ссылке.</td></tr>'}
</tbody></table></div>
<h2>Скачивания с GitHub</h2>
<p>Прямые скачивания с GitHub считаются без адресов: GitHub их не сообщает.</p>
<div class="scroll">${github}</div>
</html>`;
}

export interface Options {
  adminPassword: string;
  /** Логин страницы /admin; не задан — admin. */
  adminUser?: string;
  /** Записей с одного адреса в минуту. */
  rateLimitPerMinute?: number;
  /** Записей в минуту со всех адресов вместе (защита от «размножения» адресов). */
  globalPerMinute?: number;
  /** Сколько установок и отзывов хранить; после этого принимаются только записи от уже известных установок. */
  maxInstalls?: number;
  maxFeedback?: number;
  /** Сколько прокси стоит перед службой (Coolify/Traefik — 1): адрес клиента берётся из X-Forwarded-For
   *  с конца, потому что левая часть заголовка подделывается клиентом. 0 — заголовку не верить. */
  trustedProxyHops?: number;
  /** Заголовок, в котором первый в цепочке прокси (Cloudflare) передаёт адрес клиента, например cf-connecting-ip. Если он есть и
   *  содержит настоящий IP, берётся он. Нужен там, где Traefik подменяет X-Forwarded-For адресом своего соседа. Включать только
   *  когда служба доступна лишь через этот прокси: напрямую заголовок подделывается. Не задан — не используется. */
  clientIpHeader?: string;
  /** Папка со страницей-витриной (index.html и assets/), путь от текущего каталога процесса; не задана — витрины нет. */
  publicDir?: string;
  /** Куда ведёт /download (последний релиз на GitHub). */
  downloadUrl?: string;
  /** Счётчики скачиваний с GitHub для страницы администратора (null — не подключены). */
  githubDownloads?: () => Promise<Download[]> | null;
}

/** Адрес клиента: последний, дописанный доверенным прокси, а не первый, присланный клиентом. */
export function clientIp(c: Context, hops: number, header?: string): string {
  const named = header ? c.req.header(header)?.trim() : undefined;
  if (named && isIP(named)) return named;
  const forwarded = c.req.header("x-forwarded-for");
  if (hops > 0 && forwarded) {
    const parts = forwarded.split(",").map((part) => part.trim()).filter(Boolean);
    const ip = parts[parts.length - hops];
    if (ip) return ip;
  }
  try {
    return (getConnInfo(c).remote.address ?? "unknown").replace(/^::ffff:/, "");
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
  const maxFeedback = options.maxFeedback ?? 5000;
  const hops = options.trustedProxyHops ?? 1;
  const downloadUrl = options.downloadUrl ?? "https://github.com/yerbo-t/topbar/releases/latest/download/topbar.dmg";
  let global: number[] = [];

  /** Ограничение частоты: с одного адреса и со всех вместе. Возвращает адрес клиента или null, если пора притормозить. */
  const admit = (c: Context): string | null => {
    const ip = clientIp(c, hops, options.clientIpHeader);
    const now = Date.now();
    global = global.filter((t) => now - t < 60_000);
    if (global.length >= globalLimit) return null;
    const recent = (hits.get(ip) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= limit) return null;
    recent.push(now);
    global.push(now);
    hits.set(ip, recent);
    if (hits.size > 5000) hits.clear();
    return ip;
  };

  const tooLarge = bodyLimit({ maxSize: 8 * 1024, onError: (c) => c.json({ error: "too large" }, 413) });

  app.get("/health", (c) => c.json({ ok: true }));

  if (options.publicDir) {
    const root = options.publicDir;
    const cached = (seconds: number): MiddlewareHandler => async (c, next) => {
      await next();
      if (c.res.status === 200) {
        c.res.headers.set("Cache-Control", `public, max-age=${seconds}`);
        c.res.headers.set("X-Content-Type-Options", "nosniff");
        c.res.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
      }
    };
    app.get("/", cached(300), serveStatic({ root, path: "index.html" }));
    app.get("/assets/*", cached(86400), serveStatic({ root }));
  }

  app.post("/api/ping", tooLarge, async (c) => {
    const ip = admit(c);
    if (!ip) return c.json({ error: "slow down" }, 429);
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
    store.record(ping, ip);
    return c.json({ ok: true });
  });

  app.post("/api/feedback", tooLarge, async (c) => {
    const ip = admit(c);
    if (!ip) return c.json({ error: "slow down" }, 429);
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "bad json" }, 400);
    }
    const feedback = parseFeedback(body);
    if (!feedback) return c.json({ error: "bad feedback" }, 400);
    if (store.feedbackCount() >= maxFeedback) return c.json({ error: "full" }, 503);
    store.addFeedback(feedback, ip);
    return c.json({ ok: true });
  });

  // Ссылка для скачивания: записывает, кто пришёл, и ведёт на последний релиз GitHub.
  app.get("/download", (c) => {
    const ip = admit(c);
    if (ip) store.addDownload(ip, c.req.header("user-agent") ?? "");
    return c.redirect(downloadUrl, 302);
  });

  const auth = basicAuth({ username: options.adminUser ?? "admin", password: options.adminPassword });
  const snapshot = async (): Promise<PageData> => {
    let github: Download[] | null = null;
    try {
      github = (await options.githubDownloads?.()) ?? null;
    } catch {
      github = null;
    }
    return { installs: store.list(), versions: store.versions(), feedback: store.feedback(), downloads: store.downloads(), downloadTotal: store.downloadCount(), github };
  };
  app.get("/admin", auth, async (c) => c.html(page(await snapshot())));
  app.get("/admin.json", auth, async (c) => c.json(await snapshot()));

  return app;
}
