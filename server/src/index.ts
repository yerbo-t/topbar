import { serve } from "@hono/node-server";
import { createApp } from "./app.ts";
import { Store } from "./store.ts";

const password = process.env.ADMIN_PASSWORD;
if (!password || password.length < 12) {
  console.error("Задайте ADMIN_PASSWORD (не короче 12 символов): им закрыта страница со списком.");
  process.exit(1);
}
const dataDir = process.env.DATA_DIR ?? "./data";
const store = new Store(`${dataDir}/installs.sqlite`);
const port = Number(process.env.PORT ?? 3000);

serve({ fetch: createApp(store, { adminPassword: password }).fetch, port });
console.log(`topbar-installs слушает :${port}, записей: ${store.count()}`);
