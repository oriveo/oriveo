// Settings › Web Search page × real search store (fake-indexeddb) × real English copy.
// The catalog uses the production built-in snapshot (returned in the /api/search/catalog shape); the forwarding route uses a fetch stub.

import 'fake-indexeddb/auto';
import type { ReactElement } from 'react';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { IntlProvider } from 'use-intl';
import type { Provider } from '@oriveo/shared';
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '@oriveo/core/search/catalog-snapshot';
import enMessages from '../../../messages/en.json';

const mocks = vi.hoisted(() => ({
  push: vi.fn(),
  providers: [] as Partial<Provider>[],
}));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.push, replace: vi.fn() }),
}));
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: { providers: Partial<Provider>[] }) => unknown) => selector({ providers: mocks.providers }),
}));

import { setActiveUID } from '../../../lib/infra/storage/partition';
import {
  closeSearchDB,
  getDefaultSearchServiceId,
  listSearchServices,
  readSearchServiceKey,
  saveCustomSearchService,
  savePresetSearchService,
  setDefaultSearchServiceId,
} from '../../../lib/search/search-service-store';
import { __resetSettingsCatalogForTests } from '../../../lib/search/search-settings-data';
import { FEATURE_BADGE_IDS, isUnseen } from '../../../lib/core/feature-badges';
import { WebSearchPage } from './WebSearchPage';

const snapshotServices = (SEARCH_CATALOG_SNAPSHOT_VIEW as { data: { services: unknown[] } }).data.services;

let uid = '';
let uidCounter = 0;
let forwardResponse: unknown = null;
const forwardBodies: Array<Record<string, unknown>> = [];

function renderPage(ui: ReactElement = <WebSearchPage />) {
  return render(
    <IntlProvider locale="en" messages={enMessages} timeZone="UTC" onError={(error) => { throw error; }}>
      {ui}
    </IntlProvider>,
  );
}

/** The add row is disabled until the partition uid is read: wait until it is clickable before opening the sheet. */
async function openAddSheet(): Promise<HTMLElement> {
  const add = await screen.findByRole('button', { name: enMessages.webSearch.main.add });
  await waitFor(() => expect((add as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(add);
  return screen.findByRole('dialog');
}

beforeEach(async () => {
  uidCounter += 1;
  uid = `web-search-user-${uidCounter}`;
  await setActiveUID(uid);
  __resetSettingsCatalogForTests();
  mocks.push.mockReset();
  mocks.providers = [];
  forwardBodies.length = 0;
  forwardResponse = { ok: false, errorClass: 'auth_invalid', card: { headline: 'key_rejected', primaryAction: 'update_key' } };
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/search/catalog') {
      return new Response(JSON.stringify({ available: true, entries: snapshotServices, withdrawn: [] }), { status: 200 });
    }
    if (url === '/api/search/forward') {
      forwardBodies.push(JSON.parse(String(init?.body)));
      return new Response(JSON.stringify(forwardResponse), { status: 200 });
    }
    return new Response('{}', { status: 404 });
  }));
});

afterEach(async () => {
  vi.unstubAllGlobals();
  await closeSearchDB(uid);
});

describe('WebSearchPage', () => {
  it('empty list: description, group, "None yet" hint and add row; entering clears the home badge', async () => {
    renderPage();
    const list = await screen.findByTestId('web-search-list');
    expect(await within(list).findByText(enMessages.webSearch.main.empty)).toBeTruthy();
    expect(within(list).getByRole('button', { name: enMessages.webSearch.main.add })).toBeTruthy();
    expect(screen.getByText(enMessages.webSearch.main.intro)).toBeTruthy();
    expect(list.querySelectorAll('[data-service-row]')).toHaveLength(0);
    expect(isUnseen(FEATURE_BADGE_IDS.settingsWebSearch)).toBe(false);
  });

  it('add sheet: with a DeepSeek connection the reuse group comes first, and the domestic / overseas / custom groups render per searchAddSheetSections', async () => {
    mocks.providers = [{ id: 'p-ds', kind: 'deepseek', apiKey: 'sk-deepseek' }];
    renderPage();
    const dialog = await openAddSheet();
    await waitFor(() => expect(dialog.querySelector('[data-add-section="reuse"]')).toBeTruthy());
    const sections = [...dialog.querySelectorAll('[data-add-section]')].map((el) => (el as HTMLElement).dataset.addSection);
    expect(sections).toEqual(['reuse', 'domestic', 'overseas', 'custom']);
    const reuse = dialog.querySelector('[data-add-section="reuse"]') as HTMLElement;
    expect([...reuse.querySelectorAll('[data-add-row]')].map((el) => (el as HTMLElement).dataset.addRow)).toEqual(['deepseek']);
    expect(within(reuse).getByText(/With your “DeepSeek” connection/)).toBeTruthy();
    const domestic = dialog.querySelector('[data-add-section="domestic"]') as HTMLElement;
    expect([...domestic.querySelectorAll('[data-add-row]')].map((el) => (el as HTMLElement).dataset.addRow)).toEqual(['zhipu', 'kimi']);
    // Tavily: non-currency pricing shows no unit price, only the free quota (thousands separator) + no card required
    const tavily = dialog.querySelector('[data-add-row="tavily"]') as HTMLElement;
    expect(within(tavily).getByText('1,000 free searches a month · no card needed')).toBeTruthy();
    expect(within(dialog).getByText(enMessages.webSearch.add.customTitle)).toBeTruthy();
  });

  it('agree and test: a failed test shows the error headline and action, and the service is not saved', async () => {
    renderPage();
    const dialog = await openAddSheet();
    fireEvent.click(await waitFor(() => {
      const row = dialog.querySelector('[data-add-row="tavily"]') as HTMLElement | null;
      if (!row) throw new Error('tavily row not rendered');
      return row;
    }));
    // The Web consent sentence has an extra clause "forwarded through the Oriveo web service"
    expect(dialog.querySelector('[data-consent-line="webForwarded"]')).toBeTruthy();
    fireEvent.change(within(dialog).getByLabelText(enMessages.webSearch.connect.keyLabel), { target: { value: '  tvly-bad-key  ' } });
    fireEvent.click(within(dialog).getByRole('button', { name: enMessages.webSearch.consent.agree }));
    const failure = await within(dialog).findByTestId('web-search-test-failure');
    expect(within(failure).getByText(enMessages.webSearch.error.keyRejected)).toBeTruthy();
    expect(within(failure).getByRole('button', { name: enMessages.webSearch.action.updateKey })).toBeTruthy();
    expect(forwardBodies).toEqual([expect.objectContaining({ kind: 'preset', serviceId: 'tavily', regionId: 'global', boundHost: 'api.tavily.com', key: 'tvly-bad-key', count: 5 })]);
    expect(await listSearchServices(uid)).toEqual([]);
    expect(within(dialog).queryByTestId('web-search-consent-passed')).toBeNull();
  });

  it('agree and test: saved only on pass, and the first service becomes the default', async () => {
    forwardResponse = { ok: true, kind: 'results', results: [{ title: 'a', url: 'https://a.example', snippet: '' }] };
    renderPage();
    const dialog = await openAddSheet();
    fireEvent.click(await waitFor(() => {
      const row = dialog.querySelector('[data-add-row="exa"]') as HTMLElement | null;
      if (!row) throw new Error('exa row not rendered');
      return row;
    }));
    fireEvent.change(within(dialog).getByLabelText(enMessages.webSearch.connect.keyLabel), { target: { value: 'exa-good-key' } });
    fireEvent.click(within(dialog).getByRole('button', { name: enMessages.webSearch.consent.agree }));
    expect(await within(dialog).findByText(enMessages.webSearch.consent.passedDefault)).toBeTruthy();
    const saved = await listSearchServices(uid);
    expect(saved.map((s) => (s.kind === 'preset' ? [s.serviceId, s.boundHost] : null))).toEqual([['exa', 'api.exa.ai']]);
  });

  it('delete default service: the confirmation names the new default (computed by resolveDefaultSearchService), and after deletion the default becomes the earliest added', async () => {
    await savePresetSearchService(uid, {
      id: 'svc-tavily', kind: 'preset', serviceId: 'tavily', regionId: 'global', boundHost: 'api.tavily.com', connectionRef: null, createdAt: 1, updatedAt: 1,
    }, { key: 'tvly-key-1234' });
    await saveCustomSearchService(uid, {
      id: 'svc-searx', kind: 'custom', name: 'Home SearXNG', protocol: 'searxng', address: 'https://searx.example.com', mapping: null, createdAt: 2, updatedAt: 2,
    });
    await setDefaultSearchServiceId(uid, 'svc-searx');

    renderPage();
    const list = await screen.findByTestId('web-search-list');
    const searxRow = await waitFor(() => {
      const row = list.querySelector('[data-service-row="svc-searx"]') as HTMLElement | null;
      if (!row) throw new Error('row not rendered');
      return row;
    });
    expect(within(searxRow).getByText(enMessages.webSearch.badge.default)).toBeTruthy();
    expect(within(searxRow).getByText(enMessages.webSearch.row.noKey)).toBeTruthy();
    fireEvent.click(searxRow);

    await screen.findByTestId('web-search-detail');
    fireEvent.click(screen.getByRole('button', { name: enMessages.webSearch.detail.delete }));
    const confirm = await screen.findByRole('dialog');
    expect(within(confirm).getByText(/“Tavily” will become the default\./)).toBeTruthy();
    await act(async () => {
      fireEvent.click(within(confirm).getByRole('button', { name: enMessages.webSearch.detail.deleteConfirm }));
    });

    const after = await screen.findByTestId('web-search-list');
    const tavilyRow = await waitFor(() => {
      const row = after.querySelector('[data-service-row="svc-tavily"]') as HTMLElement | null;
      if (!row || !within(row).queryByText(enMessages.webSearch.badge.default)) throw new Error('default not moved yet');
      return row;
    });
    expect(tavilyRow).toBeTruthy();
    expect(after.querySelector('[data-service-row="svc-searx"]')).toBeNull();
    expect((await listSearchServices(uid)).map((s) => s.id)).toEqual(['svc-tavily']);
    expect(await getDefaultSearchServiceId(uid)).toBeNull();
  });

  it('edit custom service: changing the address source shows the key field, the new key and new address are tested together (count 5), and saved only on pass', async () => {
    forwardResponse = { ok: true, kind: 'empty' };
    await saveCustomSearchService(uid, {
      id: 'svc-searx', kind: 'custom', name: 'Home SearXNG', protocol: 'searxng', address: 'https://searx.example.com', mapping: null, resultCount: 8, createdAt: 1, updatedAt: 1,
    }, { key: 'old-searx-key' });

    renderPage();
    const list = await screen.findByTestId('web-search-list');
    fireEvent.click(await waitFor(() => {
      const row = list.querySelector('[data-service-row="svc-searx"]') as HTMLElement | null;
      if (!row) throw new Error('row not rendered');
      return row;
    }));
    const detail = await screen.findByTestId('web-search-detail');
    // The key field is not shown when the source is unchanged
    expect(within(detail).queryByLabelText(new RegExp(`^${enMessages.webSearch.custom.key}`))).toBeNull();
    fireEvent.change(within(detail).getByLabelText(enMessages.webSearch.custom.address), { target: { value: 'https://search.other.example/base' } });
    expect(within(detail).getByText(enMessages.webSearch.detail.addressChangeNotice)).toBeTruthy();
    const keyField = within(detail).getByLabelText(new RegExp(`^${enMessages.webSearch.custom.key}`));
    fireEvent.change(keyField, { target: { value: ' new-searx-key ' } });
    await act(async () => {
      fireEvent.click(within(detail).getByRole('button', { name: enMessages.webSearch.detail.save }));
    });

    await waitFor(() => expect(forwardBodies).toHaveLength(1));
    expect(forwardBodies[0]).toEqual(expect.objectContaining({
      kind: 'custom', address: 'https://search.other.example/base', protocol: 'searxng', key: 'new-searx-key', count: 5,
    }));
    await waitFor(async () => {
      const [saved] = await listSearchServices(uid);
      expect(saved.kind === 'custom' ? saved.address : null).toBe('https://search.other.example/base');
    });
    expect(await readSearchServiceKey(uid, 'svc-searx')).toBe('new-searx-key');
  });

  it('edit custom service: changing only the name saves directly without a test', async () => {
    await saveCustomSearchService(uid, {
      id: 'svc-searx', kind: 'custom', name: 'Home SearXNG', protocol: 'searxng', address: 'https://searx.example.com', mapping: null, createdAt: 1, updatedAt: 1,
    }, { key: 'old-searx-key' });
    renderPage();
    const list = await screen.findByTestId('web-search-list');
    fireEvent.click(await waitFor(() => {
      const row = list.querySelector('[data-service-row="svc-searx"]') as HTMLElement | null;
      if (!row) throw new Error('row not rendered');
      return row;
    }));
    const detail = await screen.findByTestId('web-search-detail');
    fireEvent.change(within(detail).getByLabelText(enMessages.webSearch.custom.name), { target: { value: 'Lab SearXNG' } });
    await act(async () => {
      fireEvent.click(within(detail).getByRole('button', { name: enMessages.webSearch.detail.save }));
    });
    await waitFor(async () => {
      const [saved] = await listSearchServices(uid);
      expect(saved.kind === 'custom' ? saved.name : null).toBe('Lab SearXNG');
    });
    expect(forwardBodies).toEqual([]);
    expect(await readSearchServiceKey(uid, 'svc-searx')).toBe('old-searx-key');
  });

  it('detail page "Advanced" is a single row: title Advanced, value is the result count, tapping opens the count page', async () => {
    await saveCustomSearchService(uid, {
      id: 'svc-searx', kind: 'custom', name: 'Home SearXNG', protocol: 'searxng', address: 'https://searx.example.com', mapping: null, resultCount: 8, createdAt: 1, updatedAt: 1,
    });
    renderPage();
    const list = await screen.findByTestId('web-search-list');
    fireEvent.click(await waitFor(() => {
      const row = list.querySelector('[data-service-row="svc-searx"]') as HTMLElement | null;
      if (!row) throw new Error('row not rendered');
      return row;
    }));
    const detail = await screen.findByTestId('web-search-detail');
    const advanced = within(detail).getByTestId('web-search-advanced');
    expect(advanced.textContent).toBe(`${enMessages.webSearch.detail.advanced}8 results per search`);
    expect(within(detail).queryByRole('heading', { name: enMessages.webSearch.detail.advanced })).toBeNull();
    fireEvent.click(advanced);
    expect(await screen.findByTestId('web-search-result-count')).toBeTruthy();
  });
});

