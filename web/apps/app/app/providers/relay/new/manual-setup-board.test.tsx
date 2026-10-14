import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider, RelayTransport } from '@oriveo/shared';
import type { RelayFormIssue } from '@oriveo/core/providers/relay-form-validation';
import { PROVIDER_VALIDATION_MESSAGES } from '../../../../lib/core/providers/validation-messages';
import { markRelayHandoff } from '../../new/relay-handoff';
import { relayEditBoard, relayEditDraftFromProvider, relayRevealsFailureCard } from '../../[providerId]/relay-edit-board';
import { ProviderDetailNoticeBanner, setProviderDetailNotice, takeProviderDetailNotice } from '../../[providerId]/provider-detail-notice';
import { RelaySetup } from './RelaySetup';
import {
  MANUAL_SETUP_TEXT,
  initialManualSetupDraft,
  manualSetupBoard,
  manualSetupEffectiveRelayKind,
  quickSetupButtonFit,
  type ManualSetupBoardInput,
} from './manual-setup-board';

/**
 * Manual setup board (cases BOARD-MANUAL-01 to 12):
 * asserts the output of manualSetupBoard, and what the production page renders from it through the production verification and persistence paths.
 */

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  addProvider: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
  setLastUsedModelRef: vi.fn(),
  trackEvent: vi.fn(),
  storeProviders: [] as unknown[],
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

vi.mock('../../../../lib/core/sync', () => ({ getSyncAdapter: () => undefined }));

/** After persistence, the non-blocking catalog refresh goes through production refreshRelayCatalogInStore: the store only needs providers and updateProvider. */
const fakeStore = {
  getState: () => ({
    providers: mocks.storeProviders,
    updateProvider: (id: string, patch: Partial<Provider>) => {
      mocks.storeProviders = mocks.storeProviders.map((item) => (
        (item as Provider).id === id ? { ...(item as Provider), ...patch } : item
      ));
    },
  }),
};

vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => fakeStore,
  useAppStore: (selector: (state: unknown) => unknown) => selector({
    providers: [],
    setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    setLastUsedModelRef: mocks.setLastUsedModelRef,
  }),
}));

vi.mock('../../../../lib/core/provider-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/core/provider-ops')>()),
  addProvider: (...args: unknown[]) => mocks.addProvider(...args),
}));

/** Vendor family (by-model view): claude-* belongs to anthropic, the rest cannot be found (candidates try only Chat). */
vi.mock('../../../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/core/metadata/metadata-client')>()),
  lookupModelFamilyByModel: async (modelID: string) => (modelID.startsWith('claude') ? 'anthropic' : undefined),
}));

vi.mock('../../../../lib/core/telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/core/telemetry')>()),
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
}));

vi.mock('../../../../lib/utils/id-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/utils/id-utils')>()),
  createCanonicalUUID: () => 'relay-provider-id',
}));

vi.mock('@oriveo/ui', () => ({
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

type Transport = 'chat' | 'responses' | 'messages' | 'gemini';

interface FakeRelay {
  /** `<model>@<protocol>` -> HTTP status; unlisted ones are 404. */
  pings?: Record<string, number>;
  /** Failure response body (by default one upstream sentence). */
  errorBody?: string;
  catalog?: string[];
  /** Generation request hangs: released manually by the test. */
  hold?: boolean;
}

interface Pending {
  resolve: (status: number) => void;
  signal?: AbortSignal | null;
}

/** Fake relay: GET .../models returns the catalog; POST = 1-token generation request, answered per the ping table. */
function installFakeRelay(relay: FakeRelay = {}) {
  const log = { gets: [] as string[], posts: [] as string[], pending: [] as Pending[] };
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
    const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
    if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
    const proxy = JSON.parse(headers.get('x-relay-proxy-config') ?? '{}') as { apiKey?: string };
    const apiKey = proxy.apiKey ?? headers.get('authorization')?.replace(/^Bearer /, '') ?? headers.get('x-api-key') ?? '';
    if (method === 'GET' && url.endsWith('/models')) {
      log.gets.push(`${apiKey} ${url}`);
      return new Response(JSON.stringify({ object: 'list', data: (relay.catalog ?? []).map((id) => ({ id, object: 'model' })) }), {
        status: 200, headers: { 'content-type': 'application/json' },
      });
    }
    const body = JSON.parse(String(init?.body ?? '{}')) as { model?: string };
    const gemini = /\/models\/([^/:]+):generateContent/.exec(url);
    const transport: Transport = gemini ? 'gemini' : url.includes('/messages') ? 'messages' : url.includes('/responses') ? 'responses' : 'chat';
    const modelID = gemini ? decodeURIComponent(gemini[1]!) : body.model;
    log.posts.push(`${apiKey} ${modelID}@${transport}`);
    const respond = (status: number) => (status === 200
      ? new Response('{"id":"ok","choices":[{"message":{"content":"ok"}}]}', { status: 200, headers: { 'content-type': 'application/json' } })
      : new Response(relay.errorBody ?? '{"error":{"message":"upstream said no"}}', { status, headers: { 'content-type': 'application/json' } }));
    if (relay.hold) {
      return new Promise<Response>((resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        log.pending.push({ resolve: (status) => resolve(respond(status)), signal: init?.signal });
      });
    }
    return respond(relay.pings?.[`${modelID}@${transport}`] ?? 404);
  }));
  return log;
}

function openManual() {
  const view = render(<RelaySetup />);
  fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
  return view;
}

function fillManual(input: { endpoint?: string; key?: string; model?: string } = {}) {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: input.endpoint ?? 'https://relay.example.com' } });
  fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: input.key ?? 'sk-a' } });
  if (input.model !== undefined || !('model' in input)) {
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: input.model ?? 'gpt-5.4' } });
  }
}

function primary(): HTMLButtonElement {
  return screen.getByTestId('relay_manual_setup_primary_button') as HTMLButtonElement;
}

function chooseProtocol(transport: string) {
  fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol'), { target: { value: transport } });
}

function openAdvanced() {
  const toggle = screen.getByRole('button', { name: new RegExp(MANUAL_SETUP_TEXT.advanced) });
  if (toggle.getAttribute('aria-expanded') === 'false') fireEvent.click(toggle);
}

function addEntry(kind: 'pages.relayDetail.headers' | 'pages.relayDetail.queryParams') {
  fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.editBoard.add' }));
  fireEvent.click(screen.getByRole('menuitem', { name: kind }));
}

function failureCard(): HTMLElement | null {
  return screen.queryByTestId('relay-manual-failure');
}

function boardInput(patch: Partial<ManualSetupBoardInput> = {}): ManualSetupBoardInput {
  return {
    endpoint: 'https://relay.example.com',
    keys: [{ id: 'implicit', apiKey: 'sk-a', name: '' }],
    draft: { ...initialManualSetupDraft(), model: 'gpt-5.4' },
    issues: [],
    normalizedEndpoint: 'https://relay.example.com',
    flagshipModelID: 'gpt-5.6-sol',
    phase: { kind: 'idle' },
    advancedChoice: undefined,
    ...patch,
  };
}

function relayProvider(transport: RelayTransport): Provider {
  return {
    id: 'relay-edit', kind: 'relay', customName: 'Work relay', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-a', apiKeyPreview: '••', baseURLText: 'https://relay.example.com', relayKind: 'custom',
    relayRequested: { transport, authMode: 'auto', securityMode: 'remote_https' },
  };
}

beforeEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  mocks.routerPush.mockReset();
  mocks.addProvider.mockReset();
  mocks.setHasCompletedOnboarding.mockReset();
  mocks.setLastUsedModelRef.mockReset();
  mocks.trackEvent.mockReset();
  mocks.storeProviders = [];
  mocks.addProvider.mockImplementation(async (_store: unknown, provider: Provider) => {
    mocks.storeProviders = [...mocks.storeProviders, provider];
    return true;
  });
  sessionStorage.clear();
  window.history.replaceState({}, '', '/providers/relay/new');
  takeProviderDetailNotice('relay-provider-id');
});

describe('BOARD-MANUAL-01 block order and Hero', () => {
  it('BOARD-MANUAL-01 board: block order, Hero copy, row-end labels, model / connection name placeholders and footnotes, no step counter and no test connection', () => {
    const board = manualSetupBoard(boardInput());
    expect(board.sections).toEqual(['requestURL', 'apiKeys', 'model', 'connectionName', 'protocol', 'advanced']);
    expect(board.hero).toEqual({
      icon: 'hard-drives',
      labelKey: 'pages.relaySetup.heroLabel',
      titleKey: 'pages.relaySetup.heroTitle',
      subtitleKey: 'pages.relaySetup.manual.heroSubtitle',
      trailingKey: 'pages.relaySetup.manualSetup',
    });
    expect(board.leadingAction).toEqual({ titleKey: 'pages.relaySetup.manual.useQuickSetup' });
    expect(board.requestURL).toMatchObject({ titleKey: 'pages.relaySetup.requestURLLabel', icon: 'link', preview: 'https://relay.example.com/v1/…' });
    expect(board.apiKeys.showsNames).toBe(false);
    expect(manualSetupBoard(boardInput({
      keys: [{ id: 'implicit', apiKey: 'sk-a', name: '' }, { id: 'k2', apiKey: '', name: '' }],
    })).apiKeys.showsNames).toBe(true);
    expect(board.model).toEqual({
      titleKey: 'pages.relaySetup.defaultModelLabel',
      icon: 'squares-four',
      placeholder: 'gpt-5.6-sol',
      footnoteKey: 'pages.relaySetup.manual.modelFootnote',
    });
    expect(board.connectionName).toEqual({
      titleKey: 'pages.relaySetup.manual.connectionName',
      icon: 'pencil-simple',
      slotLabelKey: 'pages.relaySetup.twoStep.keyName',
      placeholder: 'example.com',
      footnoteKey: 'pages.relaySetup.manual.connectionNameFootnote',
    });
    expect(board.protocolGroup).toMatchObject({ titleKey: 'pages.relaySetup.transport', collapsible: false, expanded: true });
    expect(board.protocolGroup.rows.map((row) => row.id)).toEqual(['defaultProtocol']);
    expect(board.advancedGroup).toMatchObject({ titleKey: 'pages.relaySetup.manual.advancedGroup', collapsible: true, expanded: false });
    expect(board.advancedGroup.rows.map((row) => row.id)).toEqual(['authentication', 'userAgent', 'addEntry']);
    // The auth method row on the manual page carries no "keys are managed on the detail page" footnote.
    expect(board.advancedGroup.rows[0]).toMatchObject({ titleKey: 'pages.relayDetail.authMode', icon: 'key' });
    expect(board.advancedGroup.rows[0]!.footnote).toBeUndefined();
    const withEntries = manualSetupBoard(boardInput({
      draft: { ...initialManualSetupDraft(), headers: [{ key: 'X-A', value: '1' }], queryParams: [{ key: 'q', value: '2' }] },
    }));
    expect(withEntries.advancedGroup.rows.map((row) => [row.id, row.titleKey, row.masked ?? false])).toEqual([
      ['authentication', 'pages.relayDetail.authMode', false],
      ['userAgent', 'pages.relayDetail.editBoard.userAgent', false],
      ['header', 'pages.relayDetail.headers', true],
      ['queryParam', 'pages.relayDetail.queryParams', false],
      ['addEntry', 'pages.relayDetail.editBoard.add', false],
    ]);
    expect(board.failure).toBeNull();
  });

  it('BOARD-MANUAL-01 page: renders per the board, the top left has only the "Use quick setup" text button, no step counter / kind cards / test connection / streaming rows', () => {
    openManual();
    const root = screen.getByTestId('relay-manual-setup');
    const sections = [...root.querySelectorAll('[data-manual-section]')].map((node) => node.getAttribute('data-manual-section'));
    expect(sections).toEqual(['requestURL', 'apiKeys', 'model', 'connectionName', 'protocol', 'advanced']);
    expect(screen.getByRole('heading', { name: 'pages.relaySetup.heroTitle' })).toBeTruthy();
    expect(screen.getByText('pages.relaySetup.heroLabel')).toBeTruthy();
    expect(screen.getByText('pages.relaySetup.manualSetup')).toBeTruthy();
    expect(screen.getByText('pages.relaySetup.manual.heroSubtitle')).toBeTruthy();
    const quick = screen.getByRole('button', { name: 'pages.relaySetup.manual.useQuickSetup' });
    expect(quick.querySelector('svg')).toBeNull();
    expect(screen.queryByRole('button', { name: 'back' })).toBeNull();
    expect(screen.queryByText(/twoStep\.stepOf/)).toBeNull();
    expect(screen.queryByText(/kind\./)).toBeNull();
    expect(screen.queryByText('pages.relayDetail.testRelay')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.editBoard.stream')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.serviceTier')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.disableResponseStorage')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.connectionType')).toBeNull();
    expect(screen.getByLabelText(MANUAL_SETUP_TEXT.model).getAttribute('placeholder')).toBe('gpt-5.6-sol');
    expect(screen.getByText('pages.relaySetup.manual.modelFootnote')).toBeTruthy();
    // The title row icon of the model / connection name block is drawn the same way as the address block link (16 size inside the label, hidden from screen readers).
    expect(document.querySelector('label[for="relay-manual-model"] svg[data-field-icon="squares-four"]')?.getAttribute('aria-hidden')).toBe('true');
    expect(document.querySelector('label[for="relay-manual-name"] svg[data-field-icon="pencil-simple"]')?.getAttribute('aria-hidden')).toBe('true');
    expect(document.querySelector('label[for="relay-request-url"] svg')?.getAttribute('width')).toBe('16');
    expect(screen.getByText('pages.relaySetup.manual.connectionNameFootnote')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'api.myrelay.dev' } });
    expect(screen.getByTestId('relay-setup-will-request').textContent).toBe('twoStep.willRequest({"url":"https://api.myrelay.dev/v1/…"})');
    expect(screen.getByLabelText(MANUAL_SETUP_TEXT.connectionName).getAttribute('placeholder')).toBe('myrelay.dev');
    // Multiple keys use the same slots as step 1.
    expect(screen.queryAllByLabelText('twoStep.keyName')).toHaveLength(0);
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    expect(screen.getAllByLabelText('twoStep.keyName')).toHaveLength(2);
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAndSave);
  });

  it('BOARD-MANUAL-01 new copy is complete in all 16 languages', () => {
    const dir = join(process.cwd(), 'messages');
    const keys = [
      'pages.relaySetup.manual.heroSubtitle', 'pages.relaySetup.manual.useQuickSetup', 'pages.relaySetup.manual.modelFootnote',
      'pages.relaySetup.manual.connectionName', 'pages.relaySetup.manual.connectionNameFootnote', 'pages.relaySetup.manual.advancedGroup',
      'pages.relaySetup.manual.notSet', 'pages.relaySetup.manual.validateAgain', 'pages.relaySetup.manual.notSaved',
      'pages.relaySetup.twoStep.alreadyInList',
    ];
    const files = readdirSync(dir).filter((name) => name.endsWith('.json'));
    expect(files).toHaveLength(16);
    const missing = files.flatMap((file) => {
      const messages = JSON.parse(readFileSync(join(dir, file), 'utf8')) as Record<string, unknown>;
      return keys.filter((key) => {
        const value = key.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], messages);
        return typeof value !== 'string' || value.trim() === '';
      }).map((key) => `${file}:${key}`);
    });
    expect(missing).toEqual([]);
  });
});

describe('BOARD-MANUAL-02 default protocol row', () => {
  it('BOARD-MANUAL-02 initial value auto; candidate set, icon, row color and footnote share the same row value as Edit Connection', () => {
    expect(initialManualSetupDraft()).toMatchObject({ transport: 'auto', authMode: 'auto' });
    for (const transport of ['auto', 'openai_responses', 'anthropic_messages'] as const) {
      const manual = manualSetupBoard(boardInput({ draft: { ...initialManualSetupDraft(), transport } })).protocolGroup.rows[0]!;
      const provider = relayProvider(transport);
      const edit = relayEditBoard({
        provider, displayName: 'Work relay', draft: relayEditDraftFromProvider(provider), status: null, isSaving: false,
        issues: [], normalizedEndpoint: provider.baseURLText!, shownCompatRows: new Set(), groupChoice: {},
      }).groups.find((group) => group.id === 'protocolAuth')!.rows.find((row) => row.id === 'defaultProtocol')!;
      expect(manual).toEqual(edit);
      expect(manual).toMatchObject({ icon: 'hard-drives', colorToken: '--o-row-indigo' });
    }
  });
});

describe('BOARD-MANUAL-03 collapsible group summary', () => {
  it('BOARD-MANUAL-03 current auth value · filled count (UA + headers with a name + query params with a name)', () => {
    const trailing = (draft: Partial<ReturnType<typeof initialManualSetupDraft>>) => manualSetupBoard(boardInput({
      draft: { ...initialManualSetupDraft(), ...draft },
    })).advancedGroup.trailingParts;
    expect(trailing({})).toEqual([{ key: 'pages.relayDetail.protocolAuto' }, { key: 'pages.relaySetup.manual.notSet' }]);
    const two = { authMode: 'bearer' as const, customUserAgent: 'Agent/1', headers: [{ key: 'X-Token', value: 'v' }, { key: ' ', value: 'w' }] };
    expect(trailing(two)).toEqual([{ literal: 'Bearer' }, { key: 'pages.relayDetail.editBoard.setCount', values: { count: 2 } }]);
    expect(trailing({ ...two, queryParams: [{ key: 'region', value: 'us' }] })![1]).toEqual({
      key: 'pages.relayDetail.editBoard.setCount', values: { count: 3 },
    });
  });
});

describe('BOARD-MANUAL-04 primary button', () => {
  it('BOARD-MANUAL-04 not tappable -> tappable -> verifying (spinner, not tappable) -> "Re-verify" after failure', () => {
    const empty = manualSetupBoard(boardInput({ endpoint: '', keys: [{ id: 'implicit', apiKey: '', name: '' }], draft: initialManualSetupDraft(), issues: [{ field: 'endpoint', code: 'endpoint_required' }], normalizedEndpoint: null }));
    expect(empty.primary).toEqual({ titleKey: MANUAL_SETUP_TEXT.validateAndSave, enabled: false, spinning: false });
    expect(manualSetupBoard(boardInput({ draft: { ...initialManualSetupDraft(), model: '   ' } })).primary.enabled).toBe(false);
    expect(manualSetupBoard(boardInput()).primary).toEqual({ titleKey: MANUAL_SETUP_TEXT.validateAndSave, enabled: true, spinning: false });
    expect(manualSetupBoard(boardInput({ issues: [{ field: 'endpoint', code: 'endpoint_rejected' }] })).primary.enabled).toBe(false);
    expect(manualSetupBoard(boardInput({ phase: { kind: 'validating' } })).primary).toEqual({ titleKey: MANUAL_SETUP_TEXT.validateAndSave, enabled: false, spinning: true });
    expect(manualSetupBoard(boardInput({ phase: { kind: 'failed', failureID: 1 } })).primary).toEqual({ titleKey: MANUAL_SETUP_TEXT.validateAgain, enabled: true, spinning: false });
    expect(manualSetupBoard(boardInput({ phase: { kind: 'saved' } })).primary.enabled).toBe(false);
  });

  it('BOARD-MANUAL-04 page: a public http address is not tappable and tapping sends no request; while verifying the spinner is inside the primary button, in the same color as the button text', async () => {
    const log = installFakeRelay({ hold: true });
    openManual();
    fillManual({ endpoint: 'http://relay.example.com', model: 'gpt-5.4' });
    expect(primary().disabled).toBe(true);
    fireEvent.click(primary());
    expect(log.posts).toEqual([]);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: '  ' } });
    expect(primary().disabled).toBe(true);
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.4' } });
    expect(primary().disabled).toBe(false);
    fireEvent.click(primary());
    await waitFor(() => expect(log.posts).toHaveLength(1));
    expect(primary().disabled).toBe(true);
    expect(primary().querySelector('[data-spinner]')?.getAttribute('class')).toContain('spinner');
  });
});

describe('BOARD-MANUAL-05 verification failure is not persisted', () => {
  it('BOARD-MANUAL-05 sends 1 request with the primary key only; no persistence and no navigation; failure card = reason + "not saved yet" + technical details + Save anyway; contains no key / header value / query param value / UA', async () => {
    const secrets = ['sk-primary-0123456789', 'sk-second-9876543210', 'hdr-secret-value', 'qp-secret-value', 'Agent-Secret/9.9'];
    const log = installFakeRelay({
      pings: {},
      errorBody: JSON.stringify({ error: { message: `denied ${secrets.join(' ')}` } }),
    });
    openManual();
    fillManual({ key: secrets[0] });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: secrets[1] } });
    chooseProtocol('openai_chat_completions');
    openAdvanced();
    fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.userAgent'), { target: { value: secrets[4] } });
    addEntry('pages.relayDetail.headers');
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1'), { target: { value: 'X-Region' } });
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1 pages.relayDetail.valuePlaceholder'), { target: { value: secrets[2] } });
    addEntry('pages.relayDetail.queryParams');
    fireEvent.change(screen.getByLabelText('pages.relayDetail.queryParams 1'), { target: { value: 'region' } });
    fireEvent.change(screen.getByLabelText('pages.relayDetail.queryParams 1 pages.relayDetail.valuePlaceholder'), { target: { value: secrets[3] } });
    fireEvent.click(primary());

    await waitFor(() => expect(failureCard()).toBeTruthy());
    expect(log.posts).toEqual([`${secrets[0]} gpt-5.4@chat`]);
    expect(mocks.addProvider).not.toHaveBeenCalled();
    expect(mocks.routerPush).not.toHaveBeenCalled();
    expect(takeProviderDetailNotice('relay-provider-id')).toBeNull();
    const card = failureCard()!;
    expect(card.querySelector('[data-failure-note]')?.textContent).toBe(MANUAL_SETUP_TEXT.notSaved);
    expect(within(card).getByText('attemptedRequests')).toBeTruthy();
    expect(within(card).getByRole('button', { name: 'saveUnverified' })).toBeTruthy();
    for (const secret of secrets) expect(card.textContent).not.toContain(secret);
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAgain);
    expect(primary().disabled).toBe(false);
  });
});

describe('BOARD-MANUAL-06 Save anyway (unverified)', () => {
  it('BOARD-MANUAL-06 sends no more requests; persists with a stable unverified status (normalized address, model enabled, relayKind derived from the protocol, connection-level modelID empty); detail page notice = unverified + reason; completion latch', async () => {
    markRelayHandoff({ entryPoint: 'providers' });
    const log = installFakeRelay({ pings: {} });
    openManual();
    fillManual({ endpoint: 'relay.example.com', model: 'gpt-5.4' });
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    // Input without a scheme is normalized and written back before verification (the scheme goes into the chip, the slot shows only the part after it).
    expect((screen.getByLabelText('requestURLLabel') as HTMLInputElement).value).toBe('relay.example.com');
    expect(screen.getByTestId('relay-endpoint-scheme').textContent).toBe('https');
    const posts = log.posts.length;
    const saveAnyway = within(failureCard()!).getByRole('button', { name: 'saveUnverified' });
    fireEvent.click(saveAnyway);
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(log.posts).toHaveLength(posts);
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.status).toEqual({ kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified });
    expect(saved.lastError).toBe(PROVIDER_VALIDATION_MESSAGES.unverified);
    expect(saved.baseURLText).toBe('https://relay.example.com');
    expect(saved.models.map((model) => [model.id, model.capabilities])).toEqual([['gpt-5.4', ['text']]]);
    expect(saved.relayKind).toBe('custom');
    expect(saved.relayRequested?.modelID).toBeUndefined();
    await waitFor(() => expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id'));
    const notice = takeProviderDetailNotice('relay-provider-id');
    expect(notice).toMatchObject({ unverifiedReason: expect.any(String) });
    // An unverified save does not set a last-used model.
    expect(mocks.setLastUsedModelRef).not.toHaveBeenCalled();
    // Detail page notice: one title line + the reason on its own line, warning style.
    setProviderDetailNotice('relay-provider-id', notice!);
    const banner = render(<ProviderDetailNoticeBanner providerID="relay-provider-id" />);
    const status = banner.getByRole('status');
    expect(status.getAttribute('data-notice')).toBe('unverified');
    expect(status.className).toContain('detailNotice');
    expect(status.querySelector('[data-notice-title]')?.textContent).toBe('connectionUnverified');
    expect(status.querySelector('[data-notice-title]')?.className).toContain('detailNoticeTitle');
    expect(status.querySelector('[data-notice-reason]')?.textContent).toBe(notice && 'unverifiedReason' in notice ? notice.unverifiedReason : '');
    expect(status.querySelector('[data-notice-reason]')?.className).toContain('detailNoticeReason');
    banner.unmount();
    // Completion latch: after persistence, neither the primary button nor "Save anyway" responds any more.
    fireEvent.click(primary());
    if (failureCard()) fireEvent.click(within(failureCard()!).getByRole('button', { name: 'saveUnverified' }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.addProvider).toHaveBeenCalledTimes(1);
    expect(log.posts).toHaveLength(posts);
    const validated = mocks.trackEvent.mock.calls
      .filter(([name]) => name === 'provider_key_validated')
      .map(([, properties]) => (properties as { success: boolean; error_code: string }));
    expect(validated.map((item) => [item.success, item.error_code])).toEqual([
      [false, 'route_unavailable'],
      [false, 'unverified_connection'],
    ]);
  });
});

describe('BOARD-MANUAL-07 verification passes', () => {
  it('BOARD-MANUAL-07 (1) fixed Responses: sends only 1 request with no probing, the model gets no protocol, relayKind derived from the protocol; all keys attached, empty ones not; detail notice 1, set as last used', async () => {
    markRelayHandoff({ entryPoint: 'providers' });
    const log = installFakeRelay({ pings: { 'gpt-5.4@responses': 200 }, catalog: ['gpt-5.4', 'gpt-5.4-mini'] });
    openManual();
    fillManual({ endpoint: 'relay.example.com', model: ' gpt-5.4 ' });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-b' } });
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[1]!, { target: { value: 'Backup' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    chooseProtocol('openai_responses');
    openAdvanced();
    fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.userAgent'), { target: { value: '  Agent/1  ' } });
    addEntry('pages.relayDetail.headers');
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1'), { target: { value: 'X-Team' } });
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1 pages.relayDetail.valuePlaceholder'), { target: { value: 'core' } });
    addEntry('pages.relayDetail.headers');
    fireEvent.click(primary());

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(log.posts).toEqual(['sk-a gpt-5.4@responses']);
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.status).toEqual({ kind: 'connected' });
    expect(saved.customName).toBe('example.com');
    expect(saved.baseURLText).toBe('https://relay.example.com');
    expect(saved.relayKind).toBe('codex_style');
    expect(saved.relayRequested).toMatchObject({
      transport: 'openai_responses', authMode: 'auto', stream: true, disableResponseStorage: true, codexCompatIdentity: true,
      customUserAgent: 'Agent/1', headers: [{ key: 'X-Team', value: 'core' }],
    });
    expect(saved.relayRequested?.serviceTier).toBeUndefined();
    expect(saved.relayRequested?.modelID).toBeUndefined();
    expect(saved.relayRequested?.queryParams).toBeUndefined();
    expect(saved.models).toHaveLength(1);
    expect(saved.models[0]).toMatchObject({ id: 'gpt-5.4', isDefault: false });
    expect(saved.models[0]!.relayTransport).toBeUndefined();
    expect(saved.relayKeys?.map((key) => [key.name ?? '', key.apiKey])).toEqual([['', ''], ['Backup', 'sk-b']]);
    expect(saved.catalogModels.some((model) => model.relayListedByKeyIDs?.length)).toBe(false);
    expect(mocks.setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'relay-provider-id', modelID: 'gpt-5.4' });
    await waitFor(() => expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id'));
    expect(takeProviderDetailNotice('relay-provider-id')).toEqual({ count: 1 });
    // (3) Persist first, then refresh the catalog without blocking (two keys fetched one by one).
    await waitFor(() => expect(log.gets).toEqual(['sk-a https://relay.example.com/v1/models', 'sk-b https://relay.example.com/v1/models']));
    await waitFor(() => expect((mocks.storeProviders[0] as Provider).catalogModels.map((model) => model.id)).toEqual(['gpt-5.4', 'gpt-5.4-mini']));
    expect(mocks.addProvider.mock.invocationCallOrder[0]!).toBeLessThan(
      (globalThis.fetch as ReturnType<typeof vi.fn>).mock.invocationCallOrder.at(-1)!,
    );
    // Completion latch.
    fireEvent.click(primary());
    expect(mocks.addProvider).toHaveBeenCalledTimes(1);
  });

  it('BOARD-MANUAL-07 (2) auto: probes by vendor-family candidates (<=2), the protocol that passes lands on the model; connection auto, relayKind custom, name trimmed; a single key does not write a multi-key list', async () => {
    const log = installFakeRelay({ pings: { 'claude-sonnet-4-5@chat': 200 } });
    openManual();
    fillManual({ model: 'claude-sonnet-4-5' });
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.connectionName), { target: { value: '  My Relay  ' } });
    fireEvent.click(primary());
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(log.posts).toEqual(['sk-a claude-sonnet-4-5@messages', 'sk-a claude-sonnet-4-5@chat']);
    const saved = mocks.addProvider.mock.calls[0]![1] as Provider;
    expect(saved.customName).toBe('My Relay');
    expect(saved.relayKind).toBe('custom');
    expect(saved.relayRequested).toMatchObject({ transport: 'auto', authMode: 'auto', disableResponseStorage: true, stream: true });
    expect(saved.relayRequested?.codexCompatIdentity).toBeUndefined();
    expect(saved.relayRequested?.headers).toBeUndefined();
    expect(saved.relayRequested?.queryParams).toBeUndefined();
    expect(saved.relayRequested?.customUserAgent).toBeUndefined();
    expect(saved.models[0]).toMatchObject({ id: 'claude-sonnet-4-5', relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable' });
    expect(saved.relayKeys).toBeUndefined();
  });

  it('BOARD-MANUAL-07 (3) a failed catalog refresh does not roll back the save', async () => {
    installFakeRelay({ pings: { 'gpt-5.4@chat': 200 } });
    vi.mocked(globalThis.fetch).mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
      const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
      if (method === 'GET') return new Response('{"error":"nope"}', { status: 500, headers: { 'content-type': 'application/json' } });
      void url;
      return new Response('{"id":"ok"}', { status: 200, headers: { 'content-type': 'application/json' } });
    });
    openManual();
    fillManual();
    chooseProtocol('openai_chat_completions');
    fireEvent.click(primary());
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    await waitFor(() => expect((mocks.storeProviders[0] as Provider).lastError).toBe(PROVIDER_VALIDATION_MESSAGES.catalogUnavailable));
    expect(mocks.storeProviders).toHaveLength(1);
    expect((mocks.storeProviders[0] as Provider).models.map((model) => model.id)).toEqual(['gpt-5.4']);
  });

  it('BOARD-MANUAL-07 (4) analytics relay_kind takes the effective protocol; kind_picker is not sent', async () => {
    expect(manualSetupEffectiveRelayKind('https://relay.example.com', 'openai_responses')).toBe('codex_style');
    expect(manualSetupEffectiveRelayKind('https://relay.example.com/v1/messages', 'auto')).toBe('anthropic_compatible');
    expect(manualSetupEffectiveRelayKind('https://relay.example.com', 'auto')).toBe('custom');
    expect(manualSetupEffectiveRelayKind('not a url at all', 'auto')).toBe('custom');
    installFakeRelay({ pings: { 'gpt-5.4@responses': 200 } });
    openManual();
    fillManual();
    chooseProtocol('openai_responses');
    fireEvent.click(primary());
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    const validated = mocks.trackEvent.mock.calls.filter(([name]) => name === 'provider_key_validated');
    expect(validated.map(([, properties]) => (properties as { relay_kind: string; success: boolean }).relay_kind)).toEqual(['codex_style']);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('kind_picker');
  });
});

describe('BOARD-MANUAL-08 editing input after a failure / in-flight invalidation', () => {
  async function failOnce(log = installFakeRelay({ pings: {} })) {
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    return log;
  }

  const edits: Array<[string, () => void]> = [
    ['address', () => fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay2.example.com' } })],
    ['key', () => fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-z' } })],
    ['model', () => fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-x' } })],
    ['protocol', () => chooseProtocol('anthropic_messages')],
    ['auth', () => { openAdvanced(); fireEvent.change(screen.getByLabelText('pages.relayDetail.authMode'), { target: { value: 'bearer' } }); }],
    ['UA', () => { openAdvanced(); fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.userAgent'), { target: { value: 'UA' } }); }],
    ['headers', () => { openAdvanced(); addEntry('pages.relayDetail.headers'); fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1'), { target: { value: 'X-A' } }); }],
    ['query params', () => { openAdvanced(); addEntry('pages.relayDetail.queryParams'); fireEvent.change(screen.getByLabelText('pages.relayDetail.queryParams 1'), { target: { value: 'q' } }); }],
  ];
  for (const [label, edit] of edits) {
    it(`BOARD-MANUAL-08 changing ${label}: the failure card disappears, the primary button resets, and the old failure can no longer Save anyway`, async () => {
      await failOnce();
      edit();
      expect(failureCard()).toBeNull();
      expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAndSave);
      expect(screen.queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    });
  }

  it('BOARD-MANUAL-08 changing the connection name or key name does not invalidate the failure card; Save anyway uses the name at that time', async () => {
    await failOnce();
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.connectionName), { target: { value: 'Later name' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[0]!, { target: { value: 'Main' } });
    expect(failureCard()).toBeTruthy();
    fireEvent.click(within(failureCard()!).getByRole('button', { name: 'saveUnverified' }));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).customName).toBe('Later name');
  });

  it('BOARD-MANUAL-08 changed and changed back while in flight: the primary button resets immediately, and the old (passing) result is not persisted and does not navigate', async () => {
    const log = installFakeRelay({ hold: true });
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(log.pending).toHaveLength(1));
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.4x' } });
    expect(primary().disabled).toBe(false);
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAndSave);
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.4' } });
    await act(async () => { log.pending[0]!.resolve(200); await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(mocks.addProvider).not.toHaveBeenCalled();
    expect(mocks.routerPush).not.toHaveBeenCalled();
  });

  it('BOARD-MANUAL-08 after an in-flight failure result is invalidated no failure card appears; leaving the page invalidates the in-flight one', async () => {
    const log = installFakeRelay({ hold: true });
    const view = openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(log.pending).toHaveLength(1));
    chooseProtocol('openai_responses');
    await act(async () => { log.pending[0]!.resolve(502); await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(failureCard()).toBeNull();
    fireEvent.click(primary());
    await waitFor(() => expect(log.pending).toHaveLength(2));
    view.unmount();
    expect(log.pending[1]!.signal?.aborted).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });
});

describe('BOARD-MANUAL-09 switching back and forth between quick and manual', () => {
  it('BOARD-MANUAL-09 address and all keys (including names) are shared; the manual page\'s model / protocol are still there on re-entry', () => {
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-b' } });
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[1]!, { target: { value: 'Backup' } });
    fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
    expect((screen.getByLabelText('requestURLLabel') as HTMLInputElement).value).toBe('relay.example.com');
    expect(screen.getByTestId('relay-endpoint-scheme').textContent).toBe('https');
    expect(screen.getAllByLabelText('apiKeyLabel').map((input) => (input as HTMLInputElement).value)).toEqual(['sk-a', 'sk-b']);
    expect((screen.getAllByLabelText('twoStep.keyName')[1] as HTMLInputElement).value).toBe('Backup');
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.4' } });
    chooseProtocol('anthropic_messages');
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-c' } });
    fireEvent.click(screen.getByRole('button', { name: 'pages.relaySetup.manual.useQuickSetup' }));
    expect(screen.getByRole('heading', { name: 'heroTitle' })).toBeTruthy();
    expect((screen.getAllByLabelText('apiKeyLabel')[0] as HTMLInputElement).value).toBe('sk-c');
    expect((screen.getAllByLabelText('twoStep.keyName')[1] as HTMLInputElement).value).toBe('Backup');
    fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
    expect((screen.getByLabelText(MANUAL_SETUP_TEXT.model) as HTMLInputElement).value).toBe('gpt-5.4');
    expect((screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol') as HTMLSelectElement).value).toBe('anthropic_messages');
  });

  it('BOARD-MANUAL-09 entering the manual page while quick-setup detection is in flight: detection is cancelled, and coming back stays on step 1', async () => {
    let release!: (response: Response) => void;
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
      if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
      return new Promise<Response>((resolve) => { release = resolve; });
    }));
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[0]!, { target: { value: 'sk-a' } });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await screen.findByTestId('relay-setup-detection');
    fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
    fireEvent.click(screen.getByRole('button', { name: 'pages.relaySetup.manual.useQuickSetup' }));
    await act(async () => {
      release(new Response(JSON.stringify({ object: 'list', data: [{ id: 'gpt-5.4', object: 'model' }] }), {
        status: 200, headers: { 'content-type': 'application/json' },
      }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(screen.queryByRole('heading', { name: 'twoStep.modelsTitle' })).toBeNull();
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
    expect(screen.getByRole('heading', { name: 'heroTitle' })).toBeTruthy();
  });
});

describe('BOARD-MANUAL-10 validation hints each in place', () => {
  it('BOARD-MANUAL-10 address / key issues go under the key block; header / query-param issues go into the collapsible group and expand it (even if the user collapsed it)', () => {
    const issues: RelayFormIssue[] = [
      { field: 'endpoint', code: 'endpoint_rejected' },
      { field: 'api_key', code: 'credential_invalid_characters' },
      { field: 'headers', code: 'cleartext_credentials' },
    ];
    const board = manualSetupBoard(boardInput({ issues, advancedChoice: false }));
    expect(board.apiKeys.issues.map((issue) => issue.field)).toEqual(['endpoint', 'api_key']);
    expect(board.advancedGroup.issues.map((issue) => issue.field)).toEqual(['headers']);
    expect(board.advancedGroup).toMatchObject({ expanded: true, forcedOpen: true });
    expect(manualSetupBoard(boardInput({ advancedChoice: false })).advancedGroup.expanded).toBe(false);
    expect(manualSetupBoard(boardInput({ advancedChoice: true })).advancedGroup.expanded).toBe(true);
  });

  it('BOARD-MANUAL-10 page: the address hint appears under the key block', () => {
    openManual();
    fillManual({ endpoint: 'http://192.168.1.20:8080/v1', key: 'sk-test　\u4e2d\u6587' });
    const keys = document.querySelector('[data-manual-section="apiKeys"]') as HTMLElement;
    expect(within(keys).getByText('common.relayHttpsRequired')).toBeTruthy();
    expect(within(keys).getByText('common.apiKeyInvalidChars')).toBeTruthy();
    const address = document.querySelector('[data-manual-section="requestURL"]') as HTMLElement;
    expect(within(address).queryByText('common.relayHttpsRequired')).toBeNull();
  });
});

describe('BOARD-MANUAL-11 click acceptance uses the same criterion as tappable', () => {
  it('BOARD-MANUAL-11 not tappable is not accepted; repeated clicks are accepted only once; tapping again after editing input in flight starts a new verification immediately, and the late old result is not persisted, shows no card and does not pull back to in-progress', async () => {
    const log = installFakeRelay({ hold: true });
    openManual();
    fillManual({ model: '' });
    fireEvent.click(primary());
    expect(log.posts).toEqual([]);
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.4' } });
    fireEvent.click(primary());
    fireEvent.click(primary());
    await waitFor(() => expect(log.pending).toHaveLength(1));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(log.posts).toHaveLength(1);
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'gpt-5.5' } });
    expect(primary().disabled).toBe(false);
    fireEvent.click(primary());
    await waitFor(() => expect(log.pending).toHaveLength(2));
    expect(log.posts[1]).toBe('sk-a gpt-5.5@chat');
    await act(async () => { log.pending[0]!.resolve(502); await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(failureCard()).toBeNull();
    expect(mocks.addProvider).not.toHaveBeenCalled();
    expect(primary().disabled).toBe(true);
    await act(async () => { log.pending[1]!.resolve(200); await new Promise((resolve) => setTimeout(resolve, 0)); });
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect((mocks.addProvider.mock.calls[0]![1] as Provider).models.map((model) => model.id)).toEqual(['gpt-5.5']);
  });
});

describe('BOARD-MANUAL-11 persistence throws', () => {
  it('BOARD-MANUAL-11 addProvider throws after verification passes: no endless spinner, the acceptance latch resets back to the failed state, tappable again', async () => {
    const log = installFakeRelay({ pings: { 'gpt-5.4@chat': 200 } });
    mocks.addProvider.mockRejectedValueOnce(new Error('disk full'));
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    expect(within(failureCard()!).getByText('Error: disk full')).toBeTruthy();
    expect(primary().disabled).toBe(false);
    expect(primary().querySelector('[data-spinner]')).toBeNull();
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAgain);
    expect(mocks.routerPush).not.toHaveBeenCalled();
    fireEvent.click(primary());
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(2));
    expect(log.posts).toHaveLength(2);
    await waitFor(() => expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id'));
  });
});

describe('BOARD-MANUAL-13 persistence throws vs verification failure are separate', () => {
  it('BOARD-MANUAL-13 pure board: the failure card for a persistence failure gives no Save anyway, and the primary button verifies again as before; a verification failure gives it as before', () => {
    const persistence = manualSetupBoard(boardInput({ phase: { kind: 'failed', failureID: 2, cause: 'persistence' } }));
    expect(persistence.failure).toEqual({ failureID: 2, noteKey: MANUAL_SETUP_TEXT.notSaved, saveUnverifiedKey: null });
    expect(persistence.primary).toEqual({ titleKey: MANUAL_SETUP_TEXT.validateAgain, enabled: true, spinning: false });
    const verification = manualSetupBoard(boardInput({ phase: { kind: 'failed', failureID: 3 } }));
    expect(verification.failure?.saveUnverifiedKey).toBe(MANUAL_SETUP_TEXT.saveUnverified);
  });

  it('BOARD-MANUAL-13 page: addProvider throws after verification passes -> the failure card reason is the generic sentence, with technical details and no Save anyway', async () => {
    installFakeRelay({ pings: { 'gpt-5.4@chat': 200 } });
    mocks.addProvider.mockRejectedValueOnce(new Error('disk full'));
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    const card = failureCard()!;
    expect(card.querySelector('p')?.textContent).toBe('unexpected.message');
    expect(within(card).getByText('attemptedRequests')).toBeTruthy();
    // Local error: technical details show only the exception detail itself, without the "Upstream response" subtitle and the "Upstream response redacted" note.
    expect(within(card).getByText('Error: disk full')).toBeTruthy();
    expect(within(card).queryByText('upstreamDiagnostic')).toBeNull();
    expect(within(card).queryByText('upstreamBodyRedacted')).toBeNull();
    expect(within(card).queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAgain);
    expect(primary().disabled).toBe(false);
  });

  it('BOARD-MANUAL-13 page: Save anyway (unverified) whose own persistence throws -> likewise no Save anyway, with technical details', async () => {
    installFakeRelay({ pings: {} });
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    mocks.addProvider.mockRejectedValueOnce(new Error('quota exceeded while saving'));
    fireEvent.click(within(failureCard()!).getByRole('button', { name: 'saveUnverified' }));
    await waitFor(() => expect(within(failureCard()!).queryByText('Error: quota exceeded while saving')).toBeTruthy());
    const card = failureCard()!;
    expect(within(card).getByText('attemptedRequests')).toBeTruthy();
    expect(within(card).queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    expect(primary().textContent).toBe(MANUAL_SETUP_TEXT.validateAgain);
    expect(mocks.routerPush).not.toHaveBeenCalled();
  });
});

describe('BOARD-MANUAL-14 persistence exception reason row and technical details', () => {
  it('BOARD-MANUAL-14 reason row = localized generic sentence without the original exception text; technical details = address row + redacted original exception text; contains no key / header value / query param value / UA', async () => {
    const secrets = ['sk-primary-0123456789', 'hdr-secret-value', 'qp-secret-value', 'Agent-Secret/9.9'];
    installFakeRelay({ pings: { 'gpt-5.4@chat': 200 } });
    mocks.addProvider.mockRejectedValueOnce(new Error(`database is locked ${secrets.join(' ')}`));
    openManual();
    fillManual({ key: secrets[0] });
    chooseProtocol('openai_chat_completions');
    openAdvanced();
    fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.userAgent'), { target: { value: secrets[3] } });
    addEntry('pages.relayDetail.headers');
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1'), { target: { value: 'X-Region' } });
    fireEvent.change(screen.getByLabelText('pages.relayDetail.headers 1 pages.relayDetail.valuePlaceholder'), { target: { value: secrets[1] } });
    addEntry('pages.relayDetail.queryParams');
    fireEvent.change(screen.getByLabelText('pages.relayDetail.queryParams 1'), { target: { value: 'region' } });
    fireEvent.change(screen.getByLabelText('pages.relayDetail.queryParams 1 pages.relayDetail.valuePlaceholder'), { target: { value: secrets[2] } });
    fireEvent.click(primary());

    await waitFor(() => expect(failureCard()).toBeTruthy());
    const card = failureCard()!;
    // Reason row: the localized generic sentence (same as Android error_generic_message); the original exception text does not go on the reason row.
    expect(card.querySelector('p')?.textContent).toBe('unexpected.message');
    expect(within(card).queryByText(/database is locked/, { selector: 'p' })).toBeNull();
    // Technical details: the address row (address only; a local error has no request method or status) + one line of exception text, through the same redaction.
    expect(card.querySelector('code')?.textContent).toContain('https://relay.example.com');
    expect(within(card).queryByText('networkStatus')).toBeNull();
    expect(card.querySelector('pre')?.textContent).toMatch(/^Error: database is locked /);
    for (const secret of secrets) expect(card.textContent).not.toContain(secret);
    expect(within(card).queryByRole('button', { name: 'saveUnverified' })).toBeNull();
  });
});

describe('BOARD-MANUAL-12 failure card reveal', () => {
  it('BOARD-MANUAL-12 the reveal function is the same as Edit Connection\'s: only a new card is revealed; the same one / a dismissed one is not', () => {
    expect(relayRevealsFailureCard(null, 1)).toBe(true);
    expect(relayRevealsFailureCard(1, 1)).toBe(false);
    expect(relayRevealsFailureCard(1, null)).toBe(false);
    expect(relayRevealsFailureCard(1, 2)).toBe(true);
  });

  it('BOARD-MANUAL-12 page: only a new card dismisses the keyboard and scrolls to it; the same one does not scroll again; a repeat failure is another card and is revealed again', async () => {
    const scrolled: Element[] = [];
    Element.prototype.scrollIntoView = function scrollIntoView(this: Element) { scrolled.push(this); };
    installFakeRelay({ pings: {} });
    openManual();
    fillManual();
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    expect(scrolled).toHaveLength(1);
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.connectionName), { target: { value: 'Rename' } });
    expect(scrolled).toHaveLength(1);
    fireEvent.click(primary());
    await waitFor(() => expect(failureCard()).toBeTruthy());
    await waitFor(() => expect(scrolled).toHaveLength(2));
    fireEvent.change(screen.getByLabelText(MANUAL_SETUP_TEXT.model), { target: { value: 'other' } });
    expect(failureCard()).toBeNull();
    expect(scrolled).toHaveLength(2);
  });
});

describe('BOARD-MANUAL-15 "Use quick setup" three tiers', () => {
  it('BOARD-MANUAL-15 fits on one line at 100% -> full; fits on one line at 85% -> scaled; otherwise wrapped (boundary inclusive)', () => {
    expect(quickSetupButtonFit(200, 120)).toBe('full');
    expect(quickSetupButtonFit(200, 200)).toBe('full');
    expect(quickSetupButtonFit(170, 200)).toBe('scaled');
    expect(quickSetupButtonFit(171, 200)).toBe('scaled');
    expect(quickSetupButtonFit(169.9, 200)).toBe('wrapped');
    expect(quickSetupButtonFit(80, 200)).toBe('wrapped');
  });

  it('BOARD-MANUAL-15 width not measured yet (0) shows as one line at 100%', () => {
    expect(quickSetupButtonFit(0, 200)).toBe('full');
    expect(quickSetupButtonFit(200, 0)).toBe('full');
  });
});
