// Usage (next dev only, `npm run dev:app`): http://localhost:3001/dev/context-shots/<page name>; page names are in ../context-shots-pages.ts.
// Production builds answer notFound for this route; the data, client shell and shared manifest are only dynamically imported in the dev branch (pruned from production bundles).
// Same isolation fence as the relay shots (StoreProvider installs it for /dev/*-shots/ routes).
// Next 16: this dynamic route must not export generateStaticParams (otherwise it is treated as static, and SSR reading cookies() returns 500).
import { notFound } from 'next/navigation';

export default async function ContextShotsPage({ params }: { params: Promise<{ page: string }> }) {
  if (process.env.NODE_ENV !== 'production') {
    const { page } = await params;
    const { isContextShotPage } = await import('../context-shots-pages');
    if (!isContextShotPage(page)) notFound();
    const { ContextShotsClient } = await import('../ContextShotsClient');
    const { isCompleteContextShotsManifest } = await import('../context-shots-manifest');
    type Manifest = Parameters<typeof ContextShotsClient>[0]['manifest'];
    // The Turbopack root is web; the manifest lives outside the root and cannot be imported: walk up from cwd to find the repo root and read the file.
    const { readFileSync } = await import('node:fs');
    const { dirname, join } = await import('node:path');
    let manifest: Manifest | null = null;
    let problem = 'not found';
    for (let dir = process.cwd(); ; dir = dirname(dir)) {
      let text: string;
      try {
        text = readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'context.v1.json'), 'utf8');
      } catch {
        if (dirname(dir) === dir) break;
        continue;
      }
      try {
        const parsed: unknown = JSON.parse(text);
        if (!isCompleteContextShotsManifest(parsed)) problem = 'missing fields';
        else if (!parsed.pages.some((entry) => entry.name === page)) problem = `has no page ${page}`;
        else manifest = parsed;
      } catch (error) {
        problem = `unparsable (${error instanceof Error ? error.message : String(error)})`;
      }
      break;
    }
    if (!manifest) {
      console.error(`[context-shots] shots manifest shared/test-fixtures/shots/context.v1.json ${problem}; refusing to open ${page}.`);
      notFound();
    }
    return <ContextShotsClient page={page} manifest={manifest} />;
  }
  notFound();
}
