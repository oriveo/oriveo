'use client';

import { useEffect, useMemo, useState } from 'react';
import { WebSearchEntryOverride } from '../../../lib/search/use-web-search-entry';
import { Settings } from '../../settings/Settings';
import { WebSearchPage } from '../../settings/web-search/WebSearchPage';
import { relayShotsFenceInstalled } from '../relay-shots/relay-shots-fence';
import { webSearchShotPlan, type SearchTurnShotFixture, type WebSearchShotsManifest } from './webSearch-shots-data';
import type { WebSearchShotPage } from './webSearch-shots-pages';
import { WebSearchChatHost } from './WebSearchChatHost';
import { WebSearchModelOptionsHost } from './WebSearchModelOptionsHost';

/** ThemeInitScript writes dark when there is no preference: shots follow the system appearance (the tool's --appearance). */
function followSystemAppearance(): () => void {
  const query = window.matchMedia('(prefers-color-scheme: dark)');
  const apply = () => {
    document.documentElement.dataset.theme = query.matches ? 'dark' : 'light';
  };
  apply();
  query.addEventListener('change', apply);
  return () => query.removeEventListener('change', apply);
}

export function WebSearchShotsClient({
  page,
  manifest,
  searchTurn,
}: {
  page: WebSearchShotPage;
  manifest: WebSearchShotsManifest;
  /** Chat pages only: the replyCases they name from the shared search-contracts/search-turn.v1.json. */
  searchTurn?: SearchTurnShotFixture;
}) {
  const [state, setState] = useState<'preparing' | 'refused' | 'ready'>('preparing');
  const plan = useMemo(() => webSearchShotPlan(page, manifest, searchTurn), [page, manifest, searchTurn]);
  const entryOverride = useMemo(() => ({ name: plan.defaultName }), [plan]);

  useEffect(() => {
    // Entered from another page client-side: the store already hydrated the normal way. Refuse; reload directly.
    if (!relayShotsFenceInstalled()) {
      console.error('[webSearch-shots] isolation fence is not installed; refusing to open. Reload this URL directly.');
      setState('refused');
      return;
    }
    const stopAppearance = followSystemAppearance();
    setState('ready');
    return stopAppearance;
  }, []);

  if (state === 'refused') {
    return <p data-relay-shots-refused>Web search shots: isolation unavailable. Reload this URL directly.</p>;
  }
  if (state === 'preparing') return null;
  if (plan.open === 'settingsHome') {
    return (
      <WebSearchEntryOverride.Provider value={entryOverride}>
        <Settings />
      </WebSearchEntryOverride.Provider>
    );
  }
  if (plan.chat) return <WebSearchChatHost shot={plan.chat} />;
  if (plan.modelOptions) return <WebSearchModelOptionsHost shot={plan.modelOptions} />;
  return <WebSearchPage source={plan.source} />;
}
