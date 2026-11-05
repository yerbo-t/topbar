import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, parsePing, parseFeedback, page } from "../src/app.ts";
import { Store } from "../src/store.ts";

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
  assert.ok(page({ installs: [], feedback: [], downloads: [], downloadTotal: 0, github: null }).includes("Пока никого"));
});

test("подделанная левая часть X-Forwarded-For не обходит ограничение", async () => {
  const { post } = make(2);
  // Доверенный прокси дописывает настоящий адрес справа; клиент может подставить что угодно слева.
  assert.equal((await post(good, { "x-forwarded-for": "1.1.1.1, 7.7.7.7" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "2.2.2.2, 7.7.7.7" })).status, 200);
  assert.equal((await post(good, { "x-forwarded-for": "3.3.3.3, 7.7.7.7" })).status, 429, "считается по правому адресу");
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
