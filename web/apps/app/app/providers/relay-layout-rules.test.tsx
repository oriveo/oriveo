import 'fake-indexeddb/auto';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import type { RelayDiscoveryResult } from '../../lib/core/providers/probe/probe-runner';
import { RelayDetail } from './[providerId]/RelayDetail';
import { RelayEditGroupView } from './[providerId]/components/RelayEditConnection';
import { RelayDetectionChecklist } from './relay/new/RelaySetupStepOne';
import { initialManualSetupDraft, manualSetupBoard } from './relay/new/manual-setup-board';
import {
  relayStepOneAfterCatalog,
  relayStepOneAfterDiscovery,
  relayStepOneAfterProtocols,
  startRelayStepOne,
} from './relay/new/relay-setup-two-step';

/**
 * Layout gate (RL2-LAYOUT-TRAILING-01/02, ROW-01 to 05): the in-row layout of the relay family follows iOS.
 *
 * CSS convention: a rule that aligns the whole row is preceded by an anchor comment `/* <page name>: whole row vertically centered *\/`; the rule right after it must have `align-items: center` and no `flex-start`.
 * DOM convention (asserted after the production component renders): a row's left column is marked `data-row-lead` and its trailing column `data-row-trailing`;
 * the key-row component root is marked `data-relay-key-row`, with its mask `data-row-mask` and status text `data-row-status`.
 */

const ROOT = process.cwd();
const SCOPE_DIRS = ['app/providers/[providerId]', 'app/providers/relay', 'components/providers'];
const ANCHOR = 'vertically centered';
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');
/** Take the body of the first standalone rule for a selector in a style file (the selector on a line of its own). */
const cssRule = (css: string, selector: string) =>
  new RegExp(`(^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^{}]*)\\}`).exec(css)?.[2] ?? '';

function walkCSS(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(path.join(ROOT, dir))) {
    const rel = path.posix.join(dir, name);
    if (statSync(path.join(ROOT, rel)).isDirectory()) out.push(...walkCSS(rel));
    else if (name.endsWith('.module.css')) out.push(rel);
  }
  return out;
}

/** An anchor comment and the rule right after it. */
function anchoredRules(source: string): Array<{ comment: string; selector: string; body: string }> {
  const rules: Array<{ comment: string; selector: string; body: string }> = [];
  for (const match of source.matchAll(/\/\*([\s\S]*?)\*\//g)) {
    if (!match[1]!.includes(ANCHOR)) continue;
    const rest = source.slice(match.index! + match[0].length);
    const rule = /^\s*([^{}]+?)\s*\{([^{}]*)\}/.exec(rest);
    rules.push({
      comment: match[1]!.trim(),
      selector: rule && !rule[1]!.includes('/*') ? rule[1]! : '',
      body: rule && !rule[1]!.includes('/*') ? rule[2]! : '',
    });
  }
  return rules;
}

/** Page -> file: each page has at least one anchor in its own style file, and the anchor comment names the page. */
const PAGE_FILES: ReadonlyArray<{ page: string; file: string }> = [
  { page: 'Key row', file: 'app/providers/[providerId]/components/RelayDetailBoard.module.css' },
  { page: 'Enabled row', file: 'app/providers/[providerId]/components/RelayCatalogParts.module.css' },
  { page: 'Catalog row', file: 'app/providers/[providerId]/components/RelayCatalogParts.module.css' },
  { page: 'Detail row', file: 'app/providers/[providerId]/components/RelayDetailBoard.module.css' },
  { page: 'Menu row', file: 'app/providers/[providerId]/components/RelayEditConnection.module.css' },
  { page: 'Detection row', file: 'app/providers/relay/new/RelaySetup.module.css' },
  { page: 'Advanced key row', file: 'app/providers/[providerId]/components/RelayModelAdvanced.module.css' },
  { page: 'Capability test header', file: 'app/providers/[providerId]/components/RelayCapabilityTestPanel.module.css' },
];

/* -- production component fixtures -- */

const mocks = vi.hoisted(() => ({ routerPush: vi.fn() }));

vi.mock('../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: vi.fn(), replace: vi.fn() }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../lib/hooks/useProviderActions', () => ({
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

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: Record<string, unknown>) => unknown) =>
    selector({ setLastUsedModelRef: vi.fn(), setActiveConversationId: vi.fn() }),
  getVanillaStore: () => ({ getState: () => ({ providers: [] }) }),
}));

vi.mock('../../components/Toast', () => ({ showToast: vi.fn() }));

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return { id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '', ...extra };
}

const KEY = 'sk-relay-secret-0123456789';

/** Two keys: enabled rows carry a key chip, and the detail page uses inline keys. */
function twoKeyProvider(): Provider {
  const enabled = [model('claude-sonnet-4.5', { isDefault: true, relayKeyID: 'initial' }), model('gpt-5.4', { relayKeyID: 'k2' })];
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled, model('catalog-1'), model('catalog-2')],
    apiKey: KEY,
    apiKeyPreview: formatApiKeyPreview(KEY),
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayKeys: [
      { id: 'initial', apiKey: '', name: 'Main', status: { state: 'ok' } },
      { id: 'k2', apiKey: 'sk-second-0123456789', name: 'Backup', status: { state: 'invalid', httpStatus: 401 } },
    ],
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      modelID: 'claude-sonnet-4.5',
      resolvedAPIBaseURL: 'https://api.myrelay.dev/v1',
    },
  };
}

const lead = (row: Element) => row.querySelector('[data-row-lead]');
const trailing = (row: Element) => row.querySelector('[data-row-trailing]');
const precedes = (a: Element, b: Element) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);

function openLibrary() {
  fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
}

beforeEach(() => {
  mocks.routerPush.mockReset();
  window.history.replaceState(null, '', '/providers/relay-1');
});

describe('RL2-LAYOUT-TRAILING whole-row vertical-center anchor', () => {
  it('RL2-LAYOUT-TRAILING-01 the rule right after an anchor comment has align-items: center and no flex-start', () => {
    const problems: string[] = [];
    let anchors = 0;
    for (const file of SCOPE_DIRS.flatMap(walkCSS)) {
      for (const rule of anchoredRules(read(file))) {
        anchors += 1;
        if (!rule.selector) problems.push(`${file}: no rule follows "${rule.comment}"`);
        else if (!/align-items:\s*center\s*;/.test(rule.body) || /flex-start/.test(rule.body)) {
          problems.push(`${file}: ${rule.selector} is anchored as whole-row vertically centered but is not align-items: center`);
        }
      }
    }
    expect(problems).toEqual([]);
    expect(anchors).toBeGreaterThan(0);
  });

  it('RL2-LAYOUT-TRAILING-02 each of the eight pages has at least one anchor (the anchor comment names the page)', () => {
    const missing = PAGE_FILES
      .filter(({ page, file }) => !anchoredRules(read(file)).some((rule) => rule.comment.includes(page) && rule.selector))
      .map(({ page, file }) => `${page} → ${file}`);
    expect(missing).toEqual([]);
  });
});

describe('RL2-LAYOUT-ROW in-row layout (production component DOM)', () => {
  /*
   * jsdom does no layout, and the earlier version only asserted DOM ownership: at 430 width the `.modelRow` flex-wrap still wrapped the trailing column onto a third line
   * while every assertion stayed green. Now the CSS rules that decide the 430-wide layout are asserted too: row line nowrap + left column min-width:0 (the trailing column does not wrap),
   * chip container flex-wrap (a key chip wraps as a whole instead of being squeezed into an ellipsis), the capability icons on a line of their own, status text max-width 84px.
   */
  it('RL2-LAYOUT-ROW-01 enabled rows and catalog rows: the name alone on the first line; chip line protocol -> key may wrap, chips are not compressed; the capability icons always on their own next line', () => {
    render(<RelayDetail provider={twoKeyProvider()} />);
    openLibrary();
    const enabledRows = [...document.querySelectorAll('[data-catalog-section="enabled"] [data-catalog-row]')];
    const libraryRows = [...document.querySelectorAll('[data-catalog-section="library"] [data-catalog-row]')];
    expect(enabledRows.length).toBeGreaterThan(0);
    for (const row of [...enabledRows, ...libraryRows]) {
      const left = lead(row)!;
      expect(left).toBeTruthy();
      const name = row.querySelector('.rowName')!;
      expect(name).toBeTruthy();
      expect(name.parentElement!.querySelector('[data-protocol], [data-key-chip]')).toBeNull();
      // The icon row is a direct child of the left column (a vertical stack), not in the same horizontal container as the chips.
      const caps = row.querySelector('[data-cap-row]')!;
      expect(caps).toBeTruthy();
      expect(caps.parentElement).toBe(left);
      const chips = row.querySelector('[data-row-chips]');
      if (chips) {
        expect(chips.parentElement).toBe(left);
        expect(precedes(chips, caps)).toBe(true);
      }
    }
    const withKey = enabledRows.find((row) => row.querySelector('[data-key-chip]'))!;
    expect(withKey).toBeTruthy();
    expect(precedes(withKey.querySelector('[data-protocol]')!, withKey.querySelector('[data-key-chip]')!)).toBe(true);

    const css = read('app/providers/[providerId]/components/RelayCatalogParts.module.css');
    expect(cssRule(css, '.rowMain')).toMatch(/flex-direction:\s*column/);
    expect(cssRule(css, '.rowMain')).toMatch(/min-width:\s*0/);
    expect(cssRule(css, '.rowChips')).toMatch(/flex-wrap:\s*wrap/);
    // A key chip wraps as a whole and is not squeezed; it is truncated only when it exceeds the full column width.
    expect(cssRule(css, '.keyChip')).toMatch(/flex:\s*none/);
    expect(cssRule(css, '.keyChip')).toMatch(/max-width:\s*100%/);
  });

  it('RL2-LAYOUT-ROW-02 enabled row: the left column and the trailing column sit on the same non-wrapping row line; the status text right before the chat button, may wrap, width capped at 84px', () => {
    render(<RelayDetail provider={twoKeyProvider()} />);
    openLibrary();
    for (const row of document.querySelectorAll('[data-catalog-section="enabled"] [data-catalog-row]')) {
      const line = row.querySelector('[data-row-line]')!;
      expect(line).toBeTruthy();
      expect(line.contains(lead(row)!)).toBe(true);
      const end = trailing(row);
      expect(end).toBeTruthy();
      expect(end!.parentElement).toBe(line);
      const status = end!.querySelector('[data-status]');
      expect(status).toBeTruthy();
      // New chat follows right after the status (the generation-parameters button has moved into the Parameters row of the detail page).
      expect(status!.nextElementSibling?.getAttribute('data-trailing')).toBe('newChat');
    }
    const css = read('app/providers/[providerId]/components/RelayCatalogParts.module.css');
    const lineRule = cssRule(css, '.enabledLine');
    expect(lineRule).toMatch(/flex-wrap:\s*nowrap/);
    expect(lineRule).toMatch(/align-items:\s*center/);
    expect(lineRule).toMatch(/min-width:\s*0/);
    expect(cssRule(css, '.enabledTrailing')).toMatch(/flex-shrink:\s*0/);
    const providerCSS = read('app/providers/[providerId]/ProviderDetail.module.css');
    expect(cssRule(providerCSS, '.modelClickArea')).toMatch(/min-width:\s*0/);
    // `.modelClickArea` and `.catalogRowClickArea` have the same specificity and the latter is written later, which cascades the tap area back to column/stretch;
    // the enabled-row tap area must override that with a compound selector, so the name column and the whole row are vertically centered.
    const clickArea = cssRule(providerCSS, '.modelClickArea.catalogRowClickArea');
    expect(clickArea).toMatch(/flex-direction:\s*row/);
    expect(clickArea).toMatch(/align-items:\s*center/);
    const openButton = document.querySelector('[data-catalog-section="enabled"] [data-row-open]')!;
    expect(openButton.className).toContain('modelClickArea');
    expect(openButton.className).toContain('catalogRowClickArea');
    const statusRule = cssRule(css, '.status');
    expect(statusRule).toMatch(/max-width:\s*84px/);
    expect(statusRule).not.toMatch(/white-space:\s*nowrap|text-overflow:\s*ellipsis/);
  });

  it('RL2-LAYOUT-ROW-03 key row: the mask is the catalog-row prefix in the left column, the trailing column has only the status; an unnamed key no longer shows the mask; the detail page inline uses the same component', () => {
    const provider = twoKeyProvider();
    provider.relayKeys = [...provider.relayKeys!, { id: 'k3', apiKey: 'sk-third-0123456789', status: { state: 'limited', httpStatus: 429 } }];
    const { container } = render(<RelayDetail provider={provider} />);
    const inline = [...container.querySelectorAll('[data-board-section="connection"] [data-key-inline]')];
    expect(inline.length).toBeGreaterThanOrEqual(2);
    const shape = (row: Element) => {
      expect(row.hasAttribute('data-relay-key-row')).toBe(true);
      const end = trailing(row)!;
      expect(end).toBeTruthy();
      expect(end.querySelector('[data-row-mask]')).toBeNull();
      expect(end.querySelector('[data-row-status]')).toBeTruthy();
      expect([...end.children].every((child) => child.hasAttribute('data-row-status'))).toBe(true);
      const name = row.querySelector('[data-row-title]')!.textContent;
      const mask = row.querySelector('[data-row-mask]');
      if (name === 'Main' || name === 'Backup') {
        expect(mask).toBeTruthy();
        expect(lead(row)!.contains(mask)).toBe(true);
        // "<mask> · Catalog: N models": the mask and the catalog on the same line, the mask first.
        const catalogLine = row.querySelector('[data-row-catalog]')!;
        expect(catalogLine.contains(mask)).toBe(true);
        expect(catalogLine.textContent!.startsWith(mask!.textContent!)).toBe(true);
      } else {
        expect(mask).toBeNull();
      }
    };
    inline.forEach(shape);

    fireEvent.click(container.querySelector('[data-board-row="apiKey"]')!);
    const keyRows = [...document.querySelectorAll('[data-key-row]')].filter((row) => !row.className.includes('keyAddRow'));
    expect(keyRows.length).toBe(3);
    keyRows.forEach(shape);
    expect(keyRows[2]!.querySelector('[data-row-title]')!.textContent).toBe(formatApiKeyPreview('sk-third-0123456789'));

    const css = read('app/providers/[providerId]/components/RelayDetailBoard.module.css');
    expect(css).not.toMatch(/@container/);
    // The status text is at most 2 lines, with the mark on the first line.
    expect(cssRule(css, '.keyStatusText')).toMatch(/-webkit-line-clamp:\s*2/);
    // The mark is an inline prefix of the status text's first line -- the same text flow, end-aligned, and a wrap hugs the first word; no longer a side-by-side flex child.
    const statusLine = cssRule(css, '.keyStatusLine');
    expect(statusLine).not.toMatch(/display:\s*(inline-)?flex/);
    expect(statusLine).toMatch(/text-align:\s*end/);
    expect(cssRule(css, '.statusMark')).toMatch(/display:\s*inline-flex/);
    for (const row of [...inline, ...keyRows]) {
      const mark = row.querySelector('[data-status-mark]');
      if (!mark) continue;
      const text = row.querySelector('[data-row-status] [data-row-status-text]')!;
      expect(text).toBeTruthy();
      expect(text.firstElementChild).toBe(mark);
      // No line-break opportunity between the mark and the first word (U+2060 word joiner).
      expect(mark.nextSibling?.textContent?.startsWith('\u2060')).toBe(true);
    }
  });

  it('RL2-LAYOUT-ROW-04 step 1 detection row: the elapsed time alone in the trailing column; the detail, the key catalog row and the failure text are all inside the left column', () => {
    const verified: RelayDiscoveryResult = {
      state: 'verified',
      retriedRequestCount: 0,
      attempts: [{ method: 'GET', requestURL: 'https://relay.example.com/v1/models', statusCode: 200, kind: 'catalog', retryCount: 0 }],
      detection: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        apiBaseURL: 'https://relay.example.com/v1',
        modelIDs: ['gpt-5.4'],
        catalogModels: [model('gpt-5.4')],
        generationVerified: false,
        catalogEvidenceSucceeded: true,
        detectionEvidence: 'catalog',
      },
    };
    let done = relayStepOneAfterDiscovery(startRelayStepOne(0), verified, 'Main', 400);
    done = relayStepOneAfterCatalog(done, { catalogModels: [model('gpt-5.4')], endpointTypes: {}, keyRows: done.keyRows }, 900);
    done = relayStepOneAfterProtocols(done, 1200);
    const failed = relayStepOneAfterDiscovery(startRelayStepOne(0), {
      state: 'failed',
      failure: 'authentication_rejected',
      retriedRequestCount: 0,
      diagnostic: 'invalid api key',
      attempts: [{ method: 'GET', requestURL: 'https://relay.example.com/v1/models', statusCode: 401, kind: 'catalog', retryCount: 0 }],
    }, 'Main', 300);

    for (const detection of [done, failed]) {
      const view = render(<RelayDetectionChecklist detection={detection} />);
      const rows = [...view.container.querySelectorAll('li[data-check]')];
      expect(rows).toHaveLength(3);
      for (const row of rows) {
        const left = lead(row);
        expect(left).toBeTruthy();
        const elapsed = row.querySelector('[data-elapsed]');
        if (elapsed) {
          const end = trailing(row)!;
          expect(end).toBeTruthy();
          expect(end.contains(elapsed)).toBe(true);
          expect(end.textContent).toBe(elapsed.textContent);
        }
        for (const part of row.querySelectorAll('.checkDetail, .keyRow, details, pre')) {
          expect(left!.contains(part)).toBe(true);
        }
      }
      view.unmount();
    }
  });

  it('RL2-LAYOUT-ROW-05 edit / manual-setup menu row: the value and the arrow in the same trailing column, the footnote inside the left column', () => {
    const assertMenuRows = (scope: ParentNode) => {
      const rows = [...scope.querySelectorAll('[data-edit-row="defaultProtocol"], [data-edit-row="authentication"], [data-edit-row="channel"]')];
      expect(rows.length).toBeGreaterThan(0);
      let footnotes = 0;
      for (const row of rows) {
        const end = trailing(row);
        expect(end).toBeTruthy();
        expect(end!.querySelector('select, [data-readonly]')).toBeTruthy();
        const footnote = row.querySelector('[data-row-footnote]');
        if (footnote) {
          footnotes += 1;
          expect(lead(row)!.contains(footnote)).toBe(true);
        }
      }
      expect(footnotes).toBeGreaterThan(0);
    };

    // The manual-setup protocol card (the same component RelayEditGroupView, rendered by the production board).
    const board = manualSetupBoard({
      endpoint: 'https://relay.example.com',
      keys: [{ id: 'initial', apiKey: 'sk-a', name: '' }],
      draft: initialManualSetupDraft(),
      issues: [],
      normalizedEndpoint: 'https://relay.example.com',
      flagshipModelID: 'gpt-5.4',
      phase: { kind: 'idle' },
      advancedChoice: undefined,
    });
    const manual = render(
      <RelayEditGroupView
        group={board.protocolGroup}
        draft={{
          endpoint: '',
          transport: initialManualSetupDraft().transport,
          authMode: initialManualSetupDraft().authMode,
          customUserAgent: '',
          headers: [],
          queryParams: [],
          stream: true,
          serviceTier: '',
          disableResponseStorage: false,
        }}
        locked={false}
        issueMessage={() => ''}
        onDraftChange={() => undefined}
        onToggleGroup={() => undefined}
      />,
    );
    assertMenuRows(manual.container);
    manual.unmount();

    // Edit connection: menu row + connection security row (value, "Change" and the arrow in one column, the footnote in the left column).
    render(<RelayDetail provider={twoKeyProvider()} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
    assertMenuRows(document);
    const security = document.querySelector('[data-edit-row="connectionSecurity"]')!;
    const end = trailing(security)!;
    expect(end).toBeTruthy();
    expect(end.textContent).toContain('connectionTypeRemoteHttps');
    expect(end.textContent).toContain('changeConnectionTypeShort');
    expect(end.querySelector('svg')).toBeTruthy();
    const footnote = security.querySelector('[data-row-footnote="connectionSecurity"]')!;
    expect(footnote).toBeTruthy();
    expect(lead(security)!.contains(footnote)).toBe(true);
  });
});

describe('R-7 layout and behavior', () => {
  it('RL2-LAYOUT-ROW-07 the model library header subtitle is at most 2 lines with tail truncation (no longer a single-line ellipsis)', () => {
    render(<RelayDetail provider={twoKeyProvider()} />);
    openLibrary();
    const subtitle = document.querySelector('[data-library-subtitle]')!;
    expect(subtitle).toBeTruthy();
    expect(subtitle.className).toContain('twoLineClamp');
    expect(subtitle.className).not.toContain('singleLine');
    const rule = cssRule(read('app/providers/[providerId]/components/RelayDetailBoard.module.css'), '.twoLineClamp');
    expect(rule).toMatch(/-webkit-line-clamp:\s*2/);
    expect(rule).toMatch(/overflow:\s*hidden/);
  });

  it('RL2-LAYOUT-ROW-08 the key strip inside the model library: the left column "name / Catalog" two lines each truncated to 1 line; the trailing status <= 50% and <= 2 lines + Retry keeps its intrinsic width without wrapping', () => {
    render(<RelayDetail provider={twoKeyProvider()} />);
    openLibrary();
    const items = [...document.querySelectorAll('[data-key-strip-item]')];
    expect(items).toHaveLength(2);
    for (const item of items) {
      const leadColumn = item.querySelector('[data-key-strip-lead]')!;
      expect(leadColumn).toBeTruthy();
      // Second round: the name column and the status column share the columns area (after the icon, before Retry).
      const columns = item.querySelector('[data-key-strip-columns]')!;
      expect(columns.parentElement).toBe(item);
      expect(leadColumn.parentElement).toBe(columns);
      const title = leadColumn.querySelector('[data-key-strip-title]')!;
      const meta = leadColumn.querySelector('[data-key-strip-meta]')!;
      expect([...leadColumn.children]).toEqual([title, meta]);
      const status = item.querySelector('[data-key-strip-status]')!;
      expect(status.parentElement).toBe(columns);
      expect(precedes(leadColumn, status)).toBe(true);
    }
    const failed = document.querySelector('[data-key-strip-item="k2"]')!;
    const failure = failed.querySelector('[data-key-strip-status] [data-key-strip-failure]')!;
    expect(failure).toBeTruthy();
    const retry = failed.querySelector('[data-key-strip-retry]')!;
    expect(retry.textContent).toBe('common.retry');
    expect(retry.parentElement).toBe(failed);
    expect(precedes(failed.querySelector('[data-key-strip-status]')!, retry)).toBe(true);
    expect(document.querySelector('[data-key-strip-item="initial"] [data-key-strip-status] [data-key-strip-ok]')).toBeTruthy();

    const css = read('app/providers/[providerId]/components/RelayCatalogParts.module.css');
    expect(cssRule(css, '.keyStripItem')).toMatch(/flex-wrap:\s*nowrap/);
    const leadRule = cssRule(css, '.keyStripLead');
    expect(leadRule).toMatch(/flex-direction:\s*column/);
    expect(leadRule).toMatch(/flex:\s*1 1 0/);
    expect(leadRule).toMatch(/min-width:\s*0/);
    for (const selector of ['.keyStripTitle', '.keyStripMeta']) {
      const rule = cssRule(css, selector);
      expect(rule).toMatch(/white-space:\s*nowrap/);
      expect(rule).toMatch(/text-overflow:\s*ellipsis/);
    }
    const statusRule = cssRule(css, '.keyStripStatus');
    expect(statusRule).toMatch(/max-width:\s*50%/);
    expect(statusRule).toMatch(/-webkit-line-clamp:\s*2/);
    expect(statusRule).not.toMatch(/white-space:\s*nowrap/);
    const retryRule = cssRule(css, '.keyStripRetry');
    expect(retryRule).toMatch(/flex:\s*none/);
    expect(retryRule).toMatch(/white-space:\s*nowrap/);
  });

  it('RL2-ORDER-01 relay enabled rows keep the stored (enable) order and are not re-ordered by a model-name score', () => {
    const provider = twoKeyProvider();
    const ids = ['zeta-chat', 'gpt-5.4', 'alpha-mini', 'claude-sonnet-4.5'];
    provider.models = ids.map((id) => model(id, { relayKeyID: 'initial' }));
    provider.catalogModels = [...provider.models];
    render(<RelayDetail provider={provider} />);
    openLibrary();
    const rows = [...document.querySelectorAll('[data-catalog-section="enabled"] [data-catalog-row]')];
    expect(rows.map((row) => row.getAttribute('data-catalog-row'))).toEqual(ids);
  });

  it('RL2-KEYINPUT-01 add / change key / rename: top-left x + title; an input with a title; the key box can be shown / hidden; only a full-width Save, no Cancel', () => {
    const { container } = render(<RelayDetail provider={twoKeyProvider()} />);
    fireEvent.click(container.querySelector('[data-board-row="apiKey"]')!);
    const dialog = () => screen.getByRole('dialog');
    const assertShell = (saveLabel: string) => {
      const header = dialog().querySelector('[data-key-input-header]')!;
      expect(header).toBeTruthy();
      const close = header.querySelector('button[aria-label="common.close"]')!;
      expect(close).toBeTruthy();
      expect(precedes(close, header.querySelector('[data-key-input-title]')!)).toBe(true);
      expect(dialog().querySelectorAll('button')).not.toContain(screen.queryByRole('button', { name: 'common.cancel' }));
      expect(screen.queryByRole('button', { name: 'common.cancel' })).toBeNull();
      const save = screen.getByRole('button', { name: saveLabel });
      expect(save.hasAttribute('data-key-input-save')).toBe(true);
      return { close: close as HTMLButtonElement, save: save as HTMLButtonElement };
    };
    const assertSecret = () => {
      const input = dialog().querySelector('[data-key-input-secret]') as HTMLInputElement;
      expect(input).toBeTruthy();
      expect(input.labels?.length).toBe(1);
      expect(input.getAttribute('data-secret-visibility')).toBe('masked');
      // Masked state = a native type=password + password-manager ignore markers, the eye switches type=text; the -webkit-text-security class is no longer attached.
      fireEvent.change(input, { target: { value: 'sk-typed-0123456789' } });
      expect(input.type).toBe('password');
      expect(input.getAttribute('autocomplete')).toBe('off');
      expect(input.hasAttribute('data-1p-ignore')).toBe(true);
      expect(input.getAttribute('data-lpignore')).toBe('true');
      expect(input.hasAttribute('data-bwignore')).toBe(true);
      expect(input.classList.contains('secretMasked')).toBe(false);
      expect(read('app/providers/[providerId]/components/RelayDetailBoard.module.css')).not.toMatch(/text-security/);
      fireEvent.click(screen.getByRole('button', { name: 'pages.providerDetail.showKey' }));
      expect(input.getAttribute('data-secret-visibility')).toBe('visible');
      expect(input.type).toBe('text');
      fireEvent.change(input, { target: { value: '' } });
      return input;
    };

    // Add: an empty value disables Save.
    fireEvent.click(screen.getByText('pages.relayDetail.keysAdd'));
    let shell = assertShell('common.save');
    expect(shell.save.disabled).toBe(true);
    fireEvent.change(assertSecret(), { target: { value: 'sk-new-0123456789' } });
    expect(shell.save.disabled).toBe(false);
    fireEvent.click(shell.close);
    expect(screen.queryByRole('dialog')).toBeNull();

    // Change key: the same shell, an empty value disables Save.
    fireEvent.click(document.querySelector('[data-key-row="k2"]')!);
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
    shell = assertShell('common.save');
    expect(shell.save.disabled).toBe(true);
    assertSecret();
    fireEvent.click(shell.close);

    // Rename: the same shell, the name input carries a visible title.
    fireEvent.click(document.querySelector('[data-key-row="k2"]')!);
    fireEvent.click(screen.getByRole('button', { name: 'pages.providerDetail.renameProviderTitle' }));
    shell = assertShell('common.save');
    const nameInput = dialog().querySelector('input') as HTMLInputElement;
    expect(nameInput.labels?.length).toBe(1);
    fireEvent.click(shell.close);
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('RL2-RECOVERY-01 needs-attention card: neutral card surface, the top-right x hides it within this visit to the detail page (coming back from a subview does not bring it back, re-entering does), the reason row = lastError', () => {
    const provider: Provider = {
      ...twoKeyProvider(),
      status: { kind: 'issue', message: 'Connection has not been verified.' },
      lastError: 'Connection has not been verified.',
    };
    const first = render(<RelayDetail provider={provider} />);
    const card = document.querySelector('[data-recovery-card]')!;
    expect(card).toBeTruthy();
    // The English source string is resolved in the current language via relaySetup.connectionUnverified (the translation stub in the test returns the key), same as iOS / Android
    expect(card.querySelector('[data-recovery-reason]')!.textContent).toBe('connectionUnverified');
    const recoveryRule = cssRule(read('app/providers/[providerId]/components/RelayDetailBoard.module.css'), '.recoveryCard');
    expect(recoveryRule).not.toMatch(/warning/);
    fireEvent.click(card.querySelector('[data-recovery-dismiss]')!);
    expect(document.querySelector('[data-recovery-card]')).toBeNull();
    // Page-level state (same as iOS): going to a subview and back to the detail does not bring it back.
    openLibrary();
    expect(document.querySelector('[data-library-header]')).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: 'back' })[0]!);
    expect(document.querySelector('[data-board-section="connection"]')).toBeTruthy();
    expect(document.querySelector('[data-recovery-card]')).toBeNull();
    first.unmount();
    // Not persisted: it appears again on re-entering the page.
    render(<RelayDetail provider={provider} />);
    expect(document.querySelector('[data-recovery-card]')).toBeTruthy();
  });

  it('RL2-RECOVERY-02 needs-attention card: title = body font size semibold primary color, reason = footnote font size secondary color', () => {
    render(<RelayDetail provider={{ ...twoKeyProvider(), status: { kind: 'issue', message: 'Connection has not been verified.' }, lastError: 'Connection has not been verified.' }} />);
    const card = document.querySelector('[data-recovery-card]')!;
    const reason = card.querySelector('[data-recovery-reason]')!;
    const stack = reason.parentElement!;
    expect(stack.getAttribute('data-title-only')).toBe('true');
    expect(stack.querySelector('.rowTitle')).toBeTruthy();
    expect(reason.className).toContain('rowValue');
    const css = read('app/providers/[providerId]/components/RelayDetailBoard.module.css');
    const titleRule = cssRule(css, ".rowStack[data-title-only='true'] > .rowTitle");
    expect(titleRule).toMatch(/font-size:\s*15px/);
    expect(titleRule).toMatch(/font-weight:\s*600/);
    expect(titleRule).toMatch(/color:\s*var\(--o-text\)/);
    const reasonRule = cssRule(css, ".rowStack[data-title-only='true'] > .rowValue");
    expect(reasonRule).toMatch(/font-size:\s*13px/);
    expect(reasonRule).toMatch(/color:\s*var\(--o-text-secondary\)/);
  });

  it('C14 the relay model library shows no sort, count or provider strip, going straight to group cards', () => {
    render(<RelayDetail provider={twoKeyProvider()} />);
    openLibrary();
    const library = document.querySelector('[data-catalog-section="library"]')!;
    expect(library.querySelector('[data-testid^="group-"]')).toBeTruthy();
    expect(library.querySelector('.sortControl')).toBeNull();
    expect(library.querySelector('.countBar')).toBeNull();
    expect(library.querySelector('.shortcutRail')).toBeNull();
  });
});
