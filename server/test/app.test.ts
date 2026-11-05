import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp, parsePing, page } from "../src/app.ts";
import { Store } from "../src/store.ts";

const ID = "7C1B2A3D-1111-4222-8333-444455556666";
const good = { id: ID, name: "Анна", version: "0.2.0", build: "32", macos: "26.6.2", event: "install" };
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
  const json = (await (await app.request("/admin.json", { headers: { authorization: auth } })).json()) as unknown[];
  assert.equal(json.length, 1);
});

test("разбор записи: обрезка и регистр номера", () => {
  const ping = parsePing({ ...good, id: ID.toLowerCase(), name: "  " + "я".repeat(100), event: undefined });
  assert.equal(ping?.id, ID);
  assert.equal(ping?.name?.length, 60);
  assert.equal(ping?.event, "launch");
  assert.ok(page([]).includes("Пока никого"));
});
