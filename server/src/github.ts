export interface GithubAsset {
  name: string;
  downloads: number;
}

export interface Download {
  tag: string;
  assets: GithubAsset[];
}

/** Счётчики скачиваний релизов GitHub (без адресов: GitHub их не даёт). Результат кэшируется на 10 минут. */
export function githubDownloads(repo: string, fetcher: typeof fetch = fetch): () => Promise<Download[]> {
  let cache: { at: number; data: Download[] } | null = null;
  return async () => {
    if (cache && Date.now() - cache.at < 10 * 60_000) return cache.data;
    const response = await fetcher(`https://api.github.com/repos/${repo}/releases?per_page=20`, {
      headers: { accept: "application/vnd.github+json", "user-agent": "topbar-installs" },
    });
    if (!response.ok) throw new Error(`github ${response.status}`);
    const releases = (await response.json()) as { tag_name: string; assets: { name: string; download_count: number }[] }[];
    const data = releases.map((r) => ({
      tag: r.tag_name,
      assets: r.assets.map((a) => ({ name: a.name, downloads: a.download_count })),
    }));
    cache = { at: Date.now(), data };
    return data;
  };
}
