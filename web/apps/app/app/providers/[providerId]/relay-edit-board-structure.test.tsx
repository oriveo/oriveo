import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { LocalEngineKind, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { validateRelayForm, relayFormNormalizedEndpoint, type RelayFormDraft } from '@oriveo/core/providers/relay-form-validation';
import { createAppStore } from '../../../lib/core/store/app-store';
import { buildRelaySettingsCandidate, updateProviderRelaySettings } from '../../../lib/core/provider-ops';
import { planRelaySettingsSave } from '../../../lib/core/providers/provider-sync';
import {
  RELAY_EDIT_TEXT,
  relayEditActiveCompatRows,
  relayEditBoard,
  relayEditDraftFromProvider,
  relayEditDraftMatchesSaved,
  relayEditNeedsVerification,
  relayEditNextGroupChoice,
  relayEditRevealsStatus,
  relayEditSavePatch,
  type EditCompatRowID,
  type EditGroup,
  type EditRow,
  type EditText,
  type RelayEditBoard,
  type RelayEditBoardInput,
  type RelayEditDraft,
  type RelayEditStatus,
} from './relay-edit-board';
import { RelayEditConnection } from './components/RelayEditConnection';

/**
 * Edit Connection board structure tests (cases BOARD-EDIT-01 to 18):
 * assert the output of relayEditBoard, and the header / groups / action bar rendered by the production component; saving goes through the production patch and store writes.
 */

vi.mock('../../../lib/core/sync', () => ({ getSyncAdapter: () => undefined }));
vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

const KEY = 'sk-relay-secret-0123456789';

function relayProvider(requested: Partial<RelayRequestedConfig> = {}, overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-edit',
    kind: 'relay',
    customName: 'Work relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: KEY,
    apiKeyPreview: '••••6789',
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'custom',
    relayRequested: {
      transport: 'auto',
      authMode: 'bearer',
      securityMode: 'remote_https',
      ...requested,
    },
    ...overrides,
  };
}

function localProvider(engine: LocalEngineKind, securityMode: RelayRequestedConfig['securityMode'] = 'local_http'): Provider {
  return {
    id: 'local-edit',
    kind: 'relay',
    customName: 'Mac mini',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: securityMode === 'local_http' ? 'http://192.168.1.20:8080' : 'https://mac-mini.local:8443',
    relayKind: 'custom',
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: securityMode === 'local_http' ? 'none' : 'bearer',
      securityMode,
      engineProfile: engine,
    },
  };
}

function formDraft(provider: Provider, draft: RelayEditDraft): RelayFormDraft {
  return {
    endpoint: draft.endpoint,
    apiKey: '',
    authMode: draft.authMode,
    securityMode: provider.relayRequested?.securityMode ?? 'remote_https',
    transport: draft.transport,
    modelID: '',
    headers: draft.headers,
    queryParams: draft.queryParams,
    hasSavedCredential: (provider.apiKey ?? '').trim().length > 0,
  };
}

function board(provider: Provider, patch: Partial<RelayEditDraft> = {}, extra: Partial<RelayEditBoardInput> = {}): RelayEditBoard {
  const draft = { ...relayEditDraftFromProvider(provider), ...patch };
  const form = formDraft(provider, draft);
  return relayEditBoard({
    provider,
    displayName: provider.customName ?? '',
    draft,
    status: null,
    isSaving: false,
    issues: validateRelayForm(form, 'edit'),
    normalizedEndpoint: relayFormNormalizedEndpoint(form, 'edit'),
    shownCompatRows: new Set(),
    groupChoice: {},
    ...extra,
  });
}

const groupIDs = (value: RelayEditBoard) => value.groups.map((group) => group.id);
const group = (value: RelayEditBoard, id: EditGroup['id']) => value.groups.find((item) => item.id === id);
const rowIDs = (value: RelayEditBoard, id: EditGroup['id']) => group(value, id)?.rows.map((row) => row.id);
const row = (value: RelayEditBoard, id: EditRow['id']) => value.groups.flatMap((item) => item.rows).find((item) => item.id === id);
const actions = (value: RelayEditBoard) => [value.actionBar.test.enabled, value.actionBar.primary.enabled];

function renderBoard(value: RelayEditBoard, draft: RelayEditDraft, status: RelayEditStatus | null = null) {
  return render(
    <RelayEditConnection
      board={value}
      draft={draft}
      status={status}
      locked={false}
      endpointRevealVersion={0}
      issueMessage={(issue) => `issue:${issue.field}:${issue.code}`}
      onDraftChange={vi.fn()}
      onToggleGroup={vi.fn()}
      renderSecurityControl={(icon) => <span data-testid="security-control">{icon}</span>}
      onTest={vi.fn()}
      onPrimary={vi.fn()}
      onClose={vi.fn()}
      failureCard={null}
      showDiscardConfirm={false}
      onKeepEditing={vi.fn()}
      onDiscard={vi.fn()}
    />,
  );
}

describe('BOARD-EDIT-01 relay, four groups', () => {
  it('BOARD-EDIT-01 group order / group titles / row order / icons and row colors / collapsing / footnotes', () => {
    const provider = relayProvider({
      customUserAgent: 'Agent/1',
      headers: [{ key: 'X-Tenant', value: 'alpha' }],
      queryParams: [{ key: 'region', value: 'sg' }],
    });
    const value = board(provider);

    expect(groupIDs(value)).toEqual(['connection', 'protocolAuth', 'headers', 'compatibility']);
    expect(value.groups.map((item) => item.titleKey)).toEqual([
      'pages.relayDetail.connectionTitle',
      'pages.relayDetail.editBoard.protocolAuth',
      'pages.relayDetail.sectionHeadersQuery',
      'pages.relayDetail.sectionBehavior',
    ]);
    expect(rowIDs(value, 'connection')).toEqual(['requestURL', 'connectionSecurity']);
    expect(rowIDs(value, 'protocolAuth')).toEqual(['defaultProtocol', 'authentication']);
    expect(value.groups.map((item) => [item.collapsible, item.expanded])).toEqual([
      [false, true], [false, true], [true, false], [true, false],
    ]);
    expect(['requestURL', 'connectionSecurity', 'defaultProtocol', 'authentication'].map((id) => {
      const item = row(value, id as EditRow['id'])!;
      return [item.icon, item.colorToken];
    })).toEqual([
      ['link', '--o-row-cyan'],
      ['shield-check', '--o-row-teal'],
      ['hard-drives', '--o-row-indigo'],
      ['key', '--o-row-orange'],
    ]);
    // Same row and same color as on the detail page (request URL cyan, default protocol indigo).
    expect(row(value, 'requestURL')?.footnote).toEqual({
      key: 'pages.relaySetup.twoStep.willRequest',
      values: { url: 'https://relay.example.com/v1/…' },
    });
    expect(row(value, 'connectionSecurity')).toMatchObject({
      value: { key: 'pages.relayDetail.connectionTypeRemoteHttps' },
      footnote: { key: 'pages.relayDetail.editBoard.securityFootnote' },
    });
    expect(rowIDs(value, 'headers')).toEqual(['userAgent', 'header', 'queryParam', 'addEntry']);
    expect(row(value, 'header')?.masked).toBe(true);
    expect(row(value, 'queryParam')?.masked).toBeUndefined();
    expect(row(value, 'addEntry')?.titleKey).toBe('pages.relayDetail.editBoard.add');
  });

  it('BOARD-EDIT-01 the "will request" row is not shown when the preview cannot be computed', () => {
    expect(row(board(relayProvider(), { endpoint: '' }), 'requestURL')?.footnote).toBeUndefined();
  });

  it('BOARD-EDIT-01 production component: header close button + centered title + connection-name subtitle; collapsed groups render no rows', () => {
    const provider = relayProvider();
    const value = board(provider);
    renderBoard(value, relayEditDraftFromProvider(provider));

    expect(screen.getByRole('button', { name: 'common.close' })).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'pages.relayDetail.editConnection' })).toBeTruthy();
    expect(screen.getByText('Work relay')).toBeTruthy();
    expect([...document.querySelectorAll('[data-edit-group]')].map((node) => node.getAttribute('data-edit-group')))
      .toEqual(['connection', 'protocolAuth', 'headers', 'compatibility']);
    expect(screen.getByRole('button', { name: /sectionHeadersQuery/ }).getAttribute('aria-expanded')).toBe('false');
    expect(document.querySelector('[data-edit-row="userAgent"]')).toBeNull();
    expect([...document.querySelectorAll('[data-row-icon]')].map((node) => node.getAttribute('data-row-icon')))
      .toEqual(['link', 'shield-check', 'hard-drives', 'key']);
  });
});

describe('BOARD-EDIT-02 local connection', () => {
  it('BOARD-EDIT-02 plaintext: connection + channel groups, no auth row, no headers group, no compatibility group; multiple channels get a menu', () => {
    const value = board(localProvider('llamacpp'));
    expect(groupIDs(value)).toEqual(['connection', 'channel']);
    expect(group(value, 'channel')?.titleKey).toBe('pages.relaySetup.localTileChannel');
    expect(rowIDs(value, 'connection')).toEqual(['engineAddress', 'connectionSecurity']);
    expect(row(value, 'engineAddress')).toMatchObject({ icon: 'link', colorToken: '--o-row-cyan' });
    expect(row(value, 'engineAddress')?.footnote).toBeUndefined();
    expect(rowIDs(value, 'channel')).toEqual(['channel']);
    expect(row(value, 'channel')).toMatchObject({ icon: 'hard-drives', colorToken: '--o-row-indigo' });
    expect(row(value, 'channel')?.options?.map((option) => option.value)).toEqual(['openai_chat_completions', 'llamacpp_native']);
  });

  it('BOARD-EDIT-02 with a single candidate the row is read-only with no chevron', () => {
    const value = board(localProvider('ollama'));
    expect(row(value, 'channel')?.options).toBeUndefined();
    expect(row(value, 'channel')?.value).toEqual({ literal: 'OpenAI Chat Completions' });
  });

  it('BOARD-EDIT-02 encrypted: the channel group gains an auth row and a headers group appears; still no compatibility group', () => {
    const value = board(localProvider('vllm', 'tofu_https'));
    expect(groupIDs(value)).toEqual(['connection', 'channel', 'headers']);
    expect(rowIDs(value, 'channel')).toEqual(['channel', 'authentication']);
  });
});

describe('BOARD-EDIT-03 footnotes', () => {
  it('BOARD-EDIT-03 default protocol footnote, two states', () => {
    expect(row(board(relayProvider()), 'defaultProtocol')?.footnote)
      .toEqual({ key: 'pages.relayDetail.editBoard.protocolAutoFootnote' });
    expect(row(board(relayProvider({ transport: 'anthropic_messages' })), 'defaultProtocol')?.footnote)
      .toEqual({ key: 'pages.relayDetail.editBoard.protocolSelectedFootnote', values: { protocol: 'Messages' } });
  });

  it('BOARD-EDIT-03 the %@ in the auth footnote takes the detail page keys row\'s own key', () => {
    const single = row(board(relayProvider()), 'authentication')?.footnote as EditText;
    expect(single).toEqual({ key: 'pages.relayDetail.editBoard.authFootnote', keyValues: { row: 'pages.providerDetail.apiKey' } });
    const multi = row(board(relayProvider({}, {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k2', apiKey: 'sk-second-0123456789' }],
    })), 'authentication')?.footnote as EditText;
    expect(multi).toEqual({ key: 'pages.relayDetail.editBoard.authFootnote', keyValues: { row: 'pages.relayDetail.keysTitle' } });
  });
});

describe('BOARD-EDIT-04 compatibility trimming', () => {
  it.each([
    ['auto', ['stream', 'serviceTier', 'disableResponseStorage']],
    ['openai_responses', ['stream', 'serviceTier', 'disableResponseStorage']],
    ['openai_chat_completions', ['stream', 'serviceTier']],
    ['anthropic_messages', ['stream']],
    ['gemini_generate_content', ['stream']],
  ] as const)('BOARD-EDIT-04 %s', (transport, expected) => {
    const value = board(relayProvider({ transport }));
    expect(rowIDs(value, 'compatibility')).toEqual(expected);
    expect(row(value, 'stream')).toMatchObject({ titleKey: 'pages.relayDetail.editBoard.stream', checked: true });
    if (expected.includes('disableResponseStorage' as never)) {
      expect(row(value, 'disableResponseStorage')).toMatchObject({
        titleKey: 'pages.relayDetail.disableResponseStorage',
        footnote: { key: 'pages.relayDetail.editBoard.storageFootnote' },
      });
    }
  });
});

describe('BOARD-EDIT-05 filled count', () => {
  it('BOARD-EDIT-05 a non-blank UA counts 1, plus headers / query params with non-blank names; not written at 0; collapsed by default regardless of the count', () => {
    const provider = relayProvider();
    expect(group(board(provider), 'headers')?.trailing).toBeUndefined();
    const value = board(provider, {
      customUserAgent: ' Agent ',
      headers: [{ key: 'X-A', value: '1' }, { key: '  ', value: 'blank' }],
      queryParams: [{ key: 'q', value: '' }],
    });
    expect(group(value, 'headers')?.trailing).toEqual({ key: 'pages.relayDetail.editBoard.setCount', values: { count: 3 } });
    expect(group(value, 'headers')?.expanded).toBe(false);
    expect(group(board(provider, { customUserAgent: '   ' }), 'headers')?.trailing).toBeUndefined();
  });
});

describe('BOARD-EDIT-06 action bar', () => {
  it('BOARD-EDIT-06 primary button has two states: if address / default protocol / auth changed it is "Verify and Save", otherwise "Save"', () => {
    const provider = relayProvider();
    expect(board(provider).actionBar.primary).toMatchObject({ titleKey: 'common.save', verifies: false });
    expect(board(provider, { endpoint: 'https://other.example.com/v1' }).actionBar.primary)
      .toMatchObject({ titleKey: 'pages.relayDetail.editBoard.validateAndSave', verifies: true });
    expect(board(provider, { transport: 'openai_responses' }).actionBar.primary.verifies).toBe(true);
    expect(board(provider, { authMode: 'x_api_key' }).actionBar.primary.verifies).toBe(true);
    expect(board(provider, { customUserAgent: 'Agent/2', stream: false }).actionBar.primary.verifies).toBe(false);
  });

  it('BOARD-EDIT-06 a stored relayKind that differs from the one derived from the default protocol, with only the UA changed -> still "Save"', () => {
    const provider = relayProvider({ transport: 'anthropic_messages', authMode: 'x_api_key' }, { relayKind: 'openai_compatible' });
    expect(board(provider, { customUserAgent: 'Agent/2' }).actionBar.primary.titleKey).toBe('common.save');
  });

  it('BOARD-EDIT-06 tappable matrix', () => {
    const provider = relayProvider();
    expect(actions(board(provider))).toEqual([true, true]);
    expect(actions(board(provider, {}, { status: { kind: 'reconnecting' } }))).toEqual([false, false]);
    expect(actions(board(provider, {}, { isSaving: true }))).toEqual([false, false]);
    expect(actions(board(provider, {}, { status: { kind: 'testing' } }))).toEqual([false, true]);
    expect(actions(board(provider, {}, { status: { kind: 'verified' } }))).toEqual([true, true]);
    expect(actions(board(provider, {}, { status: { kind: 'failed', message: 'x' } }))).toEqual([true, true]);
    expect(actions(board(provider, { endpoint: 'http://relay.example.com/v1' }))).toEqual([true, false]);
    // When the model input has no form issues, a blank address disables only Test.
    expect(actions(board(provider, { endpoint: '   ' }, { issues: [] }))).toEqual([false, true]);
  });

  it('BOARD-EDIT-06 real path: an empty address yields a silent required issue via validateRelayForm -> the primary button is also not tappable, and no text is shown', () => {
    const value = board(relayProvider(), { endpoint: '   ' });
    expect(actions(value)).toEqual([false, false]);
    expect(value.groups.flatMap((item) => item.issues)).toEqual([]);
  });
});

describe('BOARD-EDIT-07 no kind layer', () => {
  it('BOARD-EDIT-07 an auto connection and any stored relayKind produce exactly the same groups and rows; changing relayKind on a selected-protocol connection leaves rows unchanged', () => {
    const kinds = ['custom', 'codex_style', 'openai_compatible', 'anthropic_compatible', 'gemini_compatible'] as const;
    const autoBoards = kinds.map((relayKind) => JSON.stringify(board(relayProvider({}, { relayKind })).groups));
    expect(new Set(autoBoards).size).toBe(1);
    const selected = kinds.map((relayKind) => JSON.stringify(board(relayProvider({ transport: 'openai_responses' }, { relayKind })).groups));
    expect(new Set(selected).size).toBe(1);
  });

  it('BOARD-EDIT-07 the row set contains only the rows listed in 01 / 02 / 04', () => {
    const allowed = new Set(['requestURL', 'engineAddress', 'connectionSecurity', 'defaultProtocol', 'authentication', 'channel',
      'userAgent', 'header', 'queryParam', 'addEntry', 'stream', 'serviceTier', 'disableResponseStorage']);
    const value = board(relayProvider({ reasoningEffort: 'high', codexCompatIdentity: true, transportKind: 'openai_chat' }));
    for (const item of value.groups.flatMap((entry) => entry.rows)) expect(allowed.has(item.id)).toBe(true);
    expect(JSON.stringify(value)).not.toMatch(/reasoning|codex|relayType|transportKind|preset/i);
  });
});

describe('BOARD-EDIT-08 save (actual output of the production save path)', () => {
  async function saveThroughStore(provider: Provider, patch: Partial<RelayEditDraft> = {}) {
    const store = createAppStore();
    store.getState().addProvider(provider);
    const draft = { ...relayEditDraftFromProvider(provider), ...patch };
    const normalized = relayFormNormalizedEndpoint(formDraft(provider, draft), 'edit')!;
    await updateProviderRelaySettings(store, provider, relayEditSavePatch(provider, draft, normalized));
    return store.getState().providers[0]!;
  }

  it('BOARD-EDIT-08 relayKind is derived from the default protocol (auto -> custom, protocol still stored as auto), reasoningEffort is cleared', async () => {
    const saved = await saveThroughStore(relayProvider({ reasoningEffort: 'high' }, { relayKind: 'openai_compatible' }));
    expect(saved.relayKind).toBe('custom');
    expect(saved.relayRequested?.transport).toBe('auto');
    expect(saved.relayRequested?.reasoningEffort).toBeUndefined();
    const responses = await saveThroughStore(relayProvider({ transport: 'anthropic_messages' }), { transport: 'openai_responses' });
    expect(responses.relayKind).toBe('codex_style');
  });

  it.each([undefined, true, false])('BOARD-EDIT-08 codexCompatIdentity=%s is kept as is, unaffected by protocol or kind', async (identity) => {
    const saved = await saveThroughStore(relayProvider({ codexCompatIdentity: identity }), { transport: 'openai_responses' });
    expect(saved.relayRequested?.codexCompatIdentity).toBe(identity);
  });

  it('BOARD-EDIT-08 other fields unchanged; a save that changed no field leaves every field unchanged except reasoningEffort', async () => {
    const provider = localProvider('llamacpp', 'tofu_https');
    // A stored connection whose relayKind matches the default protocol (mismatches are covered by the previous assertion).
    const original: Provider = {
      ...provider,
      relayKind: 'openai_compatible',
      relayRequested: {
        ...provider.relayRequested!,
        certificateFingerprint: 'ab:cd',
        imageSize: '1024x1024',
        webSearchToolName: 'web_search_preview',
        transportKind: 'openai_chat',
        resolvedAPIBaseURL: 'https://mac-mini.local:8443/v1',
        resolvedAPIBaseURLs: { openai_responses: 'https://mac-mini.local:8443/v1' },
        reasoningEffort: 'medium',
        stream: true,
      },
      relayResolvedBaseURLText: 'https://mac-mini.local:8443/v1',
      relayResolvedTransport: 'openai_chat_completions',
    };
    const saved = await saveThroughStore(original);
    const { updatedAt: _updatedAt, ...savedRest } = saved;
    const { reasoningEffort: _reasoning, ...requestedRest } = original.relayRequested!;
    expect(savedRest).toEqual({ ...original, relayRequested: requestedRest });
  });
});

describe('BOARD-EDIT-08 save cleanup of header-type fields', () => {
  it('BOARD-EDIT-08 User-Agent is trimmed and cleared if empty; headers / query params are filtered by non-empty name, values are not trimmed', () => {
    const provider = relayProvider();
    const draft = {
      ...relayEditDraftFromProvider(provider),
      customUserAgent: '  Agent/1  ',
      headers: [{ key: ' X-A ', value: ' v ' }, { key: '  ', value: 'drop' }],
      queryParams: [{ key: 'q', value: ' 1 ' }],
    };
    const patch = relayEditSavePatch(provider, draft, 'https://relay.example.com/v1');
    expect(patch.relayRequested.customUserAgent).toBe('Agent/1');
    expect(patch.relayRequested.headers).toEqual([{ key: 'X-A', value: ' v ' }]);
    expect(patch.relayRequested.queryParams).toEqual([{ key: 'q', value: ' 1 ' }]);
    expect(relayEditSavePatch(provider, { ...draft, customUserAgent: '   ' }, 'https://relay.example.com/v1').relayRequested.customUserAgent)
      .toBeUndefined();
  });
});

describe('BOARD-EDIT-09 status row', () => {
  it('BOARD-EDIT-09 reconnecting in flight / testing in flight / verified / failed', () => {
    const provider = relayProvider();
    expect(board(provider, {}, { status: { kind: 'reconnecting' } }).status).toEqual({
      kind: 'reconnecting', text: { key: 'pages.relayDetail.editBoard.reconnecting' }, spinning: true, icon: null, tone: 'progress',
    });
    expect(board(provider, {}, { status: { kind: 'testing' } }).status).toMatchObject({
      text: { key: 'pages.relayDetail.testingRelay' }, spinning: true, icon: null,
    });
    expect(board(provider, {}, { status: { kind: 'verified' } }).status).toMatchObject({
      text: { key: 'pages.relayDetail.editBoard.verified' }, spinning: false, icon: 'check-circle', tone: 'success',
    });
    expect(board(provider, {}, { status: { kind: 'failed', message: 'HTTP 401' } }).status).toMatchObject({
      text: { literal: 'HTTP 401' }, icon: 'warning', tone: 'warning',
    });
    expect(board(provider).status).toBeNull();
  });
});

describe('BOARD-EDIT-10 copy complete in all 16 languages', () => {
  const locales = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
  const messages = Object.fromEntries(locales.map((locale) => [
    locale,
    JSON.parse(readFileSync(resolve(process.cwd(), `messages/${locale}.json`), 'utf8')) as Record<string, unknown>,
  ]));
  const lookup = (locale: string, key: string) => key.split('.').reduce<unknown>(
    (node, segment) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[segment] : undefined),
    messages[locale],
  );

  function collectKeys(value: RelayEditBoard): string[] {
    const keys: string[] = [value.titleKey, value.actionBar.test.titleKey, value.actionBar.primary.titleKey];
    const addText = (text: EditText | undefined) => {
      if (!text || 'literal' in text) return;
      keys.push(text.key);
      if ('keyValues' in text) keys.push(...Object.values(text.keyValues));
    };
    for (const item of value.groups) {
      keys.push(item.titleKey);
      addText(item.trailing);
      for (const entry of item.rows) {
        keys.push(entry.titleKey);
        addText(entry.value);
        addText(entry.footnote);
        entry.options?.forEach((option) => addText(option.label));
      }
    }
    if (value.status) addText(value.status.text);
    return keys;
  }

  it('BOARD-EDIT-10 every key output by the model and the action bar (including the two primary-button states and the status row) has a value in all 16 languages', () => {
    const relay = relayProvider({ customUserAgent: 'A', headers: [{ key: 'X', value: '1' }], queryParams: [{ key: 'q', value: '1' }] });
    const statuses: RelayEditStatus[] = [{ kind: 'reconnecting' }, { kind: 'testing' }, { kind: 'verified' }];
    const keys = new Set([
      ...collectKeys(board(relay)),
      ...collectKeys(board(relay, { endpoint: 'https://other.example.com', transport: 'openai_chat_completions' })),
      ...statuses.flatMap((status) => collectKeys(board(relay, {}, { status }))),
      ...collectKeys(board(localProvider('llamacpp', 'tofu_https'))),
      ...Object.values(RELAY_EDIT_TEXT),
    ]);
    const missing = [...keys].flatMap((key) => locales
      .filter((locale) => typeof lookup(locale, key) !== 'string' || (lookup(locale, key) as string).length === 0)
      .map((locale) => `${locale} ${key}`));
    expect(missing).toEqual([]);
  });

  it('BOARD-EDIT-10 existing bug 1: the generic Save is not English in 15 languages', () => {
    const english = locales.filter((locale) => locale !== 'en' && lookup(locale, 'common.save') === 'Save');
    expect(english).toEqual([]);
    expect(lookup('vi', 'common.save')).toBe('Lưu');
  });
});

describe('BOARD-EDIT-11 whether the address changed is compared after normalization', () => {
  it('BOARD-EDIT-11 differing only by scheme / leading or trailing whitespace / trailing slash -> save without verification; a real change verifies and saves', () => {
    const provider = relayProvider();
    for (const endpoint of ['relay.example.com/v1', '  https://relay.example.com/v1/  ', 'https://relay.example.com/v1///']) {
      const value = board(provider, { endpoint });
      expect(value.actionBar.primary.titleKey).toBe('common.save');
      const normalized = relayFormNormalizedEndpoint(formDraft(provider, { ...relayEditDraftFromProvider(provider), endpoint }), 'edit')!;
      const patch = relayEditSavePatch(provider, { ...relayEditDraftFromProvider(provider), endpoint }, normalized);
      // Same answer on the save path: no verification, the address in the store is left as typed.
      expect(planRelaySettingsSave(provider, buildRelaySettingsCandidate(provider, patch)).needsVerification).toBe(false);
      // Even when judged "unchanged", the normalized draft address is stored and the probed root URL is kept.
      expect(patch.baseURLText).toBe(normalized);
    }
    expect(board(provider, { endpoint: 'https://relay.example.com/v2' }).actionBar.primary.titleKey)
      .toBe('pages.relayDetail.editBoard.validateAndSave');
  });

  it('BOARD-EDIT-11 an explicit scheme is kept: swapping http <-> https counts as "changed", sends verification and clears the root', () => {
    const provider = relayProvider({ resolvedAPIBaseURL: 'https://relay.example.com/v1' });
    const draft = { ...relayEditDraftFromProvider(provider), endpoint: 'http://relay.example.com/v1' };
    const patch = relayEditSavePatch(provider, draft, 'http://relay.example.com/v1');
    expect(planRelaySettingsSave(provider, buildRelaySettingsCandidate(provider, patch)).needsVerification).toBe(true);
    expect(patch.relayRequested.resolvedAPIBaseURL).toBeUndefined();
    expect(relayEditDraftMatchesSaved(provider, draft)).toBe(false);
    const local = localProvider('ollama');
    const localDraft = { ...relayEditDraftFromProvider(local), endpoint: 'https://192.168.1.20:8080' };
    expect(relayEditDraftMatchesSaved(local, localDraft)).toBe(false);
    // A missing scheme is filled in by connection security: a plaintext connection gets http, which counts as the same as the http address in the store.
    expect(relayEditDraftMatchesSaved(local, { ...localDraft, endpoint: '192.168.1.20:8080/' })).toBe(true);
  });

  it('BOARD-EDIT-11 a stored connection (address in the store has a trailing slash) and an untouched local connection show "Save"', () => {
    expect(board(relayProvider({}, { baseURLText: 'https://relay.example.com/v1/' })).actionBar.primary.titleKey).toBe('common.save');
    expect(board(localProvider('llamacpp')).actionBar.primary.titleKey).toBe('common.save');
    expect(relayEditNeedsVerification(localProvider('lmstudio'), relayEditDraftFromProvider(localProvider('lmstudio')), null)).toBe(false);
  });
});

describe('BOARD-EDIT-12 validation hints placement', () => {
  it('BOARD-EDIT-12 a "filled in but wrong" header shows in the headers group and expands a collapsed group; the primary button is not tappable', () => {
    const provider = relayProvider({ securityMode: 'local_http', authMode: 'none' }, {
      apiKey: '', apiKeyPreview: '', baseURLText: 'http://192.168.1.20:8080/v1',
    });
    const value = board(provider, { headers: [{ key: 'Authorization', value: 'Bearer x' }] }, { groupChoice: { headers: false } });
    expect(group(value, 'headers')).toMatchObject({ expanded: true, forcedOpen: true });
    expect(group(value, 'headers')?.issues.map((issue) => issue.field)).toEqual(['headers']);
    expect(group(value, 'connection')?.issues).toEqual([]);
    expect(value.actionBar.primary.enabled).toBe(false);
  });

  it('BOARD-EDIT-12 required-type issues show no text; the address hint stays under the connection card; with no headers group (local plaintext) the hint also stays under the connection card', () => {
    const missingKey = board(relayProvider({}, { apiKey: '', apiKeyPreview: '' }));
    expect(missingKey.groups.flatMap((item) => item.issues)).toEqual([]);
    const badAddress = board(relayProvider(), { endpoint: 'http://relay.example.com/v1' });
    expect(group(badAddress, 'connection')?.issues.length).toBeGreaterThan(0);
    const local = board(localProvider('ollama'), { headers: [{ key: 'Authorization', value: 'x' }] });
    expect(group(local, 'headers')).toBeUndefined();
    expect(group(local, 'connection')?.issues.map((issue) => issue.field)).toEqual(['headers']);
  });

  it('BOARD-EDIT-12 production component: the hint appears below the last row of that field', () => {
    const provider = relayProvider({ securityMode: 'local_http', authMode: 'none' }, {
      apiKey: '', apiKeyPreview: '', baseURLText: 'http://192.168.1.20:8080/v1',
    });
    const draft = { ...relayEditDraftFromProvider(provider), headers: [{ key: 'X-A', value: '1' }, { key: 'Authorization', value: 'x' }] };
    renderBoard(board(provider, draft), draft);
    const blocks = [...document.querySelectorAll('[data-edit-row="header"]')].map((node) => node.parentElement!);
    expect(blocks[0]!.querySelector('[data-issue-field]')).toBeNull();
    expect(blocks[1]!.querySelector('[data-issue-field="headers"]')?.textContent).toBe('issue:headers:cleartext_credentials');
  });
});

describe('BOARD-EDIT-13 probed root URL', () => {
  const roots = { resolvedAPIBaseURL: 'https://relay.example.com/v1', resolvedAPIBaseURLs: { openai_responses: 'https://relay.example.com/v1' } };
  it('BOARD-EDIT-13 kept if unchanged after normalization; cleared only if truly changed', () => {
    const provider = relayProvider(roots);
    const draft = relayEditDraftFromProvider(provider);
    expect(relayEditSavePatch(provider, { ...draft, endpoint: 'relay.example.com/v1/' }, 'https://relay.example.com/v1').relayRequested)
      .toMatchObject(roots);
    const changed = relayEditSavePatch(provider, { ...draft, endpoint: 'https://new.example.com/v1' }, 'https://new.example.com/v1').relayRequested;
    expect(changed.resolvedAPIBaseURL).toBeUndefined();
    expect(changed.resolvedAPIBaseURLs).toBeUndefined();
  });

  it('BOARD-EDIT-13 local localhost / *.local hostnames are kept as well', () => {
    for (const host of ['http://localhost:11434', 'http://mac-mini.local:8080']) {
      const provider = { ...localProvider('ollama'), baseURLText: host, relayRequested: { ...localProvider('ollama').relayRequested!, resolvedAPIBaseURL: `${host}/v1` } };
      const patch = relayEditSavePatch(provider, { ...relayEditDraftFromProvider(provider), endpoint: `${host}/` }, host);
      expect(patch.relayRequested.resolvedAPIBaseURL).toBe(`${host}/v1`);
      expect(patch.baseURLText).toBe(host);
    }
  });
});

describe('BOARD-EDIT-14 / 16 reveal of the status row and the failure card', () => {
  const testing: RelayEditStatus = { kind: 'testing' };
  const reconnecting: RelayEditStatus = { kind: 'reconnecting' };
  const verified: RelayEditStatus = { kind: 'verified' };
  const failed: RelayEditStatus = { kind: 'failed', message: 'x' };

  it('BOARD-EDIT-14 reveal on appearance: nil->testing yes; verified->verified, failed->nil no', () => {
    expect(relayEditRevealsStatus(null, testing)).toBe(true);
    expect(relayEditRevealsStatus(verified, verified)).toBe(false);
    expect(relayEditRevealsStatus(failed, null)).toBe(false);
  });

  it('BOARD-EDIT-16 the in-flight one replaced in place by its result is not revealed; the one that appears only after a tap is revealed as before', () => {
    for (const [previous, next] of [[testing, verified], [testing, failed], [reconnecting, verified], [reconnecting, failed]] as const) {
      expect(relayEditRevealsStatus(previous, next)).toBe(false);
    }
    for (const [previous, next] of [[null, testing], [verified, testing], [failed, testing], [null, failed], [null, reconnecting]] as const) {
      expect(relayEditRevealsStatus(previous, next)).toBe(true);
    }
    expect(relayEditRevealsStatus(verified, null)).toBe(false);
    expect(relayEditRevealsStatus(testing, testing)).toBe(false);
  });

  it('BOARD-EDIT-16 production component: nil->testing dismisses the keyboard and scrolls to it, testing->verified does not move', () => {
    const provider = relayProvider();
    const draft = relayEditDraftFromProvider(provider);
    const scroll = vi.fn();
    Element.prototype.scrollIntoView = scroll;
    const view = renderBoard(board(provider), draft, null);
    const input = screen.getByLabelText('pages.relayDetail.endpoint') as HTMLInputElement;
    input.focus();
    view.rerender(
      <RelayEditConnection
        board={board(provider, {}, { status: testing })} draft={draft} status={testing} locked={false} endpointRevealVersion={0}
        issueMessage={() => ''} onDraftChange={vi.fn()} onToggleGroup={vi.fn()} renderSecurityControl={() => null}
        onTest={vi.fn()} onPrimary={vi.fn()} onClose={vi.fn()} failureCard={null} showDiscardConfirm={false}
        onKeepEditing={vi.fn()} onDiscard={vi.fn()}
      />,
    );
    expect(scroll).toHaveBeenCalledTimes(1);
    expect(document.activeElement).not.toBe(input);
    input.focus();
    view.rerender(
      <RelayEditConnection
        board={board(provider, {}, { status: verified })} draft={draft} status={verified} locked={false} endpointRevealVersion={0}
        issueMessage={() => ''} onDraftChange={vi.fn()} onToggleGroup={vi.fn()} renderSecurityControl={() => null}
        onTest={vi.fn()} onPrimary={vi.fn()} onClose={vi.fn()} failureCard={null} showDiscardConfirm={false}
        onKeepEditing={vi.fn()} onDiscard={vi.fn()}
      />,
    );
    expect(scroll).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(input);
  });
});

describe('BOARD-EDIT-15 compatibility items shown while in effect', () => {
  it('BOARD-EDIT-15 items turned on in the store or draft are shown even outside the trim, can be turned off / cleared; once no longer in effect after save, trimmed per 04', () => {
    const stored = relayProvider({ transport: 'anthropic_messages', disableResponseStorage: true });
    expect(rowIDs(board(stored), 'compatibility')).toEqual(['stream', 'disableResponseStorage']);
    expect(rowIDs(board(relayProvider({ transport: 'gemini_generate_content' }), { serviceTier: 'flex' }), 'compatibility'))
      .toEqual(['stream', 'serviceTier']);
    const savedOff = relayProvider({ transport: 'anthropic_messages', disableResponseStorage: undefined });
    expect(rowIDs(board(savedOff), 'compatibility')).toEqual(['stream']);
  });
});

describe('BOARD-EDIT-17 collapsed group expanded by a validation hint', () => {
  it('BOARD-EDIT-17 while expanded by the hint, tapping the group header is recorded as expanded; without a hint it toggles as usual', () => {
    expect(relayEditNextGroupChoice({ expanded: true, forcedOpen: true })).toBe(true);
    expect(relayEditNextGroupChoice({ expanded: true, forcedOpen: false })).toBe(false);
    expect(relayEditNextGroupChoice({ expanded: false, forcedOpen: false })).toBe(true);
    // After the fix it stays expanded: the choice has been recorded as expanded.
    const fixed = board(relayProvider(), {}, { groupChoice: { headers: relayEditNextGroupChoice({ expanded: true, forcedOpen: true }) } });
    expect(group(fixed, 'headers')).toMatchObject({ expanded: true, forcedOpen: false });
  });

  it('BOARD-EDIT-17 production component: tapping a group header passes the current group to the parent', () => {
    const provider = relayProvider();
    const onToggle = vi.fn();
    const value = board(provider);
    render(
      <RelayEditConnection
        board={value} draft={relayEditDraftFromProvider(provider)} status={null} locked={false} endpointRevealVersion={0}
        issueMessage={() => ''} onDraftChange={vi.fn()} onToggleGroup={onToggle} renderSecurityControl={() => null}
        onTest={vi.fn()} onPrimary={vi.fn()} onClose={vi.fn()} failureCard={null} showDiscardConfirm={false}
        onKeepEditing={vi.fn()} onDiscard={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /sectionHeadersQuery/ }));
    expect(onToggle).toHaveBeenCalledWith(expect.objectContaining({ id: 'headers', expanded: false, forcedOpen: false }));
  });
});

describe('BOARD-EDIT-18 compatibility rows opened this session', () => {
  it('BOARD-EDIT-18 still shown after the draft is turned off / cleared; protocol-switch trimming applies only to rows that never appeared', () => {
    const provider = relayProvider({ transport: 'openai_responses' });
    const shown = new Set<EditCompatRowID>([
      ...relayEditActiveCompatRows({ serviceTier: 'flex' }),
      ...relayEditActiveCompatRows({ disableResponseStorage: true }),
    ]);
    expect([...shown]).toEqual(['serviceTier', 'disableResponseStorage']);
    // After the draft is cleared and switched to Messages: both rows are still there.
    const value = board(provider, { transport: 'anthropic_messages', serviceTier: '', disableResponseStorage: false }, { shownCompatRows: shown });
    expect(rowIDs(value, 'compatibility')).toEqual(['stream', 'serviceTier', 'disableResponseStorage']);
    // Only service tier was opened: the do-not-retain-response row is trimmed by protocol.
    const partial = board(provider, { transport: 'anthropic_messages' }, { shownCompatRows: new Set(['serviceTier']) });
    expect(rowIDs(partial, 'compatibility')).toEqual(['stream', 'serviceTier']);
  });

  it('BOARD-EDIT-18 leaving the page resets: the reopened draft equals the stored connection', () => {
    const provider = relayProvider();
    expect(relayEditDraftMatchesSaved(provider, relayEditDraftFromProvider(provider))).toBe(true);
    expect(relayEditDraftMatchesSaved(provider, { ...relayEditDraftFromProvider(provider), serviceTier: 'flex' })).toBe(false);
  });
});

describe('BOARD-EDIT-11 primary-button criterion = merged into the live record vs the live record', () => {
  function boardOver(baseline: Provider, live: Provider, patch: Partial<RelayEditDraft> = {}): RelayEditBoard {
    const draft = { ...relayEditDraftFromProvider(baseline), ...patch };
    const form = formDraft(live, draft);
    return relayEditBoard({
      provider: live,
      baseline,
      displayName: live.customName ?? '',
      draft,
      status: null,
      isSaving: false,
      issues: validateRelayForm(form, 'edit'),
      normalizedEndpoint: relayFormNormalizedEndpoint(form, 'edit'),
      shownCompatRows: new Set(),
      groupChoice: {},
    });
  }

  it('BOARD-EDIT-11 auth mode changed elsewhere after the page opened, user did not change it -> still "Save", not "Verify and Save" because the draft holds the stale value', () => {
    const baseline = relayProvider();
    const live = relayProvider({ authMode: 'x_api_key' });
    expect(boardOver(baseline, live).actionBar.primary.titleKey).toBe('common.save');
  });

  it('BOARD-EDIT-11 user changed the address -> "Verify and Save"; user changed it to the same value as the live record -> "Save"', () => {
    const baseline = relayProvider();
    const live = relayProvider({ authMode: 'x_api_key' });
    expect(boardOver(baseline, live, { endpoint: 'https://other.example.com/v1' }).actionBar.primary.titleKey)
      .toBe(RELAY_EDIT_TEXT.validateAndSave);
    expect(boardOver(baseline, live, { authMode: 'x_api_key' }).actionBar.primary.titleKey).toBe('common.save');
  });
});

describe('Edit page: only a key-status change or a single materialization -> not counted as a verification-relevant change', () => {
  it('single materialization and status change add no verification; the primary button is still "Save"', () => {
    const stored = relayProvider();
    const draft = relayEditDraftFromProvider(stored);
    const materialized = { ...stored, relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'ok' as const, checkedAt: '2026-10-13T00:00:00.000Z' } }] };
    const flipped = { ...materialized, relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'invalid' as const, httpStatus: 401 } }] };
    for (const live of [materialized, flipped]) {
      // During verification / after the edit page opened, a real request wrote status into the store: the draft is compared against the same record.
      expect(planRelaySettingsSave(stored, live).needsVerification).toBe(false);
      const normalized = relayFormNormalizedEndpoint(formDraft(live, draft), 'edit');
      // The record when the edit page opened (stored) is the baseline; live is the live record at the moment of persistence.
      expect(relayEditNeedsVerification(live, draft, normalized, stored)).toBe(false);
      const patch = relayEditSavePatch(live, draft, normalized!);
      expect(planRelaySettingsSave(live, buildRelaySettingsCandidate(live, patch)).needsVerification).toBe(false);
    }
  });
});
