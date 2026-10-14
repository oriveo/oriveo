import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// "Web search" row on the detail page model card and saving on the web search settings page.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider, RelayRequestedConfig } from '@oriveo/shared';
import { makeRelayRequested } from '@oriveo/shared';
import { createAppStore } from '../../../lib/core/store/app-store';
import { saveRelayWebSearchSettings } from '../../../lib/core/provider-ops';
import {
  effectiveRelayWebFragmentsForProvider,
  readStoredRelayWebFragments,
  saveRelayWebFragment,
} from '../../../lib/core/chat/relay-web-fragments';
import { relayDetailBoard } from './relay-detail-board';
import { parseRelayDetailPage, relayDetailPageQuery, relayDetailParentPage } from './relay-detail-nav';

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  getActiveUIDSync: () => 'user-1',
  getActiveUID: async () => 'user-1',
}));

function relay(id: string, requested: Partial<RelayRequestedConfig>): Provider {
  return {
    id,
    kind: 'relay',
    customName: 'Relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk',
    apiKeyPreview: 'sk-…',
    baseURLText: 'https://relay.example',
    relayKind: 'codex_style',
    relayRequested: { transport: 'openai_responses', authMode: 'bearer', ...requested },
    createdAt: '',
    updatedAt: '',
  } as unknown as Provider;
}

function webRow(provider: Provider) {
  const configured = Object.keys(effectiveRelayWebFragmentsForProvider(provider)).length > 0;
  return relayDetailBoard(provider, null, { webSearchConfigured: configured }).modelRows.find((row) => row.id === 'webSearch');
}

beforeEach(() => {
  localStorage.clear();
});

describe('detail page model card "Web search" row', () => {
  it('a relay has a web search row below the model library row (title Web Search, subtitle, opens web search settings); a local engine does not', () => {
    const board = relayDetailBoard(relay('r1', {}), null, { webSearchConfigured: false });
    // After web search comes the connection-level Parameters row.
    expect(board.modelRows.map((row) => row.id)).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    expect(board.modelRows[1]).toMatchObject({
      titleKey: 'common.capabilityControlWebSearch',
      value: { key: 'pages.relayDetail.webSearch.rowSubtitle' },
      action: 'openWebSearch',
    });
    const local = relayDetailBoard(relay('r2', { transport: 'openai_chat_completions', engineProfile: 'ollama' }), null, { webSearchConfigured: true });
    expect(local.modelRows.map((row) => row.id)).not.toContain('webSearch');
  });

  it('status follows the effective segments: none -> not configured; one saved -> configured; only a legacy-field mapping also counts as configured', () => {
    expect(webRow(relay('r1', {}))?.trailingKey).toBe('pages.relayDetail.webSearch.statusNotSet');
    saveRelayWebFragment('r1', 'anthropic_messages', '{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}');
    expect(webRow(relay('r1', {}))?.trailingKey).toBe('pages.relayDetail.webSearch.statusSet');
    expect(webRow(relay('r3', { hasWebSearch: true }))?.trailingKey).toBe('pages.relayDetail.webSearch.statusSet');
  });

  it('the web search settings page is a real navigation level: ?view=web, back returns to detail', () => {
    expect(parseRelayDetailPage('?view=web')).toEqual({ view: 'web' });
    expect(relayDetailPageQuery({ view: 'web' })).toBe('?view=web');
    expect(relayDetailParentPage({ view: 'web' })).toEqual({ view: 'board' });
  });
});

describe('legacy fields: Edit Connection carries them over, only saving on the web search settings page clears them', () => {
  it('changing the connection kind carries both legacy fields over unchanged', () => {
    const preserved = makeRelayRequested('openai_compatible', { transport: 'openai_responses', hasWebSearch: true, webSearchProfile: 'or_web' } as RelayRequestedConfig);
    expect(preserved).toMatchObject({ hasWebSearch: true, webSearchProfile: 'or_web' });
  });

  it('saving writes to storage (empty segment = delete that segment) and clears both legacy fields before persisting the connection', async () => {
    const store = createAppStore();
    const provider = relay('r9', { hasWebSearch: true, webSearchProfile: 'or_web' });
    store.getState().addProvider(provider);
    saveRelayWebFragment('r9', 'gemini_generate_content', '{"tools":[{"googleSearch":{}}]}');

    const ok = await saveRelayWebSearchSettings(store, provider, {
      openai_chat_completions: { plugins: [{ id: 'web' }] },
    });
    expect(ok).toBe(true);
    expect(readStoredRelayWebFragments('r9')).toEqual({ openai_chat_completions: { plugins: [{ id: 'web' }] } });
    const saved = store.getState().providers.find((item) => item.id === 'r9')!;
    expect(saved.relayRequested).not.toHaveProperty('hasWebSearch');
    expect(saved.relayRequested).not.toHaveProperty('webSearchProfile');
    expect(saved.relayRequested?.transport).toBe('openai_responses');
  });
});
