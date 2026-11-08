import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, parsePing, parseFeedback, page } from "../src/app.ts";
import { Store, compareVersions } from "../src/store.ts";

const ID = "7C1B2A3D-1111-4222-8333-444455556666";
const good = { id: ID, name: "Анна", version: "0.2.0", build: "32", macos: "26.6.2", event: "install", model: "Mac15,6", chip: "Apple M3 Pro", ramGB: 18, language: "ru-KZ" };
const auth = "Basic " + Buffer.from("admin:correct-horse-battery").toString("base64");

const make = (limit?: number) => {
  const store = new Store(":memory:");
  const app = createApp(store, { adminPassword: "correct-horse-battery", rateLimitPerMinute: limit });
  const post = (body: unknown, headers: Record<string, string> = {}) =>
    app.request("/api/ping", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
  return { store, app, post };
};

test("запись сохраняется, повторная обновляет и считает запуски", async () => {
  const { store, post } = make();
  assert.equal((await post(good)).status, 200);
  assert.equal((await post({ ...good, version: "0.3.0", name: null, event: "launch" })).status, 200);
  const rows = store.list();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].version, "0.3.0");
  assert.equal(rows[0].launches, 2);
  assert.equal(rows[0].name, "Анна", "имя не затирается, если в записи его нет");
});

test("чужие и кривые сообщения отвергаются", async () => {
  const { store, post, app } = make();
  assert.equal((await post({ ...good, id: "не-uuid" })).status, 400);
  assert.equal((await post({ id: ID })).status, 400);
  assert.equal((await app.request("/api/ping", { method: "POST", body: "не json" })).status, 400);
  assert.equal(store.count(), 0);
});

test("слишком большое тело и частые запросы", async () => {
  const { post } = make(2);
  assert.equal((await post({ ...good, name: "я".repeat(6000) })).status, 413);
  assert.equal((await post(good, { "x-forwarded-for": "9.9.9.9" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "9.9.9.9" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "9.9.9.9" })).status, 429);
  assert.equal((await post(good, { "x-forwarded-for": "8.8.8.8" })).status, 200, "другой адрес не страдает");
});

test("список закрыт паролем и экранирует имена", async () => {
  const { app, post } = make();
  await post({ ...good, name: "<script>alert(1)</script>" });
  assert.equal((await app.request("/admin")).status, 401);
  assert.equal((await app.request("/admin", { headers: { authorization: "Basic " + Buffer.from("admin:wrong").toString("base64") } })).status, 401);
  const res = await app.request("/admin", { headers: { authorization: auth } });
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.ok(html.includes("&lt;script&gt;"));
  assert.ok(!html.includes("<script>alert"));
  const json = (await (await app.request("/admin.json", { headers: { authorization: auth } })).json()) as { installs: unknown[] };
  assert.equal(json.installs.length, 1);
});

test("разбор записи: обрезка и регистр номера", () => {
  const ping = parsePing({ ...good, id: ID.toLowerCase(), name: "  " + "я".repeat(100), event: undefined });
  assert.equal(ping?.id, ID);
  assert.equal(ping?.name?.length, 60);
  assert.equal(ping?.event, "launch");
  assert.ok(page({ installs: [], versions: [], feedback: [], downloads: [], downloadTotal: 0, github: null }).includes("Пока никого"));
});

test("подделанная левая часть X-Forwarded-For не обходит ограничение", async () => {
  const { post } = make(2);
  // Доверенный прокси дописывает настоящий адрес справа; клиент может подставить что угодно слева.
  assert.equal((await post(good, { "x-forwarded-for": "1.1.1.1, 7.7.7.7" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "2.2.2.2, 7.7.7.7" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "3.3.3.3, 7.7.7.7" })).status, 429, "считается по правому адресу");
});

test("адрес клиента из заголовка Cloudflare: подмены цепочки и мусор не мешают", async () => {
  const store = new Store(":memory:");
  const app = createApp(store, { adminPassword: "correct-horse-battery", rateLimitPerMinute: 1, clientIpHeader: "cf-connecting-ip" });
  const send = (headers: Record<string, string>) =>
    app.request("/api/ping", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(good) });
  assert.equal((await send({ "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "10.0.1.8" })).status, 200);
  assert.equal(store.list()[0].ip, "203.0.113.7", "в записи адрес из заголовка, а не соседа Traefik");
  assert.equal((await send({ "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "10.0.1.9" })).status, 429, "тот же человек считается одним");
  assert.equal((await send({ "cf-connecting-ip": "203.0.113.8" })).status, 200, "другой адрес не страдает");
  assert.equal((await send({ "cf-connecting-ip": "not-an-ip <script>", "x-forwarded-for": "5.5.5.5" })).status, 200, "мусор вместо адреса игнорируется");
  assert.equal(store.list()[0].ip, "5.5.5.5", "тогда работает прежний разбор цепочки");
});

test("общий предел на минуту и предел числа установок", async () => {
  const store = new Store(":memory:");
  const app = createApp(store, { adminPassword: "correct-horse-battery", globalPerMinute: 4, maxInstalls: 2 });
  const send = (id: string, ip: string) =>
    app.request("/api/ping", { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": ip }, body: JSON.stringify({ ...good, id }) });
  const id = (n: number) => `7C1B2A3D-1111-4222-8333-44445555000${n}`;
  assert.equal((await send(id(1), "1.1.1.1")).status, 200);
  assert.equal((await send(id(2), "2.2.2.2")).status, 200);
  assert.equal((await send(id(3), "3.3.3.3")).status, 503, "третья новая установка — предел базы");
  assert.equal((await send(id(1), "4.4.4.4")).status, 200, "известная обновляется и после предела");
  assert.equal((await send(id(1), "5.5.5.5")).status, 429, "общий предел в минуту: адреса не помогают");
  assert.equal(store.count(), 2);
});

test("в списке видны модель Mac, IP и язык; IP берётся с доверенной стороны заголовка", async () => {
  const { app, post, store } = make();
  await post(good, { "x-forwarded-for": "203.0.113.9" });
  const row = store.list()[0];
  assert.equal(row.ip, "203.0.113.9");
  assert.equal(row.model, "Mac15,6");
  assert.equal(row.ram_gb, 18);
  const html = await (await app.request("/admin", { headers: { authorization: auth } })).text();
  assert.ok(html.includes("203.0.113.9") && html.includes("Apple M3 Pro") && html.includes("18 ГБ") && html.includes("ru-KZ"));
});

test("отзыв принимается, виден администратору и экранируется; пустой отвергается", async () => {
  const { app, store } = make();
  const send = (body: unknown) =>
    app.request("/api/feedback", { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": "198.51.100.7" }, body: JSON.stringify(body) });
  assert.equal((await send({ id: ID, name: "Анна", contact: "@anna", message: "Супер <b>здорово</b>", version: "0.2.0", build: "32" })).status, 200);
  assert.equal((await send({ id: ID, message: "   ", version: "0.2.0", build: "32" })).status, 400);
  assert.equal((await send({ id: "плохой", message: "текст", version: "0.2.0", build: "32" })).status, 400);
  assert.equal(store.feedbackCount(), 1);
  const html = await (await app.request("/admin", { headers: { authorization: auth } })).text();
  assert.ok(html.includes("@anna") && html.includes("198.51.100.7"));
  assert.ok(html.includes("Супер &lt;b&gt;здорово&lt;/b&gt;") && !html.includes("<b>здорово"));
  assert.equal(parseFeedback({ id: ID, message: "я".repeat(9000), version: "1", build: "1" })?.message.length, 4000);
});

test("ссылка скачивания пишет запись и ведёт на релиз", async () => {
  const store = new Store(":memory:");
  const app = createApp(store, { adminPassword: "correct-horse-battery", downloadUrl: "https://example.test/topbar.dmg" });
  const res = await app.request("/download", { headers: { "x-forwarded-for": "192.0.2.5", "user-agent": "Mozilla/5.0 <script>" } });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get("location"), "https://example.test/topbar.dmg");
  const html = await (await app.request("/admin", { headers: { authorization: auth } })).text();
  assert.ok(html.includes("192.0.2.5") && html.includes("Mozilla/5.0 &lt;script&gt;"));
  assert.equal(store.downloadCount(), 1);
});

test("счётчики GitHub показываются, а их сбой не ломает страницу", async () => {
  const store = new Store(":memory:");
  const ok = createApp(store, { adminPassword: "correct-horse-battery", githubDownloads: async () => [{ tag: "v0.3.0", assets: [{ name: "topbar.dmg", downloads: 42 }] }] });
  const html = await (await ok.request("/admin", { headers: { authorization: auth } })).text();
  assert.ok(html.includes("v0.3.0") && html.includes(">42<"));
  const broken = createApp(store, { adminPassword: "correct-horse-battery", githubDownloads: async () => { throw new Error("нет сети"); } });
  assert.equal((await broken.request("/admin", { headers: { authorization: auth } })).status, 200);
});

test("забыть установку удаляет и её отзывы", () => {
  const store = new Store(":memory:");
  store.record({ id: ID, name: null, version: "1", build: "1", macos: "26", event: "install", model: "", chip: "", ramGB: 0, language: "" }, "1.1.1.1");
  store.addFeedback({ id: ID, name: null, contact: null, message: "текст", version: "1", build: "1" }, "1.1.1.1");
  store.forget(ID);
  assert.equal(store.count(), 0);
  assert.equal(store.feedbackCount(), 0);
});

test("витрина: главная и картинки отдаются, посторонние пути нет", async () => {
  const app = createApp(new Store(":memory:"), { adminPassword: "correct-horse-battery", publicDir: "./public" });
  const home = await app.request("/");
  assert.equal(home.status, 200);
  assert.match(home.headers.get("content-type") ?? "", /text\/html/);
  const html = await home.text();
  assert.ok(html.includes('href="/download"'), "на странице есть кнопка скачивания");
  assert.equal(home.headers.get("x-content-type-options"), "nosniff");
  const icon = await app.request("/assets/icon-light.png");
  assert.equal(icon.status, 200);
  assert.match(icon.headers.get("content-type") ?? "", /image\/png/);
  assert.equal((await app.request("/assets/нет-такого.png")).status, 404);
  assert.notEqual((await app.request("/assets/../package.json")).status, 200, "выйти за папку витрины нельзя");
  assert.notEqual((await app.request("/assets/%2e%2e/package.json")).status, 200, "и закодированным путём тоже");
  const bare = createApp(new Store(":memory:"), { adminPassword: "correct-horse-battery" });
  assert.equal((await bare.request("/")).status, 404, "без publicDir витрины нет");
});

const other = (n: number) => `7C1B2A3D-1111-4222-8333-44445555000${n}`;

test("версии сравниваются по числам, а не по тексту", () => {
  assert.ok(compareVersions("0.2.10", "0.2.9") > 0);
  assert.ok(compareVersions("0.2.3", "0.2.3") === 0);
  assert.ok(compareVersions("0.3.0", "0.2.99") > 0);
  assert.ok(compareVersions("1.0", "1.0.1") < 0, "короткая версия меньше длинной с тем же началом");
});

test("сводка: сколько устройств на какой версии, новые версии выше", () => {
  const store = new Store(":memory:");
  const now = new Date("2026-11-08T10:00:00Z");
  store.record({ ...good, id: other(1), version: "0.2.3" }, "1.1.1.1", new Date("2026-11-01T10:00:00Z"));
  store.record({ ...good, id: other(2), version: "0.2.3" }, "1.1.1.2", new Date("2026-11-05T10:00:00Z"));
  store.record({ ...good, id: other(3), version: "0.2.10" }, "1.1.1.3", now);
  store.record({ ...good, id: other(4), version: "0.2.9" }, "1.1.1.4", new Date("2026-11-02T10:00:00Z"));
  // Устройство обновилось: считается только на новой версии.
  store.record({ ...good, id: other(1), version: "0.2.10" }, "1.1.1.1", now);
  const versions = store.versions();
  assert.deepEqual(versions.map((v) => [v.version, v.devices]), [["0.2.10", 2], ["0.2.9", 1], ["0.2.3", 1]]);
  assert.equal(versions[0].last_seen, now.toISOString());
});

test("страница и JSON показывают сводку по версиям с долей", async () => {
  const { app, post } = make();
  for (const [n, version] of [[1, "0.2.3"], [2, "0.2.3"], [3, "0.2.4"]] as const) await post({ ...good, id: other(n), version }, { "x-forwarded-for": `3.3.3.${n}` });
  const html = await (await app.request("/admin", { headers: { authorization: auth } })).text();
  assert.ok(html.includes("Версии программы"));
  assert.match(html, /<td>0\.2\.3<\/td>\s*<td class="num">2<\/td>\s*<td class="num">67%<\/td>/);
  assert.match(html, /<td>0\.2\.4<\/td>\s*<td class="num">1<\/td>\s*<td class="num">33%<\/td>/);
  assert.ok(html.indexOf("0.2.4</td>") < html.indexOf("0.2.3</td>"), "новая версия выше старой");
  const json = (await (await app.request("/admin.json", { headers: { authorization: auth } })).json()) as { versions: { version: string; devices: number }[] };
  assert.deepEqual(json.versions.map((v) => [v.version, v.devices]), [["0.2.4", 1], ["0.2.3", 2]]);
});
