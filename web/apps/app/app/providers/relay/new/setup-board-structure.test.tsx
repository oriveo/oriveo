import fs from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import { connectLocalEngineInBrowser, localBrowserEndpointAccess } from '../../../../lib/core/providers/local-browser-probe';
import { RelaySetup } from './RelaySetup';
import {
  LOCAL_SETUP_HERO_KEYS,
  LOCAL_SETUP_SECONDARY_KEY,
  RELAY_SETUP_HERO_KEYS,
  RELAY_SETUP_SECONDARY_KEY,
  RELAY_SETUP_SLOTS,
  formatLocalContextLength,
  localSetupBoard,
  localThinkingValueKey,
  type LocalSetupConnectionValue,
} from './setup-board';
import { relaySetupFailureKey, relayStepOnePrimary } from './relay-setup-two-step';

const mocks = vi.hoisted(() => ({
  sendMessageStream: vi.fn(),
  routerPush: vi.fn(),
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

vi.mock('../../../../lib/core/providers/adapters/relay', () => ({
  sendMessageStream: (...args: unknown[]) => mocks.sendMessageStream(...args),
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({}),
  useAppStore: (selector: (state: { providers: unknown[]; setHasCompletedOnboarding: () => void }) => unknown) =>
    selector({ providers: [], setHasCompletedOnboarding: () => undefined }),
}));

vi.mock('../../../../lib/core/provider-ops', () => ({ addProvider: vi.fn() }));

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
  }) => <button type="button" onClick={onClick} disabled={disabled} className={className} data-testid={rest['data-testid']}>{children}</button>,
}));

// MARK: - Fixtures (same recorded originals as local-engine-declarations.test.ts)

type RecordedExchange = {
  request: { method: string; path: string; body?: { model?: string } };
  response: { status: number; contentType: string; body?: unknown; text?: string };
};
type RecordedEngine = { status: 'recorded' | 'pending'; records?: RecordedExchange[]; instances?: Record<string, { records: RecordedExchange[] }> };
type ResponsePointer = { engine: string; instance?: string; all?: boolean; path?: string };
type FingerprintCase = {
  caseId: string;
  status?: 'pending';
  unreachable?: boolean;
  responses: ResponsePointer[];
  expect: { outcome: 'engine' | 'generic' | 'manual'; engineProfile?: string };
};

function fixture<T>(name: string): T {
  let directory = process.cwd();
  while (path.dirname(directory) !== directory) {
    const candidate = path.join(directory, 'shared/test-fixtures/local-engine', name);
    if (fs.existsSync(candidate)) return JSON.parse(fs.readFileSync(candidate, 'utf8')) as T;
    directory = path.dirname(directory);
  }
  throw new Error(`local engine fixture ${name} not found`);
}

const expectations = fixture<{ fingerprint: { cases: FingerprintCase[] } }>('engine-expectations.v1.json');
const recordings = fixture<{ engines: Record<string, RecordedEngine> }>('engine-declarations.v1.json');
const ENDPOINT = 'http://127.0.0.1:18080';

function recordsOf(engine: string, instance?: string): RecordedExchange[] {
  const entry = recordings.engines[engine]!;
  return (instance ? entry.instances?.[instance]?.records : entry.records) ?? [];
}

/** Fake server: replies only with recorded originals; paths not listed in the fixtures return 404. Returns the requests that were sent. */
function serveRecordings(pointers: ResponsePointer[], unreachable = false): string[] {
  const served = pointers.flatMap((pointer) => {
    const records = recordsOf(pointer.engine, pointer.instance);
    return pointer.all ? records : records.filter((record) => record.request.path === pointer.path);
  });
  const requests: string[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = new URL(String(input));
    const method = init?.method ?? 'GET';
    requests.push(`${method} ${url.pathname}`);
    if (unreachable) throw new TypeError('Failed to fetch');
    const requestedModel = typeof init?.body === 'string' ? (JSON.parse(init.body) as { model?: string }).model : undefined;
    const hit = served.find((record) => record.request.method === method
      && record.request.path === url.pathname
      && (record.request.body?.model === undefined || record.request.body.model === requestedModel));
    if (!hit) return new Response('404 page not found', { status: 404, headers: { 'content-type': 'text/plain' } });
    const payload = hit.response.body !== undefined ? JSON.stringify(hit.response.body) : hit.response.text ?? '';
    return new Response(payload, { status: hit.response.status, headers: { 'content-type': hit.response.contentType } });
  });
  return requests;
}

function generationSucceeds() {
  mocks.sendMessageStream.mockReturnValue({
    abort: vi.fn(),
    stream: new ReadableStream<string>({ start(controller) { controller.enqueue('ok'); controller.close(); } }),
  });
}

function renderScenario(mode: 'relay' | 'local') {
  window.history.replaceState({}, '', mode === 'local' ? '/providers/relay/new?mode=local' : '/providers/relay/new');
  return render(<RelaySetup />);
}

/** Document order: a comes before b. */
function precedes(a: Element, b: Element): boolean {
  return Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
}

beforeEach(() => {
  vi.restoreAllMocks();
  mocks.sendMessageStream.mockReset();
  mocks.routerPush.mockReset();
  Object.defineProperty(window, 'isSecureContext', { configurable: true, value: true });
  Object.defineProperty(navigator, 'permissions', {
    configurable: true,
    value: { query: vi.fn().mockResolvedValue({ state: 'granted' }) },
  });
});

// MARK: - Relay

/** Fake relay: GET .../models is decided by `catalog` (can be left pending), POST is counted. Returns the request log. */
function stubRelay(catalog: () => Promise<Response> | Response): { gets: string[]; posts: string[] } {
  const log = { gets: [] as string[], posts: [] as string[] };
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const headers = new Headers(init?.headers);
    const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
    const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
    if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
    if (method === 'GET' && url.endsWith('/models')) {
      log.gets.push(url);
      return catalog();
    }
    log.posts.push(url);
    return new Response('{"error":"route missing"}', { status: 404, headers: { 'content-type': 'application/json' } });
  });
  return log;
}

function catalogResponse(ids: string[]): Response {
  return new Response(JSON.stringify({ object: 'list', data: ids.map((id) => ({ id, object: 'model' })) }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}

function fillRelay(endpoint = 'https://relay.example.com') {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: endpoint } });
  fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'sk-test' } });
}

function checkState(check: 'connection' | 'catalog' | 'protocols'): string | null {
  return screen.getByTestId('relay-setup-detection').querySelector(`[data-check="${check}"]`)?.getAttribute('data-state') ?? null;
}

describe('BOARD-SETUP-01 relay structure', () => {
  it('BOARD-SETUP-01 three Hero buttons, slot order address -> key -> name -> add another key; no default model slot; preview row', () => {
    expect(RELAY_SETUP_HERO_KEYS).toEqual(['heroLabel', 'heroTitle', 'twoStep.heroSubtitle']);
    expect(RELAY_SETUP_SLOTS).toEqual(['endpoint', 'apiKey', 'keyName', 'addKey']);
    expect(RELAY_SETUP_SECONDARY_KEY).toBe('manualProtocol');
    renderScenario('relay');

    expect(screen.getAllByRole('heading').map((node) => node.textContent)).toEqual(['heroTitle']);
    expect(precedes(screen.getByText('heroLabel'), screen.getByRole('heading', { name: 'heroTitle' }))).toBe(true);
    expect(screen.getByText('twoStep.heroSubtitle')).toBeTruthy();
    // No default model slot.
    expect(screen.queryByLabelText('defaultModelLabel')).toBeNull();
    // An empty address shows no preview; a filled one gets the version appended by previewAPIRoot, plus /....
    expect(screen.queryByTestId('relay-setup-will-request')).toBeNull();
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'api.myrelay.dev' } });
    expect(screen.getByTestId('relay-setup-will-request').textContent)
      .toBe('twoStep.willRequest({"url":"https://api.myrelay.dev/v1/…"})');
    // With only one key no name input is shown; after adding a second key every key (including the primary) has a name input, and the primary key cannot be removed.
    expect(screen.queryAllByLabelText('twoStep.keyName')).toHaveLength(0);
    const endpoint = screen.getByLabelText('requestURLLabel');
    const apiKey = screen.getByLabelText('apiKeyLabel');
    const addKey = screen.getByRole('button', { name: 'twoStep.addKey' });
    expect(precedes(endpoint, apiKey) && precedes(apiKey, addKey)).toBe(true);
    expect(screen.getByText('apiKeyPrivacy')).toBeTruthy();
    fireEvent.click(addKey);
    const names = screen.getAllByLabelText('twoStep.keyName');
    const keys = screen.getAllByLabelText('apiKeyLabel');
    expect(names).toHaveLength(2);
    expect(keys).toHaveLength(2);
    expect(precedes(keys[0]!, names[0]!) && precedes(names[0]!, keys[1]!) && precedes(keys[1]!, names[1]!)).toBe(true);
    expect(screen.getAllByRole('button', { name: 'twoStep.removeKey' })).toHaveLength(1);
    expect(screen.getByTestId('relay_setup_add_key_button')).toBeTruthy();
    fireEvent.click(screen.getByTestId('relay_setup_remove_key_button'));
    expect(screen.queryAllByLabelText('twoStep.keyName')).toHaveLength(0);
    expect(screen.getByTestId('relay-endpoint-scheme').textContent).toBe('https');
    expect(screen.getByRole('button', { name: 'manualProtocol' })).toBeTruthy();
    expect(screen.getByText('twoStep.stepOf({"current":1,"total":2})')).toBeTruthy();
  });
});

describe('BOARD-SETUP-02 relay detection card, three items', () => {
  it('BOARD-SETUP-02 first click on Next shows three items + n / 3 + cancel; step 1 sends zero 1-token requests; the card disappears after cancel', async () => {
    let release!: (response: Response) => void;
    const log = stubRelay(() => new Promise<Response>((resolve) => { release = resolve; }));
    renderScenario('relay');
    fillRelay();
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));

    const card = await screen.findByTestId('relay-setup-detection');
    expect(card.textContent).toContain('twoStep.detectionTitle');
    expect(screen.getByText('twoStep.checkConnection')).toBeTruthy();
    expect(screen.getByText('twoStep.checkCatalog')).toBeTruthy();
    expect(screen.getByText('twoStep.checkProtocols')).toBeTruthy();
    expect(screen.getByTestId('relay-setup-detection-progress').textContent).toBe('0 / 3');
    expect(checkState('connection')).toBe('running');
    expect(checkState('catalog')).toBe('pending');
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByTestId('relay_setup_cancel_detection_button'));
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(false);
    release(catalogResponse(['gpt-5.4']));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
    expect(log.posts).toEqual([]);
  });

  it('BOARD-SETUP-02 empty catalog: connectivity done (reachable path), catalog failed with modelsEmpty, protocol skipped, 3 / 3; changing only the name does not dismiss it, changing the key does', async () => {
    const log = stubRelay(() => catalogResponse([]));
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await waitFor(() => expect(screen.getByTestId('relay-setup-detection-progress').textContent).toBe('3 / 3'));
    expect(checkState('connection')).toBe('done');
    expect(checkState('catalog')).toBe('failed');
    expect(checkState('protocols')).toBe('skipped');
    expect(screen.getByText('twoStep.reachablePath({"path":"/v1/models"})')).toBeTruthy();
    expect(screen.getAllByText('twoStep.modelsEmpty').length).toBeGreaterThan(0);
    expect(screen.getByText('twoStep.checkSkipped')).toBeTruthy();
    // Elapsed time: seconds with one decimal, reusing the existing "{value} s" format.
    expect(screen.getByTestId('relay-setup-detection').querySelector('[data-check="connection"] [data-elapsed]')?.textContent)
      .toMatch(/^detail\.durationS\(\{"value":"\d+\.\d"\}\)$/);
    expect(screen.queryByTestId('relay_setup_cancel_detection_button')).toBeNull();
    expect(log.posts).toEqual([]);
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    fireEvent.change(screen.getAllByLabelText('twoStep.keyName')[0]!, { target: { value: 'Main' } });
    expect(screen.getByTestId('relay-setup-detection')).toBeTruthy();
    fireEvent.change(screen.getAllByLabelText('apiKeyLabel')[1]!, { target: { value: 'sk-two' } });
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
  });

  it('BOARD-SETUP-02 one-sentence classification: route unavailable / returned a web page -> address; 401 -> key; 403 -> cannot list models; network -> cannot connect; others keep the existing reason', () => {
    const failed = (failure: RelayDiscoveryResult['failure'], statusCode?: number): RelayDiscoveryResult => ({
      state: 'failed', failure, retriedRequestCount: 0,
      attempts: statusCode ? [{ method: 'GET', requestURL: 'https://relay.example.com/v1/models', statusCode, kind: 'catalog', retryCount: 0 }] : [],
    });
    expect(relaySetupFailureKey(failed('route_unavailable', 404))).toBe('twoStep.failAddress');
    expect(relaySetupFailureKey(failed('invalid_response', 200))).toBe('twoStep.failAddress');
    expect(relaySetupFailureKey(failed('authentication_rejected', 401))).toBe('twoStep.failKey');
    expect(relaySetupFailureKey(failed('authentication_rejected', 403))).toBe('twoStep.failPermission');
    expect(relaySetupFailureKey(failed('network'))).toBe('twoStep.failNetwork');
    expect(relaySetupFailureKey(failed('rate_limited', 429))).toBe('relayRateLimited');
    expect(relaySetupFailureKey(failed('temporary_failure', 502))).toBe('temporaryFailure');
    expect(relaySetupFailureKey(failed('embedded_query'))).toBe('embeddedQuery');
  });
});

describe('BOARD-SETUP-03 relay Next state', () => {
  it('BOARD-SETUP-03 not detected -> start detection; not clickable while detecting; success with catalog >= 1 enters step 2 automatically; failure stays, clicking again enters step 2 in manual-add state', async () => {
    expect(relayStepOnePrimary({ detection: null, isDetecting: false, canSubmit: true })).toEqual({ action: 'detect', enabled: true });
    expect(relayStepOnePrimary({ detection: null, isDetecting: false, canSubmit: false }).enabled).toBe(false);
    expect(relayStepOnePrimary({ detection: null, isDetecting: true, canSubmit: true }).enabled).toBe(false);

    stubRelay(() => new Response('{"error":"bad key"}', { status: 401, headers: { 'content-type': 'application/json' } }));
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await waitFor(() => expect(checkState('connection')).toBe('failed'));
    expect(checkState('catalog')).toBe('skipped');
    expect(checkState('protocols')).toBe('skipped');
    expect(screen.getByText('twoStep.failKey')).toBeTruthy();
    // A failed item keeps the "requests tried" list; the collapsed title follows iOS "What Oriveo tried".
    expect(screen.getByText('whatOriveoTried')).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'heroTitle' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
    expect(screen.getByText('twoStep.modelsEmpty')).toBeTruthy();
    expect((screen.getByTestId('relay_setup_models_save_button') as HTMLButtonElement).disabled).toBe(true);
    // Going back to step 1, the detection card is still there.
    fireEvent.click(screen.getByTestId('relay_setup_models_back_button'));
    expect(screen.getByTestId('relay-setup-detection')).toBeTruthy();
  });

  it('BOARD-SETUP-03 primary key 403: connectivity failed (cannot list models), the other two items skipped', async () => {
    stubRelay(() => new Response('{"error":"forbidden"}', { status: 403, headers: { 'content-type': 'application/json' } }));
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await waitFor(() => expect(checkState('connection')).toBe('failed'));
    expect(checkState('catalog')).toBe('skipped');
    expect(checkState('protocols')).toBe('skipped');
    expect(screen.getByText('twoStep.failPermission')).toBeTruthy();
    expect(screen.getByTestId('relay-setup-detection-progress').textContent).toBe('3 / 3');
  });

  it('BOARD-SETUP-03 extra key empty row: does not block Next, ignored during detection', async () => {
    const log = stubRelay(() => catalogResponse(['gpt-5.4']));
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.addKey' }));
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
    expect(log.gets).toHaveLength(1);
  });

  it('BOARD-SETUP-03 success with non-empty catalog: enters step 2 automatically', async () => {
    stubRelay(() => catalogResponse(['gpt-5.4', 'gpt-5.4-mini']));
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
  });
});

// MARK: - Local

describe('BOARD-SETUP-04 local structure', () => {
  it('BOARD-SETUP-04 three Hero buttons, only an address slot (no default model slot), secondary row button; no safety mode switch, no engine menu exposed', () => {
    expect(LOCAL_SETUP_HERO_KEYS).toEqual(['localHeroLabel', 'localHeroTitle', 'localHeroSubtitle']);
    expect(LOCAL_SETUP_SECONDARY_KEY).toBe('localManualEngine');
    renderScenario('local');

    expect(screen.getAllByRole('heading').map((node) => node.textContent)).toEqual(['localHeroTitle']);
    expect(screen.getByText('localHeroLabel')).toBeTruthy();
    expect(screen.getByText('localHeroSubtitle')).toBeTruthy();
    expect(screen.getByLabelText('engineAddress')).toBeTruthy();
    expect(screen.queryByLabelText('defaultModelLabel')).toBeNull();
    expect(screen.queryByLabelText('apiKeyLabel')).toBeNull();
    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect(screen.queryByLabelText('engine')).toBeNull();
    expect(screen.getByRole('button', { name: 'localManualEngine' })).toBeTruthy();
    expect(localSetupBoard({
      result: null, isDetecting: false, endpointAccess: 'empty', manualExpanded: true, manualEngine: 'openwebui', hasApiKey: false,
    }).slots).toEqual(['endpoint', 'apiKey']);
    expect(localSetupBoard({
      result: null, isDetecting: false, endpointAccess: 'empty', manualExpanded: false, manualEngine: 'ollama', hasApiKey: false,
    }).slots).toEqual(['endpoint']);
  });
});

describe('BOARD-SETUP-05 local detection card, three states', () => {
  const base = { isDetecting: false, endpointAccess: 'allowed' as const, manualExpanded: false, manualEngine: 'ollama' as const, hasApiKey: false };

  it('BOARD-SETUP-05 llama.cpp recording: context from /props n_ctx, thinking per chat template, footnote "currently loaded by the engine"', async () => {
    serveRecordings([{ engine: 'llamacpp', instance: 'text_only', all: true }]);
    generationSucceeds();
    const connected = await connectLocalEngineInBrowser({ engine: 'llamacpp', endpoint: ENDPOINT, securityMode: 'local_http' });
    const board = localSetupBoard({ ...base, result: { ...connected, engine: 'llamacpp', channel: 'chat' } });
    expect(board).toMatchObject({
      card: 'succeeded',
      failure: null,
      summary: { engine: 'llama.cpp', modelCount: 1, channel: 'OpenAI Chat Completions', contextLength: '2K', thinking: 'localThinkingTemplate' },
    });
  });

  it('BOARD-SETUP-05 LM Studio recording: context from max_context_length of the default model catalog row, thinking decided by the model', async () => {
    serveRecordings([{ engine: 'lmstudio', all: true }]);
    generationSucceeds();
    const connected = await connectLocalEngineInBrowser({ engine: 'lmstudio', endpoint: ENDPOINT, securityMode: 'local_http' });
    const board = localSetupBoard({ ...base, result: { ...connected, engine: 'lmstudio', channel: 'chat' } });
    expect(board.summary).toMatchObject({ engine: 'LM Studio', contextLength: '8K', thinking: 'localThinkingModel' });
  });

  it('BOARD-SETUP-05 three thinking values; context that cannot be measured is null (shows "not available", never 0)', () => {
    expect(localThinkingValueKey('llamacpp', 'chat', undefined)).toBe('localThinkingTemplate');
    expect(localThinkingValueKey('llamacpp', 'native', undefined)).toBe('localThinkingModel');
    expect(localThinkingValueKey('ollama', 'chat', false)).toBe('localValueUnsupported');
    expect(localThinkingValueKey('ollama', 'chat', true)).toBe('localThinkingModel');
    expect(formatLocalContextLength(undefined)).toBeNull();
    expect(formatLocalContextLength(0)).toBeNull();
    const ollama: LocalSetupConnectionValue = {
      state: 'ready', endpoint: ENDPOINT, modelIDs: ['qwen3:0.6b'], generationVerified: true, engine: 'ollama', channel: 'chat',
      models: [{ id: 'qwen3:0.6b', localLoadState: 'unknown', executionLocality: 'local', engineDeclaration: { thinking: false } }],
    };
    expect(localSetupBoard({ ...base, result: ollama }).summary).toMatchObject({ contextLength: null, thinking: 'localValueUnsupported' });
  });

  it('BOARD-SETUP-05 hidden / detecting / connection failure keep the existing failure row', () => {
    expect(localSetupBoard({ ...base, result: null }).card).toBe('hidden');
    expect(localSetupBoard({ ...base, result: null, isDetecting: true }).card).toBe('detecting');
    const failed = localSetupBoard({
      ...base,
      result: { state: 'unreachable', failure: 'cors_blocked', endpoint: ENDPOINT, modelIDs: [], models: [], generationVerified: false, engine: 'ollama', channel: 'chat' },
    });
    expect(failed).toMatchObject({ card: 'failed', failure: 'connection', showsManualPicker: false, summary: null });
  });
});

describe('BOARD-SETUP-06 local fingerprint drives the engine (engine-expectations.v1.json fingerprint.cases)', () => {
  const displayName: Record<string, string> = { ollama: 'Ollama', llamacpp: 'llama.cpp', lmstudio: 'LM Studio', vllm: 'vLLM' };
  for (const item of expectations.fingerprint.cases) {
    if (item.status === 'pending') continue;
    it(`BOARD-SETUP-06 ${item.caseId}`, async () => {
      serveRecordings(item.responses, item.unreachable === true);
      generationSucceeds();
      renderScenario('local');
      fireEvent.change(screen.getByLabelText('engineAddress'), { target: { value: ENDPOINT } });
      fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
      if (item.expect.outcome === 'engine') {
        const engine = displayName[item.expect.engineProfile!]!;
        expect(await screen.findByText(new RegExp(`^localRecognized\\(\\{"engine":"${engine.replace('.', '\\.')}"`))).toBeTruthy();
        expect(screen.getByRole('button', { name: 'connectAndSave' })).toBeTruthy();
        expect(screen.queryByLabelText('engine')).toBeNull();
      } else {
        expect(await screen.findByText('localUnrecognizedTitle')).toBeTruthy();
        expect(screen.getByText('localUnrecognizedBody')).toBeTruthy();
        // Manual selection expands automatically, and the primary button returns to Detect.
        expect(screen.getByLabelText('engine')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'detectConnectionSettings' })).toBeTruthy();
      }
    });
  }

  it('BOARD-SETUP-06 user expanded manual selection and chose an engine: skip the fingerprint and connect directly with the chosen engine and channel', async () => {
    const requests = serveRecordings([{ engine: 'llamacpp', instance: 'text_only', all: true }]);
    generationSucceeds();
    renderScenario('local');
    fireEvent.click(screen.getByRole('button', { name: 'localManualEngine' }));
    fireEvent.change(screen.getByLabelText('engine'), { target: { value: 'llamacpp' } });
    expect(screen.getByLabelText('localTileChannel')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('engineAddress'), { target: { value: ENDPOINT } });
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect(await screen.findByText(/^localRecognized\(\{"engine":"llama\.cpp"/)).toBeTruthy();
    // None of the three fingerprint-specific probes was sent.
    expect(requests).not.toContain('GET /api/tags');
    expect(requests).not.toContain('GET /api/v0/models');
    expect(requests).not.toContain('GET /version');
    expect(screen.getByText('2K')).toBeTruthy();
    expect(screen.getByText('localThinkingTemplate')).toBeTruthy();
  });
});

describe('BOARD-SETUP-07 local button three states', () => {
  it('BOARD-SETUP-07 Detect -> detecting(loading) -> Connect and save; local has no Save and continue', () => {
    const base = { endpointAccess: 'allowed' as const, manualExpanded: false, manualEngine: 'ollama' as const, hasApiKey: false };
    expect(localSetupBoard({ ...base, result: null, isDetecting: false })).toMatchObject({ primaryButton: 'detectConnectionSettings', isPrimaryEnabled: true });
    expect(localSetupBoard({ ...base, result: null, isDetecting: true })).toMatchObject({ card: 'detecting', isPrimaryEnabled: false });
    const ok: LocalSetupConnectionValue = { state: 'ready', endpoint: ENDPOINT, modelIDs: ['m'], models: [], generationVerified: true, apiBaseURL: `${ENDPOINT}/v1`, engine: 'vllm', channel: 'chat' };
    expect(localSetupBoard({ ...base, result: ok, isDetecting: false }).primaryButton).toBe('connectAndSave');
    const unrecognized: LocalSetupConnectionValue = { state: 'unreachable', endpoint: ENDPOINT, modelIDs: [], models: [], generationVerified: false, unrecognized: true };
    expect(localSetupBoard({ ...base, result: unrecognized, isDetecting: false })).toMatchObject({
      primaryButton: 'detectConnectionSettings', failure: 'unrecognized', showsManualPicker: true,
    });
  });
});

describe('WEB-SETUP-LAN-01 (Web only) LAN http -> W1 + primary button disabled', () => {
  it('WEB-SETUP-LAN-01 address classification: loopback http and any https are allowed, LAN http is blocked', () => {
    for (const raw of ['http://127.0.0.1:8080', 'http://localhost:11434', 'http://[::1]:1234', 'https://192.168.1.20:8080', 'https://gpu.example.com']) {
      expect(localBrowserEndpointAccess(raw).kind).toBe('allowed');
    }
    for (const raw of ['http://192.168.1.20:8080', 'http://10.0.0.8:11434', 'http://studio.local:1234', 'http://gpu.example.com']) {
      expect(localBrowserEndpointAccess(raw).kind).toBe('lan_http_blocked');
    }
    expect(localBrowserEndpointAccess('http://localhost:11434')).toMatchObject({ securityMode: 'local_http' });
  });

  it('WEB-SETUP-LAN-01 page: LAN http shows W1 and the primary button is disabled; switching to loopback restores it', () => {
    renderScenario('local');
    const endpoint = screen.getByLabelText('engineAddress');
    fireEvent.change(endpoint, { target: { value: 'http://192.168.1.20:8080' } });
    expect(screen.getByText('localLanHttpBlocked')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByTestId('local-endpoint-scheme').textContent).toBe('http');

    fireEvent.change(endpoint, { target: { value: 'http://localhost:8080' } });
    expect(screen.queryByText('localLanHttpBlocked')).toBeNull();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(false);
  });
});

describe('BOARD-SETUP-08 add flow primary button loading has the same color as the button text', () => {
  it('BOARD-SETUP-08 style: the spinner has no fixed color (no longer hard-coded white) and follows the button text color (currentColor = --o-primary-text)', () => {
    const css = fs.readFileSync(path.join(process.cwd(), 'app/providers/relay/new/RelaySetup.module.css'), 'utf8');
    expect(css).not.toMatch(/\.primaryAction \.spinner/);
    const spinnerRules = [...css.matchAll(/\.spinner\s*\{([^}]*)\}/g)].map((match) => match[1]);
    expect(spinnerRules.length).toBeGreaterThan(0);
    for (const rule of spinnerRules) expect(rule).not.toMatch(/(^|[^-])color\s*:/);
    const buttonCSS = fs.readFileSync(path.join(process.cwd(), '../../packages/ui/src/components/Button/Button.module.css'), 'utf8');
    expect(/\.primary\s*\{([^}]*)\}/.exec(buttonCSS)?.[1]).toMatch(/color:\s*var\(--o-primary-text\)/);
  });

  it('BOARD-SETUP-08 the spinner in the step 2 save primary button is the spinner in primaryAction, svg uses currentColor (Phosphor, no longer lucide)', async () => {
    let releaseSave: ((response: Response) => void) | undefined;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const headers = new Headers(init?.headers);
      const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
      const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
      if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
      if (method === 'GET') return catalogResponse(['gpt-5.4']);
      return new Promise<Response>((resolve) => { releaseSave = resolve; });
    });
    renderScenario('relay');
    fillRelay();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
    for (const button of screen.getAllByTestId('relay_setup_models_select_group_button')) fireEvent.click(button);
    fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
    const save = screen.getByTestId('relay_setup_models_save_button');
    const spinner = await waitFor(() => {
      const element = save.querySelector('[data-spinner]');
      expect(element).toBeTruthy();
      return element!;
    });
    expect(save.className).toContain('primaryAction');
    expect(spinner.getAttribute('class')).toContain('spinner');
    expect(spinner.getAttribute('fill')).toBe('currentColor');
    expect(spinner.getAttribute('color') ?? '').toBe('');
    expect(save.querySelector('.lucide')).toBeNull();
    releaseSave?.(new Response('{"error":"x"}', { status: 502, headers: { 'content-type': 'application/json' } }));
  });
});

describe('LOCAL-ADDR local add page address title', () => {
  it('LOCAL-ADDR address field title = the Engine address string already used by edit connection', () => {
    renderScenario('local');
    const label = document.querySelector('label[for="local-endpoint"]');
    expect(label?.textContent).toBe('engineAddress');
    expect(screen.queryByText('requestURLLabel')).toBeNull();
  });
});

describe('RL2-COPY-6-5 detection result card copy (pending mapping cleanup)', () => {
  const detection = {
    transport: 'openai_chat_completions',
    authMode: 'bearer',
    apiBaseURL: 'https://relay.example/v1',
    modelIDs: [],
    catalogModels: [],
    generationVerified: true,
    catalogEvidenceSucceeded: false,
    detectionEvidence: 'generation_probe',
  } as unknown as NonNullable<RelayDiscoveryResult['detection']>;

  it('RL2-COPY-6-5 only generation route probed: the note uses probeProtocol and no longer passes a protocol; the detection success / failure title no longer appears above the result card', async () => {
    const { DiscoveryStatus } = await import('./RelaySimpleForm');
    const { container, unmount } = render(<DiscoveryStatus result={{ state: 'needs_manual_model', detection, attempts: [], retriedRequestCount: 0 }} />);
    expect(screen.getByText('probeProtocol')).toBeTruthy();
    expect(container.querySelector('[role="status"] > strong')).toBeNull();
    expect(screen.queryByText('relayDetected')).toBeNull();
    unmount();

    const failed = render(<DiscoveryStatus result={{ state: 'failed', failure: 'network', attempts: [], retriedRequestCount: 0 }} />);
    expect(screen.getByText('networkFailure')).toBeTruthy();
    expect(screen.queryByText('relayDetectionFailed')).toBeNull();
    failed.unmount();
  });
});
