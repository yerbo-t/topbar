import { serve } from "@hono/node-server";
import { createApp } from "./app.ts";
import { githubDownloads } from "./github.ts";
import { Store } from "./store.ts";

const password = process.env.ADMIN_PASSWORD;
if (!password || password.length < 12) {
  console.error("Задайте ADMIN_PASSWORD (не короче 12 символов): им закрыта страница со списком.");
  process.exit(1);
}
const dataDir = process.env.DATA_DIR ?? "./data";
const store = new Store(`${dataDir}/installs.sqlite`);
const port = Number(process.env.PORT ?? 3000);
const repo = process.env.GITHUB_REPO; // например yerbo-t/topbar: тогда на странице видны счётчики скачиваний GitHub
const downloadUrl = process.env.DOWNLOAD_URL ?? (repo ? `https://github.com/${repo}/releases/latest/download/topbar.dmg` : undefined);
const hops = process.env.TRUSTED_PROXY_HOPS === undefined ? 1 : Number(process.env.TRUSTED_PROXY_HOPS);

const app = createApp(store, {
  adminPassword: password,
  trustedProxyHops: hops,
  downloadUrl,
  githubDownloads: repo ? githubDownloads(repo) : undefined,
});
serve({ fetch: app.fetch, port });
console.log(`topbar-installs слушает :${port}, установок: ${store.count()}`);
