/**
 * Detail sub-page navigation levels: detail -> model library -> advanced, detail -> keys, detail -> web search settings.
 * Web represents the level with URL query parameters `?view=library[&key=<id>]|keys|web|advanced&model=<id>[&readonly=1]`: push on enter,
 * browser back goes level by level, and a refresh restores from the URL. Model ids contain `/`, so they go in query parameters rather than path segments. Edit Connection is not in the URL (as today).
 */

export type RelayDetailPage =
  | { view: 'board' }
  /** keyID: open the model library filtered by key(id); the first frame already has that filter. */
  | { view: 'library'; keyID?: string }
  | { view: 'keys' }
  /** Web search settings page. */
  | { view: 'web' }
  | { view: 'advanced'; modelID: string; readOnly: boolean };

export function parseRelayDetailPage(search: string | URLSearchParams): RelayDetailPage {
  const params = typeof search === 'string' ? new URLSearchParams(search) : search;
  switch (params.get('view')) {
    case 'library': {
      const keyID = params.get('key');
      return keyID ? { view: 'library', keyID } : { view: 'library' };
    }
    case 'keys':
      return { view: 'keys' };
    case 'web':
      return { view: 'web' };
    case 'advanced': {
      const modelID = params.get('model');
      // An advanced page without a model has no content: fall back to its level above.
      if (!modelID) return { view: 'library' };
      return { view: 'advanced', modelID, readOnly: params.get('readonly') === '1' };
    }
    default:
      return { view: 'board' };
  }
}

/** The query string of this level (including `?`); detail itself is the empty string. */
export function relayDetailPageQuery(page: RelayDetailPage): string {
  if (page.view === 'board') return '';
  const params = new URLSearchParams({ view: page.view });
  if (page.view === 'advanced') {
    params.set('model', page.modelID);
    if (page.readOnly) params.set('readonly', '1');
  }
  if (page.view === 'library' && page.keyID) params.set('key', page.keyID);
  return `?${params.toString()}`;
}

/** One level up: advanced -> model library; model library / keys / web search settings -> detail. */
export function relayDetailParentPage(page: RelayDetailPage): RelayDetailPage {
  if (page.view === 'advanced') return { view: 'library' };
  return { view: 'board' };
}
