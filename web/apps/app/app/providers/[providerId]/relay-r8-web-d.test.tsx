import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { IntlMessageFormat } from 'intl-messageformat';
import { fireEvent, render } from '@testing-library/react';
import { WarningIcon } from '@phosphor-icons/react';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { makeRelayRequested } from '@oriveo/shared';
import { toProviderError } from '@oriveo/core/providers/errors';
import { validateRelayForm, relayFormNormalizedEndpoint } from '@oriveo/core/providers/relay-form-validation';
import { RelayCatalogKeyStrip } from './components/RelayCatalogParts';
import { RelayKeyRowView } from './components/RelayKeysPage';
import { RelaySettingsFailureCard } from './components/RelaySettingsFailureCard';
import { RelayEditConnection } from './components/RelayEditConnection';
import { relayEditBoard, relayEditDraftFromProvider } from './relay-edit-board';
import { RelayDetail } from './RelayDetail';

/**
 * Column-split algorithm of RL2-LAYOUT-ROW-08 / ROW-03, structure of the RL2-EDITFAIL-03 failure card,
 * RL2-EDITFAIL-04 edit panel title bar and action bar fixed at phone width, RL2-DIGITS-01 Latin digits for ar.
 */

const ROOT = process.cwd();
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');
const loadMessages = (locale: string) => JSON.parse(read(`messages/${locale}.json`)) as Record<string, unknown>;
const EN = loadMessages('en');
const lookup = (messages: Record<string, unknown>, dotted: string): unknown =>
  dotted.split('.').reduce<unknown>((node, part) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[part] : undefined), messages);
/** Get the body of the first standalone rule for a selector in a stylesheet (the selector is on its own line). */
const cssRule = (css: string, selector: string) =>
  new RegExp(`(^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^{}]*)\\}`).exec(css)?.[2] ?? '';
/** Get the content of an @media block. */
const mediaBlock = (css: string, query: string) => {
  const start = css.indexOf(`@media ${query} {`);
  if (start < 0) return '';
  let depth = 0;
  for (let i = css.indexOf('{', start); i < css.length; i += 1) {
    if (css[i] === '{') depth += 1;
    else if (css[i] === '}' && (depth -= 1) === 0) return css.slice(start, i + 1);
  }
  return '';
};

// Real en copy: what the component receives is the sentence from the production copy resources.
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => {
    const value = lookup(EN, namespace ? `${namespace}.${key}` : key);
    if (typeof value !== 'string') return key;
    return values ? String(new IntlMessageFormat(value, 'en').format(values)) : value;
  },
  useLocale: () => 'en',
}));

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn(), back: vi.fn(), replace: vi.fn() }),
}));

vi.mock('../../../lib/hooks/useProviderActions', () => ({
  useProviderActions: () => ({
    isSyncing: false,
    catalogLoadState: 'loaded',
    relaySettingsSaveFailure: null,
    saveKey: vi.fn(),
    removeKey: vi.fn(),
    clearRelayCredentials: vi.fn(),
    reconnectRelaySecurityMode: vi.fn(),
    verifyRelayConnection: vi.fn(),
    saveBaseURL: vi.fn(),
    writeBackBaseURL: vi.fn(),
    saveName: vi.fn(),
    saveRelaySettings: vi.fn(),
    relaySettingsSavePlan: () => ({ needsVerification: false, needsCatalogRefresh: false }),
    saveRelaySettingsUnverified: vi.fn(),
    retryRelaySettingsSave: vi.fn(),
    clearRelaySettingsSaveFailure: vi.fn(),
    refreshRelayCatalog: vi.fn(),
    addModels: vi.fn(),
    toggleModel: vi.fn(),
    removeModel: vi.fn(),
    deleteProvider: vi.fn(),
  }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: Record<string, unknown>) => unknown) =>
    selector({ setLastUsedModelRef: vi.fn(), setActiveConversationId: vi.fn() }),
  getVanillaStore: () => ({ getState: () => ({ providers: [] }) }),
}));

vi.mock('../../../components/Toast', () => ({ showToast: vi.fn() }));

const CATALOG_CSS = 'app/providers/[providerId]/components/RelayCatalogParts.module.css';
const BOARD_CSS = 'app/providers/[providerId]/components/RelayDetailBoard.module.css';
const DETAIL_CSS = 'app/providers/[providerId]/ProviderDetail.module.css';
const EDIT_CSS = 'app/providers/[providerId]/components/RelayEditConnection.module.css';

describe('RL2-LAYOUT-ROW-08 / ROW-03 column-split algorithm = iOS RelayMenuRowColumns.columnWidths', () => {
  it('RL2-LAYOUT-ROW-08 key bar: total = after the key icon, before Retry; status column = min(single-line ideal width, total x 50%), the left column takes the remainder', () => {
    const { container } = render(
      <RelayCatalogKeyStrip
        items={[
          { id: 'k1', title: 'Main', catalogCount: 4, state: 'ok', statusKey: null, retry: false },
          { id: 'k3', title: 'sk-r…51Lx', catalogCount: 2, state: 'failed', httpStatus: 429, statusKey: 'pages.relayDetail.keyStatus.limited', retry: true },
        ]}
        onRetry={() => undefined}
      />,
    );
    const items = [...container.querySelectorAll('[data-key-strip-item]')];
    expect(items).toHaveLength(2);
    for (const item of items) {
      // Split area = name column + status column; the icon is before it and Retry after it (neither counts toward total).
      const columns = item.querySelector('[data-key-strip-columns]')!;
      expect(columns).toBeTruthy();
      expect(columns.parentElement).toBe(item);
      const leadColumn = columns.querySelector('[data-key-strip-lead]')!;
      const status = columns.querySelector('[data-key-strip-status]')!;
      expect([...columns.children]).toEqual([leadColumn, status]);
      expect(item.firstElementChild!.tagName.toLowerCase()).toBe('svg');
      const retry = item.querySelector('[data-key-strip-retry]');
      if (retry) {
        expect(retry.parentElement).toBe(item);
        expect(item.lastElementChild).toBe(retry);
      }
    }
    expect(items[1]!.querySelector('[data-key-strip-meta]')!.textContent).toBe('Catalog: 2 models');

    const css = read(CATALOG_CSS);
    const columnsRule = cssRule(css, '.keyStripColumns');
    expect(columnsRule).toMatch(/display:\s*flex/);
    expect(columnsRule).toMatch(/flex:\s*1 1 0/);
    expect(columnsRule).toMatch(/min-width:\s*0/);
    // Status column: flex basis = content (single-line ideal width), cap = 50% of the split area, no longer squeezed by the left column.
    const statusRule = cssRule(css, '.keyStripStatus');
    expect(statusRule).toMatch(/flex:\s*0 0 auto/);
    expect(statusRule).toMatch(/max-width:\s*50%/);
    expect(statusRule).toMatch(/-webkit-line-clamp:\s*2/);
    // The left column takes the remainder (basis 0); the name never gets zero width, guaranteed by min-width 0 + ellipsis.
    const leadRule = cssRule(css, '.keyStripLead');
    expect(leadRule).toMatch(/flex:\s*1 1 0/);
    expect(leadRule).toMatch(/min-width:\s*0/);
  });

  it('RL2-LAYOUT-ROW-03 key row uses the same algorithm: total excludes the row-end chevron; status column <= 50% of the split area', () => {
    const { container } = render(
      <RelayKeyRowView
        element="button"
        data={{
          title: 'Backup',
          primaryBadge: false,
          primaryBadgeText: 'Primary',
          preview: 'sk-s…6789',
          catalog: 'Catalog: 4 models',
          statusText: 'Out of credit or rate-limited',
          statusMark: 'warning',
        }}
      />,
    );
    const row = container.querySelector('[data-relay-key-row]')!;
    const inner = row.firstElementChild!;
    const columns = inner.querySelector('[data-row-columns]')!;
    expect(columns).toBeTruthy();
    expect(columns.parentElement).toBe(inner);
    expect([...columns.children]).toEqual([columns.querySelector('[data-row-lead]'), columns.querySelector('[data-row-trailing]')]);
    // The row-end chevron is outside the split area.
    const chevron = inner.lastElementChild!;
    expect(chevron.tagName.toLowerCase()).toBe('svg');
    expect(columns.contains(chevron)).toBe(false);

    const css = read(BOARD_CSS);
    const columnsRule = cssRule(css, '.keyColumns');
    expect(columnsRule).toMatch(/display:\s*flex/);
    expect(columnsRule).toMatch(/flex:\s*1 1 0/);
    expect(columnsRule).toMatch(/min-width:\s*0/);
    expect(cssRule(css, '.keyTrailing')).toMatch(/max-width:\s*50%/);
  });
});

const KEY = 'sk-relay-secret-0123456789';
const requested = makeRelayRequested('openai_compatible');

describe('RL2-EDITFAIL-03 failure card structure', () => {
  it('warning triangle mark + kind title -> body -> full-width primary button -> Technical details below the primary button', () => {
    const error = toProviderError(401, '{"error":{"message":"Invalid API key provided."}}', 'https://api.relay-demo.example/v1/responses');
    const { container } = render(
      <RelaySettingsFailureCard
        error={error}
        canSaveUnverified
        apiKey={KEY}
        connectionKeySecrets={[KEY]}
        relayRequested={requested}
        showRetry={false}
        onRetry={() => undefined}
        onSaveUnverified={() => undefined}
      />,
    );
    const card = container.querySelector('[role="alert"]')!;
    // Mark = this platform's warning triangle (verbatim identical to the production rendering of the same icon).
    const mark = card.querySelector('svg')!;
    const triangle = render(<WarningIcon size={22} weight="fill" aria-hidden="true" />).container.querySelector('svg')!;
    expect(mark.innerHTML).toBe(triangle.innerHTML);
    expect(card.textContent).toContain('Invalid API Key');

    const button = [...card.querySelectorAll('button')].find((node) => node.textContent === 'Save anyway (unverified)')!;
    expect(button).toBeTruthy();
    // Full-width primary button: same component and size as this platform's full-width Save (Button primary, default md), full row.
    expect(button.className).toMatch(/primary/);
    expect(button.className).toMatch(/\bmd\b/);
    expect(button.className).not.toMatch(/\bsm\b/);
    expect(button.className).toMatch(/relayFailurePrimary/);
    expect(cssRule(read(DETAIL_CSS), '.relayFailurePrimary')).toMatch(/width:\s*100%/);
    expect(cssRule(read(DETAIL_CSS), '.relayFailureActions')).toMatch(/flex-direction:\s*column/);

    const details = card.querySelector('details');
    if (details) {
      expect(Boolean(button.compareDocumentPosition(details) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
    }
  });
});

function relayProvider(): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'Demo Relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: KEY,
    apiKeyPreview: '',
    baseURLText: 'https://api.relay-demo.example',
    relayKind: 'openai_compatible',
    relayRequested: requested,
  };
}

describe('RL2-EDITFAIL-04 edit panel at phone width: title bar and bottom action bar fixed, only the middle scrolls', () => {
  it('structure = title bar / middle scroll area (groups, status, failure card) / action bar; at phone width the whole panel is a fixed viewport and the middle is overflow:auto', () => {
    const provider = relayProvider();
    const draft = relayEditDraftFromProvider(provider);
    const form = {
      endpoint: draft.endpoint,
      apiKey: '',
      authMode: draft.authMode,
      securityMode: 'remote_https' as const,
      transport: draft.transport,
      modelID: '',
      headers: draft.headers,
      queryParams: draft.queryParams,
      hasSavedCredential: true,
    };
    const board = relayEditBoard({
      provider,
      displayName: 'Demo Relay',
      draft,
      status: null,
      isSaving: false,
      issues: validateRelayForm(form, 'edit'),
      normalizedEndpoint: relayFormNormalizedEndpoint(form, 'edit'),
      shownCompatRows: new Set(),
      groupChoice: {},
    });
    const { container } = render(
      <RelayEditConnection
        board={board}
        draft={draft}
        status={null}
        locked={false}
        endpointRevealVersion={0}
        issueMessage={() => ''}
        onDraftChange={() => undefined}
        onToggleGroup={() => undefined}
        renderSecurityControl={() => null}
        onTest={() => undefined}
        onPrimary={() => undefined}
        onClose={() => undefined}
        failureCard={<div data-testid="failure-card" />}
        showDiscardConfirm={false}
        onKeepEditing={() => undefined}
        onDiscard={() => undefined}
      />,
    );
    const page = container.querySelector('[data-edit-form]')!;
    const [header, body, actionBar] = [...page.children];
    expect(header!.tagName.toLowerCase()).toBe('header');
    expect(body!.hasAttribute('data-edit-body')).toBe(true);
    expect(body!.querySelectorAll('[data-edit-group]').length).toBe(board.groups.length);
    expect(body!.querySelector('[data-testid="failure-card"]')).toBeTruthy();
    expect(actionBar!.querySelector('[data-edit-action="test"]')).toBeTruthy();
    expect(actionBar!.querySelector('[data-edit-action="primary"]')).toBeTruthy();

    const mobile = mediaBlock(read(EDIT_CSS), '(max-width: 767px)');
    const pageRule = cssRule(mobile, '.page');
    expect(pageRule).toMatch(/position:\s*fixed/);
    expect(pageRule).toMatch(/inset:\s*0/);
    expect(pageRule).toMatch(/flex-direction:\s*column/);
    const bodyRule = cssRule(mobile, '.body');
    expect(bodyRule).toMatch(/flex:\s*1 1 auto/);
    expect(bodyRule).toMatch(/min-height:\s*0/);
    expect(bodyRule).toMatch(/overflow-y:\s*auto/);
    expect(cssRule(mobile, '.header')).toMatch(/flex:\s*none/);
    expect(cssRule(mobile, '.page > .actionBar')).toMatch(/flex:\s*none/);
  });
});

describe('RL2-DIGITS-01 count copy shows Latin digits under ar', () => {
  it('ar modelsCount 5 -> "5 نماذج" (Latin 5, not ٥); Intl ar defaults to latn', () => {
    const ar = loadMessages('ar');
    const format = new IntlMessageFormat(lookup(ar, 'pages.relayDetail.modelsCount') as string, 'ar');
    const text = String(format.format({ count: 5 }));
    expect(text).toBe('5 نماذج');
    expect(text).not.toMatch(/[\u0660-\u0669]/);
    expect(new Intl.NumberFormat('ar').format(1234567890)).toMatch(/^[0-9,.\u066C\u066B\u060C ]+$/);
  });
});

describe('RL2-LAYOUT-ROW-02 enabled rows: the Enabled section needs only one layer of card, buttons 36, status <= 84', () => {
  function model(id: string): AIModel {
    return { id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '' };
  }

  it('the Enabled section\'s outer layer is no longer a card (only the inner list card remains); the chat / ... buttons are 36 circles, and the .modelChatBtn shared with official providers is untouched', () => {
    const provider = { ...relayProvider(), models: [model('claude-sonnet-5-extended-thinking-preview-20261001')] };
    provider.catalogModels = provider.models;
    render(<RelayDetail provider={provider} />);
    fireEvent.click(document.querySelector('[data-board-row="modelLibrary"]') as HTMLElement);
    const section = document.querySelector('[data-catalog-section="enabled"]')!;
    expect(section).toBeTruthy();
    expect(section.className).toMatch(/enabledSection/);
    // The inner list card is still there and is the only card in this section.
    expect(section.querySelector('[data-catalog-row]')!.parentElement!.className).toMatch(/modelList/);
    const trailing = section.querySelector('[data-row-trailing]')!;
    const buttons = [...trailing.querySelectorAll('button')];
    expect(buttons.length).toBe(2);
    for (const button of buttons) expect(button.className).toMatch(/trailingButton/);

    const css = read(CATALOG_CSS);
    const sectionRule = cssRule(css, '.enabledSection[data-catalog-section]');
    expect(sectionRule).toMatch(/padding:\s*0/);
    expect(sectionRule).toMatch(/border:\s*0/);
    expect(sectionRule).toMatch(/background:\s*transparent/);
    expect(sectionRule).toMatch(/box-shadow:\s*none/);
    const buttonRule = cssRule(css, '.enabledTrailing .trailingButton');
    expect(buttonRule).toMatch(/width:\s*36px/);
    expect(buttonRule).toMatch(/height:\s*36px/);
    expect(cssRule(css, '.status')).toMatch(/max-width:\s*84px/);
    expect(cssRule(css, '.rowName')).toMatch(/overflow-wrap:\s*anywhere/);
    expect(cssRule(read(DETAIL_CSS), '.modelChatBtn')).toMatch(/width:\s*32px/);
  });
});
