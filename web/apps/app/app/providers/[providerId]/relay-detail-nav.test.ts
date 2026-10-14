import { describe, expect, it } from 'vitest';
import {
  parseRelayDetailPage,
  relayDetailPageQuery,
  relayDetailParentPage,
  type RelayDetailPage,
} from './relay-detail-nav';

/**
 * Detail sub-page navigation levels: Web represents the level with URL query parameters,
 * push on enter, level by level on back; this locks query-string generation / parsing and "up one level". Page-level wiring is in RelayDetail.test.tsx.
 */

const board: RelayDetailPage = { view: 'board' };
const library: RelayDetailPage = { view: 'library' };
const keys: RelayDetailPage = { view: 'keys' };

describe('NAV-RELAY query parameters', () => {
  it('NAV-RELAY-01 detail -> model library -> advanced, going up level by level returns to detail; model ids containing / round-trip', () => {
    const advanced: RelayDetailPage = { view: 'advanced', modelID: 'openai/gpt-5.4', readOnly: false };
    expect(relayDetailPageQuery(board)).toBe('');
    expect(relayDetailPageQuery(library)).toBe('?view=library');
    const query = relayDetailPageQuery(advanced);
    expect(query).toBe('?view=advanced&model=openai%2Fgpt-5.4');
    expect(parseRelayDetailPage(query)).toEqual(advanced);
    expect(relayDetailParentPage(advanced)).toEqual(library);
    expect(relayDetailParentPage(library)).toEqual(board);
    expect(relayDetailParentPage(board)).toEqual(board);
  });

  it('NAV-RELAY-02 detail -> keys page, the level above is detail', () => {
    expect(relayDetailPageQuery(keys)).toBe('?view=keys');
    expect(parseRelayDetailPage('?view=keys')).toEqual(keys);
    expect(relayDetailParentPage(keys)).toEqual(board);
  });

  it('NAV-RELAY-03 read-only advanced carries readonly=1, the level above is the model library', () => {
    const readOnly: RelayDetailPage = { view: 'advanced', modelID: 'gpt-5.4', readOnly: true };
    expect(relayDetailPageQuery(readOnly)).toBe('?view=advanced&model=gpt-5.4&readonly=1');
    expect(parseRelayDetailPage(new URLSearchParams('view=advanced&model=gpt-5.4&readonly=1'))).toEqual(readOnly);
    expect(relayDetailParentPage(readOnly)).toEqual(library);
  });

  it('NAV-RELAY invalid parameters: unknown view falls back to detail, advanced without a model falls back to the model library', () => {
    expect(parseRelayDetailPage('')).toEqual(board);
    expect(parseRelayDetailPage('?view=edit')).toEqual(board);
    expect(parseRelayDetailPage('?view=advanced')).toEqual(library);
    expect(parseRelayDetailPage('?view=advanced&model=')).toEqual(library);
  });
});
