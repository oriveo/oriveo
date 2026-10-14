// Usage (next dev only, `npm run dev:app`): http://localhost:3001/dev/relay-shots/<page name>; page names are in ../relay-shots-pages.ts.
// Production builds answer notFound for this route; the fake data, fence, client shell and shared manifest are only dynamically imported in the dev branch (pruned from production bundles).
// Next 16: this dynamic route must not export generateStaticParams (otherwise it is treated as static and SSR reading cookies() returns 500).
import { notFound } from 'next/navigation';

export default async function RelayShotsPage({ params }: { params: Promise<{ page: string }> }) {
  if (process.env.NODE_ENV !== 'production') {
    const { page } = await params;
    const { isRelayShotPage } = await import('../relay-shots-pages');
    if (!isRelayShotPage(page)) notFound();
    const { RelayShotsClient } = await import('../RelayShotsClient');
    type Manifest = Parameters<typeof RelayShotsClient>[0]['manifest'];
    // The manifest lives outside the Turbopack root and cannot be imported: walk up from cwd to the repo root and read it as a file.
    const { readFileSync } = await import('node:fs');
    const { dirname, join } = await import('node:path');
    let manifest: Manifest | null = null;
    let problem = 'not found';
    for (let dir = process.cwd(); ; dir = dirname(dir)) {
      let text: string;
      try {
        text = readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'relay.v1.json'), 'utf8');
      } catch {
        if (dirname(dir) === dir) break;
        continue;
      }
      try {
        const parsed = JSON.parse(text) as Partial<Manifest> | null;
        const complete = parsed?.schema === 'oriveo-shots-manifest/v1'
          && typeof parsed.clock === 'object' && parsed.clock !== null
          && typeof parsed.relay === 'object' && parsed.relay !== null
          && Array.isArray(parsed.relay.keys) && Array.isArray(parsed.relay.catalog) && Array.isArray(parsed.relay.enabled)
          && typeof parsed.local === 'object' && parsed.local !== null && Array.isArray(parsed.local.models)
          && Array.isArray(parsed.setupCatalog) && Array.isArray(parsed.pages);
        if (!complete) problem = 'missing fields';
        else if (!parsed.pages!.some((entry) => entry.name === page)) problem = `has no page ${page}`;
        else manifest = parsed as Manifest;
      } catch (error) {
        problem = `unparsable (${error instanceof Error ? error.message : String(error)})`;
      }
      break;
    }
    if (!manifest) {
      console.error(`[relay-shots] shots manifest shared/test-fixtures/shots/relay.v1.json ${problem}; refusing to open ${page}.`);
      notFound();
    }
    return <RelayShotsClient page={page} manifest={manifest} />;
  }
  notFound();
}
