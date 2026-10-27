// Usage (next dev only, `npm run dev:app`): http://localhost:3001/dev/webSearch-shots/<page name>; page names are in ../webSearch-shots-pages.ts.
// A production build returns notFound for this route; the data, client shell and shared manifest are loaded only via dynamic import in the dev branch (the whole block is tree-shaken out of production).
// Same isolation fence as the relay shots (StoreProvider installs it for /dev/*-shots/ routes).
// Next 16: this dynamic route must not export generateStaticParams (otherwise it is treated as statically generated and SSR reading cookies() returns 500).
import { notFound } from 'next/navigation';

export default async function WebSearchShotsPage({ params }: { params: Promise<{ page: string }> }) {
  if (process.env.NODE_ENV !== 'production') {
    const { page } = await params;
    const { isWebSearchShotPage } = await import('../webSearch-shots-pages');
    if (!isWebSearchShotPage(page)) notFound();
    const { WebSearchShotsClient } = await import('../WebSearchShotsClient');
    const { isCompleteWebSearchShotsManifest } = await import('../webSearch-shots-data');
    type Manifest = Parameters<typeof WebSearchShotsClient>[0]['manifest'];
    // The Turbopack root is the web app directory and the manifest lives outside it so it cannot be imported: walk up from cwd to find the repo root and read the file directly.
    const { readFileSync } = await import('node:fs');
    const { dirname, join } = await import('node:path');
    let manifest: Manifest | null = null;
    let problem = 'not found';
    for (let dir = process.cwd(); ; dir = dirname(dir)) {
      let text: string;
      try {
        text = readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'webSearch.v1.json'), 'utf8');
      } catch {
        if (dirname(dir) === dir) break;
        continue;
      }
      try {
        const parsed: unknown = JSON.parse(text);
        if (!isCompleteWebSearchShotsManifest(parsed)) problem = 'missing fields';
        else if (!parsed.pages.some((entry) => entry.name === page)) problem = `has no page ${page}`;
        else manifest = parsed;
      } catch (error) {
        problem = `unparsable (${error instanceof Error ? error.message : String(error)})`;
      }
      break;
    }
    if (!manifest) {
      console.error(`[webSearch-shots] shots manifest shared test-fixtures/shots/webSearch.v1.json ${problem}; refusing to open ${page}.`);
      notFound();
    }
    // Chat pages run the production search-turn chain over the shared search-contracts/search-turn.v1.json replyCases.
    type SearchTurn = NonNullable<Parameters<typeof WebSearchShotsClient>[0]['searchTurn']>;
    const replyCase = manifest.pages.find((entry) => entry.name === page)?.preset.replyCase;
    let searchTurn: SearchTurn | undefined;
    if (replyCase) {
      for (let dir = process.cwd(); ; dir = dirname(dir)) {
        let text: string;
        try {
          text = readFileSync(join(dir, 'shared', 'search-contracts', 'search-turn.v1.json'), 'utf8');
        } catch {
          if (dirname(dir) === dir) break;
          continue;
        }
        const parsed = JSON.parse(text) as SearchTurn;
        searchTurn = { replyCases: (parsed.replyCases ?? []).filter((c) => c.caseId === replyCase) };
        break;
      }
      if (!searchTurn?.replyCases.length) {
        console.error(`[webSearch-shots] shared search-contracts/search-turn.v1.json has no replyCase ${replyCase}; refusing to open ${page}.`);
        notFound();
      }
    }
    return <WebSearchShotsClient page={page} manifest={manifest} searchTurn={searchTurn} />;
  }
  notFound();
}
