// Usage (next dev only, `npm run dev:app`): http://localhost:3001/dev/memory-shots/<page name>; page names are in ../memory-shots-pages.ts.
// Production builds answer notFound for this route; the data, client shell and shared manifest are only dynamically imported in the dev branch (pruned from production bundles).
// Same isolation fence as the relay shots (StoreProvider installs it for /dev/*-shots/ routes).
// Next 16: this dynamic route must not export generateStaticParams (otherwise it is treated as static, and SSR reading cookies() returns 500).
import { notFound } from 'next/navigation';

export default async function MemoryShotsPage({ params }: { params: Promise<{ page: string }> }) {
  if (process.env.NODE_ENV !== 'production') {
    const { page } = await params;
    const { isMemoryShotPage } = await import('../memory-shots-pages');
    if (!isMemoryShotPage(page)) notFound();
    const { MemoryShotsClient } = await import('../MemoryShotsClient');
    const { isCompleteMemoryShotsManifest } = await import('../memory-shots-data');
    type Manifest = Parameters<typeof MemoryShotsClient>[0]['manifest'];
    // The Turbopack root is web; the manifest lives outside the root and cannot be imported: walk up from cwd to find the repo root and read the file.
    const { readFileSync } = await import('node:fs');
    const { dirname, join } = await import('node:path');
    let manifest: Manifest | null = null;
    let problem = 'not found';
    for (let dir = process.cwd(); ; dir = dirname(dir)) {
      let text: string;
      try {
        text = readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'memory.v1.json'), 'utf8');
      } catch {
        if (dirname(dir) === dir) break;
        continue;
      }
      try {
        const parsed: unknown = JSON.parse(text);
        if (!isCompleteMemoryShotsManifest(parsed)) problem = 'missing fields';
        else if (!parsed.pages.some((entry) => entry.name === page)) problem = `has no page ${page}`;
        else manifest = parsed;
      } catch (error) {
        problem = `unparsable (${error instanceof Error ? error.message : String(error)})`;
      }
      break;
    }
    if (!manifest) {
      console.error(`[memory-shots] shots manifest shared/test-fixtures/shots/memory.v1.json ${problem}; refusing to open ${page}.`);
      notFound();
    }
    return <MemoryShotsClient page={page} manifest={manifest} />;
  }
  notFound();
}
