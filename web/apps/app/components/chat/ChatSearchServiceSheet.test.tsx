// "Search via" page last row "Add search service" → production onboarding sheet saves successfully → this conversation's source is persisted.
// Real search store (fake-indexeddb) x real English copy; the catalog uses the built-in snapshot (/api/search/catalog shape) and the forwarding route uses a fetch stub.

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import type { ReactElement } from 'react';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { IntlProvider } from 'use-intl';
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '@oriveo/core/search/catalog-snapshot';
import enMessages from '../../messages/en.json';

vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn(), replace: vi.fn() }) }));
vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: <T,>(selector: (state: { providers: never[] }) => T) => selector({ providers: [] }),
  tryGetVanillaStore: () => null,
}));
vi.mock('../../lib/core/telemetry', () => ({ trackEvent: vi.fn() }));

import { setActiveUID } from '../../lib/infra/storage/partition';
import { closeSearchDB, getConversationSearchSource, listSearchServices } from '../../lib/search/search-service-store';
import { __resetSettingsCatalogForTests } from '../../lib/search/search-settings-data';
import type { ChatSearchServiceSheetRequest } from './ChatSearchServiceSheet';

const snapshotServices = (SEARCH_CATALOG_SNAPSHOT_VIEW as { data: { services: unknown[] } }).data.services;

function loadManifest() {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'webSearch.v1.json'), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}

function withIntl(ui: ReactElement) {
  return <IntlProvider locale="en" messages={enMessages} timeZone="UTC" onError={() => {}}>{ui}</IntlProvider>;
}

let uid = '';
let counter = 0;

beforeAll(async () => {
  await import('../../app/dev/webSearch-shots/webSearch-shots-data');
  await import('./ModelOptionsPopover');
  await import('./ChatSearchServiceSheet');
}, 60_000);

beforeEach(async () => {
  counter += 1;
  uid = `chat-sheet-user-${counter}`;
  await setActiveUID(uid);
  __resetSettingsCatalogForTests();
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (url === '/api/search/catalog') return new Response(JSON.stringify({ available: true, entries: snapshotServices, withdrawn: [] }), { status: 200 });
    if (url === '/api/search/forward') return new Response(JSON.stringify({ ok: true, kind: 'results', results: [{ title: 'a', url: 'https://a.example', snippet: '' }] }), { status: 200 });
    return new Response('{}', { status: 404 });
  }));
});

afterEach(async () => {
  cleanup();
  vi.unstubAllGlobals();
  await closeSearchDB(uid);
});

/** Open the "Search via" page, click the last row, and get the onboarding request the production panel hands to its host. */
async function requestFromPickerAddRow(panelWritable: boolean): Promise<ChatSearchServiceSheetRequest> {
  const data = await import('../../app/dev/webSearch-shots/webSearch-shots-data');
  const { ModelOptionsPopover } = await import('./ModelOptionsPopover');
  const shot = data.webSearchShotPlan('webSearchSourcePicker' as never, loadManifest()).modelOptions!;
  const onOpen = vi.fn();
  render(withIntl(
    <ModelOptionsPopover
      provider={shot.provider} model={shot.model} webControl={shot.webControl} webPreference={shot.webPreference}
      conversationId="conv-1" transportIdentity="shots" initialPane="searchSource"
      externalSearchSource={{ ...shot.externalSearchSource, panelWritable }}
      onOpenSearchServiceSheet={onOpen} onClose={() => {}}
    />,
  ));
  fireEvent.click(screen.getByRole('button', { name: enMessages.webSearch.main.add }));
  expect(onOpen).toHaveBeenCalledTimes(1);
  cleanup();
  return onOpen.mock.calls[0][0] as ChatSearchServiceSheetRequest;
}

/** Production onboarding sheet: pick Exa, enter a key, agree and test, wait for "Passed". */
async function addExaThroughSheet(request: ChatSearchServiceSheetRequest) {
  const { ChatSearchServiceSheet } = await import('./ChatSearchServiceSheet');
  render(withIntl(<ChatSearchServiceSheet request={request} onClose={() => {}} />));
  const dialog = await screen.findByRole('dialog');
  fireEvent.click(await waitFor(() => {
    const row = dialog.querySelector('[data-add-row="exa"]') as HTMLElement | null;
    if (!row) throw new Error('exa row not rendered');
    return row;
  }));
  fireEvent.change(within(dialog).getByLabelText(enMessages.webSearch.connect.keyLabel), { target: { value: 'exa-good-key' } });
  fireEvent.click(within(dialog).getByRole('button', { name: enMessages.webSearch.consent.agree }));
  await within(dialog).findByText(enMessages.webSearch.consent.passedDefault);
  const saved = await listSearchServices(uid);
  expect(saved).toHaveLength(1);
  return saved[0];
}

describe('adding a search service from the "Search via" page → production save callback', () => {
  it('save succeeds → this conversation\'s conversationSource records methods[modelKey] = external, serviceId = the new service', async () => {
    const request = await requestFromPickerAddRow(true);
    const saved = await addExaThroughSheet(request);
    await waitFor(async () => {
      expect(await getConversationSearchSource(uid, 'conv-1')).toEqual({
        methods: { 'c-openai:GPT-5.6': 'external' },
        serviceId: saved.id,
        serviceName: 'Exa',
        notice: null,
      });
    });
  });

  it('oneTapArms false (panel cannot persist) → the service is still saved, nothing is written to the source', async () => {
    const request = await requestFromPickerAddRow(false);
    expect(request.arm).toBeUndefined();
    await addExaThroughSheet(request);
    expect(await getConversationSearchSource(uid, 'conv-1')).toBeNull();
  });
});
