import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import { buildModelBrowserGroups } from '../../[providerId]/model-browser-groups';
import {
  ProviderDetailNoticeBanner,
  setProviderDetailNotice,
  takeProviderDetailNotice,
} from '../../[providerId]/provider-detail-notice';
import { markRelayHandoff } from '../../new/relay-handoff';
import { RelaySetup } from './RelaySetup';
import {
  relayStepTwoAddManual,
  relayStepTwoCatalog,
  relayStepTwoEnabledSelection,
  relayStepTwoGroupExpanded,
  relayStepTwoGroups,
  relayStepTwoOrderedSelection,
  relayStepTwoSelectGroup,
} from './relay-setup-two-step';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  addProvider: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
  setLastUsedModelRef: vi.fn(),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: vi.fn() }),
  useSearchParams: () => new URLSearchParams(window.location.search),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({ store: 'relay-store' }),
  useAppStore: (selector: (state: unknown) => unknown) => selector({
    providers: [],
    setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    setLastUsedModelRef: mocks.setLastUsedModelRef,
  }),
}));

vi.mock('../../../../lib/core/provider-ops', () => ({
  addProvider: (...args: unknown[]) => mocks.addProvider(...args),
}));

vi.mock('../../../../lib/utils/id-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/utils/id-utils')>()),
  createCanonicalUUID: () => 'relay-provider-id',
}));

vi.mock('@oriveo/ui', () => ({
  Dialog: ({ open, children, ariaLabelledBy }: { open: boolean; children: React.ReactNode; ariaLabelledBy?: string }) =>
    open ? <div role="dialog" aria-labelledby={ariaLabelledBy}>{children}</div> : null,
  BackButton: ({ label, onClick, ...rest }: { label: string; onClick?: () => void; 'data-testid'?: string }) => (
    <button type="button" aria-label={label} onClick={onClick} data-testid={rest['data-testid']} />
  ),
  Button: ({ children, onClick, disabled, className, ...rest }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    className?: string;
    'data-testid'?: string;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled} className={className} data-testid={rest['data-testid']}>
      {children}
    </button>
  ),
}));

interface FakeRelay {
  /** Models each key can list (value = catalog entry). */
  catalogs: Record<string, Array<{ id: string; supported_endpoint_types?: string[] }> | number>;
  /** `<model>@<chat|responses|messages|gemini>` -> HTTP status; unlisted ones return 404. */
  pings?: Record<string, number>;
}

/** Fake relay: GET .../models returns the catalog for the key used in the request; POST is a generation request answered from the ping table. Returns the request log. */
function installFakeRelay(relay: FakeRelay) {
  const log = { gets: [] as string[], posts: [] as string[] };
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
    const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
    if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
    const proxy = JSON.parse(headers.get('x-relay-proxy-config') ?? '{}') as { apiKey?: string };
    const apiKey = proxy.apiKey ?? headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
    if (method === 'GET' && url.endsWith('/models')) {
      log.gets.push(`${apiKey} ${url}`);
      const catalog = relay.catalogs[apiKey] ?? 401;
      if (typeof catalog === 'number') {
        return new Response('{"error":"denied"}', { status: catalog, headers: { 'content-type': 'application/json' } });
      }
      return new Response(JSON.stringify({ object: 'list', data: catalog.map((entry) => ({ object: 'model', ...entry })) }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    const body = JSON.parse(String(init?.body ?? '{}')) as { model?: string };
    const transport = url.endsWith('/messages') ? 'messages' : url.endsWith('/responses') ? 'responses' : url.includes(':generateContent') ? 'gemini' : 'chat';
    log.posts.push(`${apiKey} ${body.model}@${transport}`);
    const status = relay.pings?.[`${body.model}@${transport}`] ?? 404;
    if (status === 200) {
      return new Response('{"id":"ok","choices":[{"message":{"content":"ok"}}]}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response('{"error":{"message":"upstream said no"}}', { status, headers: { 'content-type': 'application/json' } });
  }));
  return log;
}

function model(id: string, group?: { key: string; name: string }): AIModel {
  return {
    id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
    ...(group ? { groupKey: group.key, groupName: group.name } : {}),
  };
}

async function detectAndAdvance(endpoint = 'https://relay.example.com') {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: endpoint } });
  fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
  fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
}

function rowCheckbox(modelID: string): HTMLInputElement {
  return screen.getByRole('checkbox', { name: modelID }) as HTMLInputElement;
}

/** After the relay groups by family the catalog may split into several groups: expand all collapsed groups. */
function expandAllGroups() {
  for (const toggle of document.querySelectorAll('[data-testid="relay-setup-group"] button[aria-expanded="false"]')) {
    fireEvent.click(toggle);
  }
}

/** Select every group (previously the whole catalog was in one domain group, so selecting this group once selected everything). */
function selectAllGroups() {
  const count = screen.getAllByTestId('relay_setup_models_select_group_button').length;
  for (let index = 0; index < count; index += 1) {
    fireEvent.click(screen.getAllByTestId('relay_setup_models_select_group_button')[index]!);
  }
}

beforeEach(() => {
  vi.unstubAllGlobals();
  for (const mock of Object.values(mocks)) mock.mockReset();
  mocks.addProvider.mockResolvedValue(true);
  sessionStorage.clear();
  window.history.replaceState({}, '', '/providers/relay/new');
  takeProviderDetailNotice('relay-provider-id');
});

describe('BOARD-SETUPMODELS-01 group / collapse / expand / select group', () => {
  const claude = { key: 'anthropic', name: 'Claude' };
  const gpt = { key: 'openai', name: 'GPT' };
  const catalog = [
    model('claude-sonnet-4-5', claude), model('gpt-6-sol', gpt), model('claude-opus-4-1', claude),
    model('gpt-5.6-sol', gpt), model('mystery-model'),
  ];

  it('BOARD-SETUPMODELS-01 groups use the same grouping projection as the model library (group names / order verbatim), unmatched ones fall into the domain group', () => {
    // The relay groups by family (family = cached by-model family -> heuristic) and no longer reads metadata groupKey;
    // models of unknown family fall into the "Other" group at the bottom.
    const groups = relayStepTwoGroups({ catalogModels: catalog, host: 'example.com', query: '', otherTitle: 'OTHER' });
    const library = buildModelBrowserGroups({
      catalogModels: catalog, query: '', capFilter: null, sortBy: 'recommended', providerKind: 'relay',
      providerLabel: 'example.com', preserveCatalogOrder: true, otherGroupTitle: 'OTHER',
    });
    expect(groups.map((group) => [group.id, group.title, group.models.map((item) => item.id)]))
      .toEqual(library.map((group) => [group.id, group.title, group.models.map((item) => item.id)]));
    expect(groups.map((group) => group.title)).toEqual(['Anthropic', 'OpenAI', 'OTHER']);
    expect(relayStepTwoOrderedSelection(groups, new Set(['mystery-model', 'gpt-6-sol', 'claude-opus-4-1'])))
      .toEqual(['claude-opus-4-1', 'gpt-6-sol', 'mystery-model']);
  });

  it('BOARD-SETUPMODELS-01 collapsed by default; groups with selected items or search hits expand; manual user state wins; select group during search selects the whole group', () => {
    const full = relayStepTwoGroups({ catalogModels: catalog, host: 'example.com', query: '', otherTitle: 'OTHER' });
    const [claudeGroup, gptGroup] = full;
    const none = new Set<string>();
    expect(relayStepTwoGroupExpanded({ group: claudeGroup!, selected: none, query: '', userExpanded: {} })).toBe(false);
    expect(relayStepTwoGroupExpanded({ group: claudeGroup!, selected: new Set(['claude-opus-4-1']), query: '', userExpanded: {} })).toBe(true);
    expect(relayStepTwoGroupExpanded({ group: gptGroup!, selected: none, query: 'sol', userExpanded: {} })).toBe(true);
    expect(relayStepTwoGroupExpanded({ group: claudeGroup!, selected: new Set(['claude-opus-4-1']), query: '', userExpanded: { anthropic: false } })).toBe(false);
    expect(relayStepTwoGroupExpanded({ group: gptGroup!, selected: none, query: '', userExpanded: { openai: true } })).toBe(true);
    const searched = relayStepTwoGroups({ catalogModels: catalog, host: 'example.com', query: 'opus', otherTitle: 'OTHER' });
    expect(searched.map((group) => group.models.map((item) => item.id))).toEqual([['claude-opus-4-1']]);
    expect([...relayStepTwoSelectGroup(none, full.find((group) => group.id === searched[0]!.id)!)].sort())
      .toEqual(['claude-opus-4-1', 'claude-sonnet-4-5']);
  });

  it('BOARD-SETUPMODELS-01 page: groups collapsed by default; after select group they expand, the selected count shows, the button is not clickable; search hits expand', async () => {
    installFakeRelay({ catalogs: { 'sk-a': [{ id: 'm-1' }, { id: 'm-2' }, { id: 'm-3' }] } });
    render(<RelaySetup />);
    await detectAndAdvance();
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
    expect(screen.getByText('example.com · twoStep.stepOf({"current":2,"total":2})')).toBeTruthy();
    const group = screen.getByTestId('relay-setup-group');
    expect(within(group).getByRole('button', { name: /catalogGroupOther/ }).getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('checkbox', { name: 'm-1' })).toBeNull();
    fireEvent.click(within(group).getByTestId('relay_setup_models_select_group_button'));
    expect(rowCheckbox('m-1').checked && rowCheckbox('m-2').checked && rowCheckbox('m-3').checked).toBe(true);
    expect(within(group).getByText('twoStep.groupSelected({"count":3})')).toBeTruthy();
    expect((within(group).getByTestId('relay_setup_models_select_group_button') as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('button', { name: 'twoStep.saveSelected({"count":3})' })).toBeTruthy();
    // After collapsing the user wins; a search hit still follows the user collapse.
    fireEvent.click(within(group).getByRole('button', { name: /catalogGroupOther/ }));
    expect(screen.queryByRole('checkbox', { name: 'm-1' })).toBeNull();
    fireEvent.click(within(group).getByRole('button', { name: /catalogGroupOther/ }));
    fireEvent.click(rowCheckbox('m-2'));
    fireEvent.change(screen.getByLabelText('twoStep.searchModels({"count":3})'), { target: { value: 'm-3' } });
    await waitFor(() => expect(screen.queryByRole('checkbox', { name: 'm-1' })).toBeNull());
    expect(rowCheckbox('m-3')).toBeTruthy();
  });
});

describe('BOARD-SETUPMODELS-02 key chip only with 2 or more keys and only on selected rows', () => {
  it('BOARD-SETUPMODELS-02 two keys: catalogs fetched per key and merged, selected rows show the RK-2 binding (name, or mask when there is no name), unselected rows show none', async () => {
    const log = installFakeRelay({
      catalogs: {
        'sk-a': [{ id: 'claude-sonnet-4-5' }, { id: 'gpt-5.4' }],
        'sk-bbbbbbbbbbbb': [{ id: 'gpt-5.4' }, { id: 'gemini-2.5-pro' }],
      },
    });
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-bbbbbbbbbbbb' } });
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[0]!, { target: { value: 'Main' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
    // Each of the two keys fetches the catalog once; the extra key goes through catalogAPIRoot + /models.
    expect(log.gets).toEqual(['sk-a https://relay.example.com/v1/models', 'sk-bbbbbbbbbbbb https://relay.example.com/v1/models']);
    expect(screen.getByText('example.com · twoStep.keyCount({"count":2}) · twoStep.stepOf({"current":2,"total":2})')).toBeTruthy();
    selectAllGroups();
    fireEvent.click(rowCheckbox('gpt-5.4'));
    const chip = (modelID: string) => rowCheckbox(modelID).closest('[data-model-row]')?.querySelector('[data-testid="relay-setup-key-chip"]')?.textContent ?? null;
    expect(chip('claude-sonnet-4-5')).toBe('Main');
    expect(chip('gemini-2.5-pro')).toBe(formatApiKeyPreview('sk-bbbbbbbbbbbb'));
    // After grouping by family gpt-5.4 sits alone in a group, and that group collapses once deselected: expand first, then look at the row.
    expandAllGroups();
    expect(chip('gpt-5.4')).toBeNull();
  });

  it('BOARD-SETUPMODELS-02 primary key succeeds, extra key 401: a non-empty merged catalog still enters step 2 automatically', async () => {
    installFakeRelay({ catalogs: { 'sk-a': [{ id: 'gpt-5.4' }], 'sk-bad': 401 } });
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-bad' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
  });

  it('BOARD-SETUPMODELS-02 one key: no key chip', async () => {
    installFakeRelay({ catalogs: { 'sk-a': [{ id: 'gpt-5.4' }] } });
    render(<RelaySetup />);
    await detectAndAdvance();
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    selectAllGroups();
    expect(rowCheckbox('gpt-5.4').checked).toBe(true);
    expect(screen.queryByTestId('relay-setup-key-chip')).toBeNull();
  });
});

describe('BOARD-SETUPMODELS-03 save: verify only the first selected, one generation request, enable all selected, providers goes to detail + hint', () => {
  it('BOARD-SETUPMODELS-03 first = first in display order (not click order), only 1 generation request is sent, all selected are enabled, no other probes', async () => {
    markRelayHandoff({ entryPoint: 'providers' });
    const log = installFakeRelay({
      catalogs: {
        'sk-a': [
          { id: 'claude-sonnet-4-5', supported_endpoint_types: ['anthropic', 'openai'] },
          { id: 'gpt-4o-mini', supported_endpoint_types: ['openai'] },
          { id: 'o3-pro', supported_endpoint_types: ['openai-response'] },
        ],
      },
      pings: { 'claude-sonnet-4-5@messages': 200 },
    });
    render(<RelaySetup />);
    await detectAndAdvance();
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    expect(log.posts).toEqual([]);
    // Protocol chip = first candidate (computed locally, zero requests).
    expandAllGroups();
    const row = (modelID: string) => rowCheckbox(modelID).closest('[data-model-row]') as HTMLElement;
    expect(within(row('claude-sonnet-4-5')).getByText('Messages')).toBeTruthy();
    expect(within(row('o3-pro')).getByText('Responses')).toBeTruthy();
    fireEvent.click(rowCheckbox('o3-pro'));
    fireEvent.click(rowCheckbox('gpt-4o-mini'));
    fireEvent.click(rowCheckbox('claude-sonnet-4-5'));
    expect(screen.getByText('twoStep.saveNote')).toBeTruthy();
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(log.posts).toEqual(['sk-a claude-sonnet-4-5@messages']);
    expect(log.gets).toHaveLength(1);
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.models.map((item) => item.id)).toEqual(['claude-sonnet-4-5', 'gpt-4o-mini', 'o3-pro']);
    expect(saved.models.some((item) => item.isDefault)).toBe(false);
    expect(saved.status).toEqual({ kind: 'connected' });
    expect(saved.relayRequested?.transport).toBe('auto');
    expect(saved.relayRequested?.resolvedAPIBaseURLs).toEqual({ anthropic_messages: 'https://relay.example.com/v1' });
    expect(saved.models.find((item) => item.id === 'claude-sonnet-4-5')).toMatchObject({
      relayTransport: 'anthropic_messages', relayTransportSource: 'reachable',
    });
    expect(saved.models.find((item) => item.id === 'gpt-4o-mini')?.relayTransport).toBeUndefined();
    expect(saved.relayKeys).toBeUndefined();
    expect(mocks.setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'relay-provider-id', modelID: 'claude-sonnet-4-5' });
    await waitFor(() => expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id'));
    expect(takeProviderDetailNotice('relay-provider-id')).toEqual({ count: 3 });
    expect(takeProviderDetailNotice('relay-provider-id')).toBeNull();
  });

  it('BOARD-SETUPMODELS-03 two keys: the first selected is verified with the key it is bound to, the other keys are written per RK-2, and the primary key name is written too', async () => {
    const log = installFakeRelay({
      catalogs: { 'sk-a': [{ id: 'gpt-5.4' }], 'sk-bbbbbbbbbbbb': [{ id: 'gemini-2.5-pro', supported_endpoint_types: ['openai'] }] },
      pings: { 'gemini-2.5-pro@chat': 200 },
    });
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-bbbbbbbbbbbb' } });
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[0]!, { target: { value: 'Main' } });
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[1]!, { target: { value: 'Backup' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    expandAllGroups();
    fireEvent.click(rowCheckbox('gemini-2.5-pro'));
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(log.posts).toEqual(['sk-bbbbbbbbbbbb gemini-2.5-pro@chat']);
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.apiKey).toBe('sk-a');
    expect(saved.relayKeys?.map((key) => [key.name, key.apiKey])).toEqual([['Main', ''], ['Backup', 'sk-bbbbbbbbbbbb']]);
    const backupID = saved.relayKeys![1]!.id;
    expect(saved.models).toEqual([expect.objectContaining({ id: 'gemini-2.5-pro', relayKeyID: backupID })]);
    expect(saved.catalogModels.find((item) => item.id === 'gemini-2.5-pro')?.relayListedByKeyIDs).toEqual([backupID]);
    // Not the providers entry: no one-time hint is left.
    expect(takeProviderDetailNotice('relay-provider-id')).toBeNull();
  });

  it('BOARD-SETUPMODELS-03 detail page one-time hint: given only to the matching connection, shown once then cleared', () => {
    const empty = render(<ProviderDetailNoticeBanner providerID="relay-provider-id" />);
    expect(empty.queryByRole('status')).toBeNull();
    empty.unmount();
    setProviderDetailNotice('relay-provider-id', { count: 2 });
    const other = render(<ProviderDetailNoticeBanner providerID="another-id" />);
    expect(other.queryByRole('status')).toBeNull();
    other.unmount();
    const first = render(<ProviderDetailNoticeBanner providerID="relay-provider-id" />);
    expect(first.getByRole('status').textContent).toBe('twoStep.addedBanner({"count":2})');
    first.unmount();
    const second = render(<ProviderDetailNoticeBanner providerID="relay-provider-id" />);
    expect(second.queryByRole('status')).toBeNull();
  });
});

describe('BOARD-SETUPMODELS-03 save in flight can be canceled', () => {
  it('BOARD-SETUPMODELS-03 leaving the page while the save 1-token request is in flight: the request is aborted and nothing is persisted', async () => {
    const posts: AbortSignal[] = [];
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
      const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
      if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
      if (method === 'GET') {
        return new Response(JSON.stringify({ object: 'list', data: [{ id: 'gpt-5.4', supported_endpoint_types: ['openai'] }] }), {
          status: 200, headers: { 'content-type': 'application/json' },
        });
      }
      posts.push(init!.signal!);
      return new Promise<Response>((_, reject) => {
        init!.signal!.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      });
    }));
    const view = render(<RelaySetup />);
    await detectAndAdvance();
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    selectAllGroups();
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(posts).toHaveLength(1));
    expect(posts[0]!.aborted).toBe(false);
    view.unmount();
    expect(posts[0]!.aborted).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });
});

describe('BOARD-SETUPMODELS-04 catalog failure -> manual add, 0 items cannot be saved', () => {
  it('BOARD-SETUPMODELS-04 403: one sentence on step 1, clicking Next again enters the step 2 empty state; manually added is selected immediately and can be saved', async () => {
    installFakeRelay({ catalogs: { 'sk-a': 403 }, pings: { 'my-model@chat': 200 } });
    render(<RelaySetup />);
    await detectAndAdvance();
    expect(await screen.findByText('twoStep.failPermission')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    expect(screen.getByText('twoStep.modelsEmpty')).toBeTruthy();
    expect((screen.getByTestId('relay_setup_models_save_button') as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
    fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: ' my-model ' } });
    expect(screen.getByTestId('relay_setup_models_add_manual_confirm_button')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'add' }));
    expect(rowCheckbox('my-model').checked).toBe(true);
    expect(rowCheckbox('my-model').getAttribute('data-testid')).toBe('relay_setup_models_row_toggle');
    expect((screen.getByTestId('relay_setup_models_save_button') as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).models.map((item) => item.id)).toEqual(['my-model']);
  });
});

describe('BOARD-SETUPMODELS-05 verification failure is not persisted', () => {
  it('BOARD-SETUPMODELS-05 all candidates of the first selected fail: stay on step 2 showing the failure card, addProvider is not called, no navigation', async () => {
    const log = installFakeRelay({
      catalogs: { 'sk-a': [{ id: 'o3-pro', supported_endpoint_types: ['openai-response'] }] },
      pings: { 'o3-pro@responses': 502 },
    });
    render(<RelaySetup />);
    await detectAndAdvance();
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    selectAllGroups();
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    // The failure card no longer carries a "detection failed" title (pending mapping cleanup); judge by the failure-state result card.
    await waitFor(() => expect(document.querySelector('[role="status"][data-state="error"]')).toBeTruthy());
    expect(log.posts).toEqual(['sk-a o3-pro@responses']);
    expect(mocks.addProvider).not.toHaveBeenCalled();
    expect(mocks.routerPush).not.toHaveBeenCalled();
    expect(screen.getByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
  });
});

// MARK: - Step 2 manually add model ID (BOARD-SETUPMODELS-06 to 12)

async function openStepTwo(catalog: string[], pings: Record<string, number> = {}) {
  markRelayHandoff({ entryPoint: 'providers' });
  const log = installFakeRelay({ catalogs: { 'sk-a': catalog.map((id) => ({ id })) }, pings });
  render(<RelaySetup />);
  await detectAndAdvance();
  await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
  return log;
}

function addManual(modelID: string) {
  fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
  fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: modelID } });
  fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_confirm_button'));
}

function hint(): HTMLElement | null {
  return screen.queryByTestId('relay_setup_models_add_manual_hint');
}

function rowIDs(): string[] {
  expandAllGroups();
  return [...document.querySelectorAll('[data-model-row]')].map((node) => node.getAttribute('data-model-row')!);
}

describe('BOARD-SETUPMODELS-06 empty string cannot be added', () => {
  it('BOARD-SETUPMODELS-06 empty / whitespace only: ignored, Add disabled', async () => {
    expect(relayStepTwoAddManual({ catalogModels: [], manualIDs: [] }, '   ')).toEqual({ kind: 'ignored' });
    await openStepTwo(['gpt-4o']);
    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
    const confirm = screen.getByTestId('relay_setup_models_add_manual_confirm_button') as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: '   ' } });
    expect(confirm.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: ' x ' } });
    expect(confirm.disabled).toBe(false);
  });
});

describe('BOARD-SETUPMODELS-07 duplicate of the catalog', () => {
  it('BOARD-SETUPMODELS-07 compared after trim: nothing added, the catalog item is selected, a hint appears; the hint disappears on the next add / toggling selection / select group / reopening add', async () => {
    const catalog = [model('gpt-4o')];
    expect(relayStepTwoAddManual({ catalogModels: catalog, manualIDs: [] }, ' gpt-4o ')).toEqual({ kind: 'existing', modelID: 'gpt-4o' });
    await openStepTwo(['gpt-4o', 'o3']);
    addManual(' gpt-4o ');
    expect(rowIDs()).toEqual(['gpt-4o', 'o3']);
    expect(rowCheckbox('gpt-4o').checked).toBe(true);
    expect(hint()?.textContent).toBe('twoStep.alreadyInList');
    // The hint is under the button.
    const button = screen.getByTestId('relay_setup_models_add_manual_button');
    expect(Boolean(button.compareDocumentPosition(hint()!) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
    // Toggling selection -> disappears.
    fireEvent.click(rowCheckbox('o3'));
    expect(hint()).toBeNull();
    addManual('gpt-4o');
    expect(hint()).toBeTruthy();
    // Reopening add -> disappears.
    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
    expect(hint()).toBeNull();
    fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: 'gpt-4o' } });
    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_confirm_button'));
    expect(hint()).toBeTruthy();
    fireEvent.click(rowCheckbox('o3'));
    expect(rowCheckbox('o3').checked).toBe(false);
    addManual('gpt-4o');
    expect(hint()).toBeTruthy();
    // Select group -> disappears.
    const groupButtons = screen.getAllByTestId('relay_setup_models_select_group_button') as HTMLButtonElement[];
    fireEvent.click(groupButtons.find((item) => !item.disabled)!);
    expect(hint()).toBeNull();
    addManual('gpt-4o');
    expect(hint()).toBeTruthy();
    // Next successful add -> disappears.
    addManual('my-new-model');
    expect(hint()).toBeNull();
    expect(rowCheckbox('my-new-model').checked).toBe(true);
  });
});

describe('BOARD-SETUPMODELS-08 duplicate of an already manually added one', () => {
  it('BOARD-SETUPMODELS-08 nothing added, re-selected, manual list length unchanged, a hint appears', async () => {
    expect(relayStepTwoAddManual({ catalogModels: [], manualIDs: ['my-model'] }, 'my-model')).toEqual({ kind: 'existing', modelID: 'my-model' });
    await openStepTwo(['gpt-4o']);
    addManual('my-model');
    expect(hint()).toBeNull();
    fireEvent.click(rowCheckbox('my-model'));
    // After deselecting, the group collapses (no selected items inside): expand first, then look at the row.
    expandAllGroups();
    expect(rowCheckbox('my-model').checked).toBe(false);
    addManual(' my-model ');
    expect(rowIDs().filter((id) => id === 'my-model')).toHaveLength(1);
    expect(rowCheckbox('my-model').checked).toBe(true);
    expect(hint()).toBeTruthy();
  });
});

describe('BOARD-SETUPMODELS-09 differs only by case', () => {
  it('BOARD-SETUPMODELS-09 counts as the same one: selects the spelling of the existing item, save enables only that one, hint count = number actually enabled', async () => {
    expect(relayStepTwoAddManual({ catalogModels: [model('gpt-4o')], manualIDs: [] }, 'GPT-4O')).toEqual({ kind: 'existing', modelID: 'gpt-4o' });
    await openStepTwo(['gpt-4o'], { 'gpt-4o@chat': 200 });
    addManual('GPT-4O');
    expect(rowIDs()).toEqual(['gpt-4o']);
    expect(rowCheckbox('gpt-4o').checked).toBe(true);
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).models.map((item) => item.id)).toEqual(['gpt-4o']);
    expect(takeProviderDetailNotice('relay-provider-id')).toEqual({ count: 1 });
  });
});

describe('BOARD-SETUPMODELS-10 a dated snapshot is a different model', () => {
  it('BOARD-SETUPMODELS-10 catalog gpt-4o + manually added gpt-4o-2024-08-06 -> a new row; the case variant lands on this row; both are stored, hint 2, only 1 generation request is sent', async () => {
    expect(relayStepTwoAddManual({ catalogModels: [model('gpt-4o')], manualIDs: [] }, 'gpt-4o-2024-08-06'))
      .toEqual({ kind: 'added', modelID: 'gpt-4o-2024-08-06' });
    expect(relayStepTwoAddManual({ catalogModels: [model('gpt-4o')], manualIDs: ['gpt-4o-2024-08-06'] }, 'GPT-4O-2024-08-06'))
      .toEqual({ kind: 'existing', modelID: 'gpt-4o-2024-08-06' });
    expect(relayStepTwoAddManual({ catalogModels: [model('gpt-4o-2024-08-06')], manualIDs: [] }, 'gpt-4o'))
      .toEqual({ kind: 'added', modelID: 'gpt-4o' });
    // The grouping projection does not collapse by date.
    const groups = relayStepTwoGroups({
      catalogModels: relayStepTwoCatalog([model('gpt-4o')], ['gpt-4o-2024-08-06']), host: 'example.com', query: '', otherTitle: 'OTHER',
    });
    expect(groups.flatMap((group) => group.models.map((item) => item.id)).sort()).toEqual(['gpt-4o', 'gpt-4o-2024-08-06']);

    const log = await openStepTwo(['gpt-4o'], { 'gpt-4o@chat': 200 });
    addManual('gpt-4o-2024-08-06');
    expect(hint()).toBeNull();
    addManual('GPT-4O-2024-08-06');
    expect(hint()).toBeTruthy();
    expect(rowIDs().sort()).toEqual(['gpt-4o', 'gpt-4o-2024-08-06']);
    fireEvent.click(rowCheckbox('gpt-4o'));
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).models.map((item) => item.id).sort()).toEqual(['gpt-4o', 'gpt-4o-2024-08-06']);
    expect(takeProviderDetailNotice('relay-provider-id')).toEqual({ count: 2 });
    expect(log.posts).toHaveLength(1);
  });
});

describe('BOARD-SETUPMODELS-11 hint reports the number actually enabled', () => {
  it('BOARD-SETUPMODELS-11 catalog lists two IDs differing only by case and both are selected: the enable path treats them as one, hint = number actually enabled', async () => {
    expect(relayStepTwoEnabledSelection([model('GPT-4o'), model('gpt-4o'), model('o3')]).map((item) => item.id)).toEqual(['GPT-4o', 'o3']);
    await openStepTwo(['GPT-4o', 'gpt-4o'], { 'GPT-4o@chat': 200 });
    selectAllGroups();
    expect(screen.getByRole('button', { name: 'twoStep.saveSelected({"count":2})' })).toBeTruthy();
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.models).toHaveLength(1);
    expect(takeProviderDetailNotice('relay-provider-id')).toEqual({ count: saved.models.length });
  });
});

describe('BOARD-SETUPMODELS-12 two different dated snapshots', () => {
  it('BOARD-SETUPMODELS-12 catalog ...-20240620, manually add ...-20241022 -> a new row, both are persisted after save', async () => {
    await openStepTwo(['claude-3-5-sonnet-20240620'], { 'claude-3-5-sonnet-20240620@messages': 200, 'claude-3-5-sonnet-20240620@chat': 200 });
    addManual('claude-3-5-sonnet-20241022');
    expect(rowIDs().sort()).toEqual(['claude-3-5-sonnet-20240620', 'claude-3-5-sonnet-20241022']);
    fireEvent.click(rowCheckbox('claude-3-5-sonnet-20240620'));
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).models.map((item) => item.id).sort())
      .toEqual(['claude-3-5-sonnet-20240620', 'claude-3-5-sonnet-20241022']);
  });
});
