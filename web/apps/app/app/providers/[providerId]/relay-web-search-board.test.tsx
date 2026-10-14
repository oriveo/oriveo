import 'fake-indexeddb/auto';
// Web search settings page (BOARD-WEBSEARCH-01 to 09): the board model's grouping / folding / counts / savability / whether anything changed /
// template confirmation decision, the page structure the production component renders from the model, and the persisted result when saving goes through the production saveRelayWebSearchSettings.

import { fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type Provider, type RelayRequestedConfig } from '@oriveo/shared';
import { RELAY_WEB_FRAGMENT_TEMPLATES } from '@oriveo/shared/relay/web-fragments';
import { createAppStore } from '../../../lib/core/store/app-store';
import { readStoredRelayWebFragments, saveRelayWebFragment } from '../../../lib/core/chat/relay-web-fragments';
import { relayDetailBoard } from './relay-detail-board';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import type { AIModel } from '@oriveo/shared';
import {
  readRelayWebProbeAutoHistory,
  writeRelayWebProbeRecord,
} from '../../../lib/core/chat/relay-web-probe-records';
import {
  RELAY_WEB_SEARCH_TEXT,
  relayWebDraftsFromProvider,
  relayWebNextOtherChoice,
  relayWebSearchBoard,
  relayWebTemplateNeedsConfirm,
  type RelayWebDrafts,
} from './relay-web-search-board';
import { RelayWebSearchPage } from './components/RelayWebSearchPage';

const mocks = vi.hoisted(() => ({
  store: null as null | ReturnType<typeof import('../../../lib/core/store/app-store').createAppStore>,
}));

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  getActiveUIDSync: () => 'user-1',
  getActiveUID: async () => 'user-1',
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../../providers/StoreProvider', () => ({
  getVanillaStore: () => mocks.store,
}));

// Re-test goes through the production runRelayWebProbe entry; here it is replaced by a controllable stand-in (the case writes the record as the result), measuring only how the page calls and refreshes.
const probe = vi.hoisted(() => ({ run: vi.fn() }));
vi.mock('../../../lib/core/relay-web-probe-ops', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  runRelayWebProbe: probe.run,
}));

/* -- fixtures -- */

function relay(id: string, requested: Partial<RelayRequestedConfig>): Provider {
  const base = makeRelayRequested('openai_compatible');
  base.authMode = 'bearer';
  return {
    id,
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk',
    apiKeyPreview: 'sk-…',
    baseURLText: 'https://relay.example',
    relayKind: 'openai_compatible',
    relayRequested: { ...base, transport: 'auto', ...requested },
    createdAt: '',
    updatedAt: '',
  } as unknown as Provider;
}

const CHAT = 'openai_chat_completions' as const;
const RESPONSES = 'openai_responses' as const;
const MESSAGES = 'anthropic_messages' as const;
const GEMINI = 'gemini_generate_content' as const;

const pretty = (value: unknown) => JSON.stringify(value, null, 2);
const OK_CHAT = '{"plugins":[{"id":"web"}]}';

function boardOf(provider: Provider, drafts?: Partial<RelayWebDrafts>, otherChoice?: boolean) {
  const baseline = relayWebDraftsFromProvider(provider);
  return relayWebSearchBoard({ provider, baseline, drafts: { ...baseline, ...drafts }, otherChoice });
}

function renderPage(provider: Provider, handlers: { onBack?: () => void; onSaved?: () => void } = {}) {
  const onBack = handlers.onBack ?? vi.fn();
  const onSaved = handlers.onSaved ?? vi.fn();
  const view = render(
    <RelayWebSearchPage
      provider={provider}
      connectionName="myrelay.dev"
      backLabel="Back"
      onBack={onBack}
      onSaved={onSaved}
      disabled={false}
    />,
  );
  return { ...view, onBack, onSaved };
}

const textareaOf = (transport: string) =>
  document.querySelector(`[data-relay-web-transport="${transport}"] textarea`) as HTMLTextAreaElement;
const saveButton = () => screen.getByRole('button', { name: 'common.save' });

beforeEach(() => {
  localStorage.clear();
  mocks.store = createAppStore();
});

afterEach(() => {
  localStorage.clear();
});

/* -- 01 header / description / footer / save clickable -- */

describe('BOARD-WEBSEARCH-01 header, description, footer and save clickable', () => {
  it('BOARD-WEBSEARCH-01 board: not savable with no change; savable once changed; changed back to the original = no change; not savable with a mistyped section', () => {
    const provider = relay('ws-01', { transport: CHAT });
    expect(boardOf(provider)).toMatchObject({ hasChanges: false, hasError: false, canSave: false });
    expect(boardOf(provider, { [CHAT]: OK_CHAT })).toMatchObject({ hasChanges: true, hasError: false, canSave: true });
    expect(boardOf(provider, { [CHAT]: '' })).toMatchObject({ hasChanges: false, canSave: false });
    expect(boardOf(provider, { [CHAT]: '{"model":"x"}' })).toMatchObject({ hasChanges: true, hasError: true, canSave: false });
  });

  it('BOARD-WEBSEARCH-01 page: back + "Web Search" + subtitle with the connection name; description; footer Saved only on this device; the bottom Save is not clickable when nothing changed', () => {
    const provider = relay('ws-01b', { transport: CHAT });
    renderPage(provider);
    expect(screen.getByRole('button', { name: 'Back' })).toBeTruthy();
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe(RELAY_WEB_SEARCH_TEXT.title);
    expect(RELAY_WEB_SEARCH_TEXT.title).toBe('common.capabilityControlWebSearch');
    expect(screen.getByText('myrelay.dev')).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.webSearch.intro')).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.advanced.localOnly')).toBeTruthy();
    expect((saveButton() as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(textareaOf(CHAT), { target: { value: OK_CHAT } });
    expect((saveButton() as HTMLButtonElement).disabled).toBe(false);
    fireEvent.change(textareaOf(CHAT), { target: { value: '{"model":"x"}' } });
    expect((saveButton() as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(textareaOf(CHAT), { target: { value: '' } });
    expect((saveButton() as HTMLButtonElement).disabled).toBe(true);
  });
});

/* -- 02 section order and the expanded set -- */

describe('BOARD-WEBSEARCH-02 section order and the expanded set', () => {
  const transportsOf = (sections: Array<{ transport: string }>) => sections.map((section) => section.transport);

  it('BOARD-WEBSEARCH-02 connection fixed to Responses, no root address -> main group [Responses], the rest go into Other protocols in order', () => {
    const board = boardOf(relay('ws-02a', { transport: RESPONSES }));
    expect(transportsOf(board.mainSections)).toEqual([RESPONSES]);
    expect(transportsOf(board.otherGroup!.sections)).toEqual([CHAT, MESSAGES, GEMINI]);
    expect(RELAY_WEB_SEARCH_TEXT.otherProtocols).toBe('pages.relayDetail.webSearch.otherProtocols');
  });

  it('BOARD-WEBSEARCH-02 expanded = the detail page Base paths protocol set union the connection-selected protocol', () => {
    const auto = relay('ws-02b', {
      transport: 'auto',
      resolvedAPIBaseURLs: { [MESSAGES]: 'https://relay.example/v1', [CHAT]: 'https://relay.example/v1' },
    });
    expect(transportsOf(boardOf(auto).mainSections)).toEqual([CHAT, MESSAGES]);
    expect(transportsOf(boardOf(auto).otherGroup!.sections)).toEqual([RESPONSES, GEMINI]);
    const selected = relay('ws-02c', {
      transport: GEMINI,
      resolvedAPIBaseURLs: { [CHAT]: 'https://relay.example/v1' },
    });
    expect(transportsOf(boardOf(selected).mainSections)).toEqual([CHAT, GEMINI]);
    expect(transportsOf(boardOf(selected).otherGroup!.sections)).toEqual([RESPONSES, MESSAGES]);
  });

  it('BOARD-WEBSEARCH-02 auto with no root address -> all four sections expanded, no folded group; the Chat section carries a description', () => {
    const board = boardOf(relay('ws-02d', { transport: 'auto' }));
    expect(transportsOf(board.mainSections)).toEqual([CHAT, RESPONSES, MESSAGES, GEMINI]);
    expect(board.otherGroup).toBeNull();
    expect(board.mainSections.map((section) => section.showsChatNote)).toEqual([true, false, false, false]);
  });

  it('BOARD-WEBSEARCH-02 a local connection has no web-search page entry', () => {
    const local = relay('ws-02e', { transport: CHAT, engineProfile: 'ollama' });
    expect(relayDetailBoard(local, null, { webSearchConfigured: false }).modelRows.map((row) => row.id)).not.toContain('webSearch');
  });
});

/* -- 03 folded group -- */

describe('BOARD-WEBSEARCH-03 folded group: collapsed by default, counts, a mistyped section forces it open', () => {
  it('BOARD-WEBSEARCH-03 collapsed by default; the group header writes %lld set (whitespace only = not filled, 0 is not written)', () => {
    const provider = relay('ws-03a', { transport: RESPONSES });
    expect(boardOf(provider).otherGroup).toMatchObject({ expanded: false, forcedOpen: false, trailing: null });
    const filled = boardOf(provider, { [CHAT]: OK_CHAT, [GEMINI]: '   \n ' });
    expect(filled.otherGroup).toMatchObject({
      expanded: false,
      trailing: { key: RELAY_WEB_SEARCH_TEXT.setCount, values: { count: 1 } },
    });
    expect(RELAY_WEB_SEARCH_TEXT.setCount).toBe('pages.relayDetail.editBoard.setCount');
    expect(boardOf(provider, {}, true).otherGroup!.expanded).toBe(true);
  });

  it('BOARD-WEBSEARCH-03 a mistyped section inside a group forces it open; tapping the group header meanwhile records expanded, and once fixed it does not collapse in front of the user', () => {
    const provider = relay('ws-03b', { transport: RESPONSES });
    const broken = boardOf(provider, { [MESSAGES]: '{"stream":true}' });
    expect(broken.otherGroup).toMatchObject({ expanded: true, forcedOpen: true });
    const choice = relayWebNextOtherChoice(broken.otherGroup!);
    expect(choice).toBe(true);
    expect(boardOf(provider, { [MESSAGES]: OK_CHAT }, choice).otherGroup).toMatchObject({ expanded: true, forcedOpen: false });
    // Tapping the group header toggles as usual when it was not forced open
    expect(relayWebNextOtherChoice({ expanded: true, forcedOpen: false })).toBe(false);
  });

  it('BOARD-WEBSEARCH-03 page: the main group cannot collapse (no group header button), and the folded group header aria-expanded follows the toggle', () => {
    renderPage(relay('ws-03c', { transport: RESPONSES }));
    const toggles = screen.getAllByRole('button', { expanded: false });
    expect(toggles).toHaveLength(1);
    expect(toggles[0]!.textContent).toContain('pages.relayDetail.webSearch.otherProtocols');
    expect(textareaOf(CHAT)).toBeNull();
    fireEvent.click(toggles[0]!);
    expect(screen.getByRole('button', { expanded: true })).toBeTruthy();
    expect(textareaOf(CHAT)).toBeTruthy();
  });
});

/* -- 04 fill-in template confirmation -- */

describe('BOARD-WEBSEARCH-04 Use template: confirm first when there is other content, decided per protocol', () => {
  it('BOARD-WEBSEARCH-04 decision: empty / whitespace only / already the template -> fill directly; other content -> confirm', () => {
    expect(relayWebTemplateNeedsConfirm(CHAT, '')).toBe(false);
    expect(relayWebTemplateNeedsConfirm(CHAT, '  \n')).toBe(false);
    expect(relayWebTemplateNeedsConfirm(CHAT, pretty(RELAY_WEB_FRAGMENT_TEMPLATES[CHAT]))).toBe(false);
    expect(relayWebTemplateNeedsConfirm(CHAT, JSON.stringify(RELAY_WEB_FRAGMENT_TEMPLATES[CHAT]))).toBe(false);
    expect(relayWebTemplateNeedsConfirm(CHAT, pretty(RELAY_WEB_FRAGMENT_TEMPLATES[GEMINI]))).toBe(true);
    expect(relayWebTemplateNeedsConfirm(GEMINI, '{"x":1}')).toBe(true);
  });

  it('BOARD-WEBSEARCH-04 page: with content -> confirm (Replace what’s here? + description + Replace / Cancel); an empty section fills directly', () => {
    renderPage(relay('ws-04', { transport: 'auto' }));
    fireEvent.change(textareaOf(CHAT), { target: { value: '{"x":1}' } });
    const useTemplate = (transport: string) => within(
      document.querySelector(`[data-relay-web-transport="${transport}"]`) as HTMLElement,
    ).getByRole('button', { name: 'pages.relayDetail.webSearch.useTemplate' });

    fireEvent.click(useTemplate(CHAT));
    const dialog = screen.getByRole('alertdialog');
    expect(within(dialog).getByText(RELAY_WEB_SEARCH_TEXT.templateReplaceTitle)).toBeTruthy();
    expect(within(dialog).getByText(RELAY_WEB_SEARCH_TEXT.templateReplaceMessage)).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.cancel' }));
    expect(screen.queryByRole('alertdialog')).toBeNull();
    expect(textareaOf(CHAT).value).toBe('{"x":1}');

    fireEvent.click(useTemplate(CHAT));
    fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: RELAY_WEB_SEARCH_TEXT.templateReplace }));
    expect(textareaOf(CHAT).value).toBe('{"web_search_options":{}}');

    fireEvent.click(useTemplate(GEMINI));
    expect(screen.queryByRole('alertdialog')).toBeNull();
    expect(textareaOf(GEMINI).value).toBe('{"tools":[{"googleSearch":{}}]}');
  });
});

/* -- 05 unsaved-changes prompt -- */

describe('BOARD-WEBSEARCH-05 going back with changes gives the unsaved prompt (reusing the copy of the edit-connection page)', () => {
  it('BOARD-WEBSEARCH-05 board: a change inside a collapsed group counts; typing only whitespace does not; content from the old hasWebSearch mapping does not', () => {
    const provider = relay('ws-05a', { transport: RESPONSES });
    expect(boardOf(provider, { [GEMINI]: OK_CHAT }).hasChanges).toBe(true);
    expect(boardOf(provider, { [GEMINI]: '  \n' }).hasChanges).toBe(false);
    const legacy = relay('ws-05b', { transport: 'auto', hasWebSearch: true } as Partial<RelayRequestedConfig>);
    const baseline = relayWebDraftsFromProvider(legacy);
    expect(Object.values(baseline).some((raw) => raw.trim().length > 0)).toBe(true);
    expect(boardOf(legacy).hasChanges).toBe(false);
    saveRelayWebFragment('ws-05c', CHAT, OK_CHAT);
    const stored = relay('ws-05c', { transport: CHAT });
    expect(boardOf(stored, { [CHAT]: `  ${OK_CHAT}\n\n` }).hasChanges).toBe(false);
  });

  it('BOARD-WEBSEARCH-05 page: with changes -> Discard unsaved changes? / Keep editing stays / Discard goes back; with no changes it goes back directly', () => {
    const { onBack } = renderPage(relay('ws-05d', { transport: CHAT }));
    fireEvent.change(textareaOf(CHAT), { target: { value: OK_CHAT } });
    fireEvent.click(screen.getByRole('button', { name: 'Back' }));
    const dialog = screen.getByRole('alertdialog');
    expect(within(dialog).getByText('pages.relayDetail.editBoard.discardTitle')).toBeTruthy();
    expect(within(dialog).getByText('pages.relayDetail.editBoard.unsavedMessage')).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('button', { name: 'pages.relayDetail.editBoard.keepEditing' }));
    expect(onBack).not.toHaveBeenCalled();
    expect(textareaOf(CHAT).value).toBe(OK_CHAT);
    fireEvent.click(screen.getByRole('button', { name: 'Back' }));
    fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'pages.relayDetail.editBoard.discard' }));
    expect(onBack).toHaveBeenCalledTimes(1);

    const clean = renderPage(relay('ws-05e', { transport: CHAT }));
    fireEvent.click(within(clean.container).getByRole('button', { name: 'Back' }));
    expect(clean.onBack).toHaveBeenCalledTimes(1);
  });
});

describe('BOARD-WEBSEARCH-05b saved snippet draft = compact JSON (same format as the template)', () => {
  it('BOARD-WEBSEARCH-05b on entering the page both the draft and the input box are single-line JSON without indentation', () => {
    saveRelayWebFragment('ws-05f', RESPONSES, pretty({ web_search_options: {} }));
    const provider = relay('ws-05f', { transport: RESPONSES });
    const drafts = relayWebDraftsFromProvider(provider);
    expect(drafts[RESPONSES]).toBe('{"web_search_options":{}}');
    renderPage(provider);
    expect(textareaOf(RESPONSES).value).toBe('{"web_search_options":{}}');
  });
});

/* -- 06 page structure (both ends assert structure only) -- */

describe('BOARD-WEBSEARCH-06 in-page header + bottom action bar', () => {
  it('BOARD-WEBSEARCH-06 the header comes before the content; the bottom action bar has a single primary button Save, after the footer', () => {
    const { container } = renderPage(relay('ws-06', { transport: CHAT }));
    const header = container.querySelector('[data-relay-web-header]');
    const actionBar = container.querySelector('[data-relay-web-action-bar]');
    expect(header).toBeTruthy();
    expect(within(header as HTMLElement).getByRole('button', { name: 'Back' })).toBeTruthy();
    expect(actionBar).toBeTruthy();
    expect(within(actionBar as HTMLElement).getAllByRole('button').map((button) => button.textContent)).toEqual(['common.save']);
    const firstSection = container.querySelector('[data-relay-web-transport]')!;
    expect(header!.compareDocumentPosition(firstSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(firstSection.compareDocumentPosition(actionBar!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });
});

/* -- 07 / 08 save -- */

describe('BOARD-WEBSEARCH-08 saving goes through the production path', () => {
  it('BOARD-WEBSEARCH-08 a mistyped section -> nothing is written to storage or persisted', () => {
    const provider = relay('ws-08a', { transport: 'auto', hasWebSearch: true } as Partial<RelayRequestedConfig>);
    mocks.store!.getState().addProvider(provider);
    const { onSaved } = renderPage(provider);
    fireEvent.change(textareaOf(CHAT), { target: { value: '{"messages":[]}' } });
    fireEvent.click(saveButton());
    expect(onSaved).not.toHaveBeenCalled();
    expect(readStoredRelayWebFragments('ws-08a')).toEqual({});
  });

  it('BOARD-WEBSEARCH-08 snippets are written to on-device storage (clearing a section deletes it), the connection drops hasWebSearch, transport is unchanged; reading back = the stored sections', async () => {
    const provider = relay('ws-08b', { transport: RESPONSES, hasWebSearch: true } as Partial<RelayRequestedConfig>);
    mocks.store!.getState().addProvider(provider);
    saveRelayWebFragment('ws-08b', GEMINI, '{"tools":[{"googleSearch":{}}]}');
    const { onSaved } = renderPage(provider);
    fireEvent.click(screen.getByRole('button', { name: /otherProtocols/ }));
    fireEvent.change(textareaOf(GEMINI), { target: { value: '' } });
    fireEvent.change(textareaOf(CHAT), { target: { value: OK_CHAT } });
    fireEvent.click(saveButton());
    await vi.waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    const fragments = readStoredRelayWebFragments('ws-08b');
    expect(fragments).toEqual({ [CHAT]: { plugins: [{ id: 'web' }] } });
    const saved = mocks.store!.getState().providers.find((item) => item.id === 'ws-08b')!;
    expect(saved.relayRequested).not.toHaveProperty('hasWebSearch');
    expect(saved.relayRequested?.transport).toBe(RESPONSES);
  });
});

describe('BOARD-WEBSEARCH-07 re-entering the page after saving', () => {
  it('BOARD-WEBSEARCH-07 saving becomes the new baseline: re-entering shows no change; content in another group only writes the count and does not auto-expand', async () => {
    const provider = relay('ws-07', { transport: RESPONSES });
    mocks.store!.getState().addProvider(provider);
    const first = renderPage(provider);
    fireEvent.click(screen.getByRole('button', { name: /otherProtocols/ }));
    fireEvent.change(textareaOf(MESSAGES), { target: { value: pretty(RELAY_WEB_FRAGMENT_TEMPLATES[MESSAGES]) } });
    fireEvent.click(saveButton());
    await vi.waitFor(() => expect(first.onSaved).toHaveBeenCalledTimes(1));
    first.unmount();

    const reopened = mocks.store!.getState().providers.find((item) => item.id === 'ws-07')!;
    const board = boardOf(reopened);
    expect(board.hasChanges).toBe(false);
    expect(board.otherGroup).toMatchObject({ expanded: false, trailing: { values: { count: 1 } } });
    renderPage(reopened);
    expect((saveButton() as HTMLButtonElement).disabled).toBe(true);
    expect(textareaOf(MESSAGES)).toBeNull();
  });
});

/* ── 09 LTR ── */

describe('BOARD-WEBSEARCH-09 JSON editor forced LTR', () => {
  it('BOARD-WEBSEARCH-09 every textarea has dir="ltr"', () => {
    renderPage(relay('ws-09', { transport: 'auto' }));
    const areas = Array.from(document.querySelectorAll('textarea'));
    expect(areas).toHaveLength(4);
    expect(areas.every((area) => area.getAttribute('dir') === 'ltr')).toBe(true);
  });
});

/* -- Notice above Save, the models that reject these settings, and re-test -- */

describe('RL2-WEBPROBE-RETEST rejected area and re-test', () => {
  const OTHER_CHAT = '{"web_search_options":{"search_context_size":"low"}}';

  function relayWithModels(id: string): Provider {
    const provider = relay(id, { transport: CHAT });
    const models = ['m-a', 'm-b', 'm-c', 'm-d', 'm-e'].map((modelID) => ({
      id: modelID,
      name: `Model ${modelID.slice(2).toUpperCase()}`,
      capabilities: [],
    }) as unknown as AIModel);
    return { ...provider, models };
  }

  /** Saved Chat snippet; records: a rejected, b searched, c rejected, d none, e rejected but its hash belongs to an old snippet. */
  function seed(id: string): Provider {
    const provider = relayWithModels(id);
    mocks.store!.getState().addProvider(provider);
    const saved = saveRelayWebFragment(id, CHAT, OK_CHAT);
    const stale = saveRelayWebFragment(`${id}-stale`, CHAT, OTHER_CHAT);
    if (!saved.ok || !stale.ok) throw new Error('fixture fragment invalid');
    const write = (modelId: string, result: 'searched' | 'rejected', hash: string) => writeRelayWebProbeRecord(
      { connectionId: id, modelId, transport: CHAT },
      { result, source: 'tested', at: '2026-10-01T00:00:00.000Z', fragmentHash: hash },
    );
    const current = relayWebFragmentHash(saved.fragment);
    // The write order deliberately differs from the enable order: the list follows the enable order, not the record order.
    write('m-c', 'rejected', current);
    write('m-a', 'rejected', current);
    write('m-b', 'searched', current);
    write('m-e', 'rejected', relayWebFragmentHash(stale.fragment));
    return provider;
  }

  const rejectedRows = (container: HTMLElement) =>
    [...container.querySelectorAll('[data-relay-web-rejected-model]')].map((row) => row.getAttribute('data-relay-web-rejected-model'));

  beforeEach(() => {
    probe.run.mockReset();
  });

  it('RL2-WEBPROBE-12 RETEST lists only enabled models recorded as rejected under the current fragment, in enable order; row = model name + Test again', () => {
    const { container } = renderPage(seed('ws-rt1'));
    const section = container.querySelector('[data-relay-web-rejected]') as HTMLElement;
    expect(section).toBeTruthy();
    expect(within(section).getByText('pages.relayDetail.webSearch.rejectedTitle')).toBeTruthy();
    expect(rejectedRows(container)).toEqual(['m-a', 'm-c']);
    const row = container.querySelector('[data-relay-web-rejected-model="m-a"]') as HTMLElement;
    expect(row.textContent).toContain('Model A');
    expect(within(row).getAllByRole('button').map((button) => button.textContent)).toEqual(['pages.relayDetail.webSearch.retest']);
  });

  it('RL2-WEBPROBE-RETEST no rejected record -> no rejected area', () => {
    const provider = relayWithModels('ws-rt0');
    saveRelayWebFragment('ws-rt0', CHAT, OK_CHAT);
    const { container } = renderPage(provider);
    expect(container.querySelector('[data-relay-web-rejected]')).toBeNull();
  });

  it('RL2-WEBPROBE-RETEST re-test goes through runRelayWebProbe (manual, not entered into the automatic history), shows a spinner while running, only one at a time; after searched the row disappears', async () => {
    const provider = seed('ws-rt2');
    let finish: () => void = () => {};
    probe.run.mockImplementation((_store: unknown, connectionId: string, modelId: string) => new Promise((resolve) => {
      finish = () => {
        const saved = saveRelayWebFragment(`${connectionId}-probe`, CHAT, OK_CHAT);
        if (!saved.ok) throw new Error('fixture fragment invalid');
        writeRelayWebProbeRecord(
          { connectionId, modelId, transport: CHAT },
          { result: 'searched', source: 'tested', at: '2026-10-02T00:00:00.000Z', fragmentHash: relayWebFragmentHash(saved.fragment) },
        );
        resolve({ outcome: 'completed', transport: CHAT, result: 'searched', evidenceUrls: [], overrideWritten: true });
      };
    }));
    const { container } = renderPage(provider);
    const rowOf = (modelID: string) => container.querySelector(`[data-relay-web-rejected-model="${modelID}"]`) as HTMLElement;

    fireEvent.click(within(rowOf('m-c')).getByRole('button', { name: 'pages.relayDetail.webSearch.retest' }));
    expect(probe.run).toHaveBeenCalledTimes(1);
    expect(probe.run.mock.calls[0]![0]).toBe(mocks.store);
    expect(probe.run.mock.calls[0]!.slice(1, 3)).toEqual(['ws-rt2', 'm-c']);

    // While running: that row's button becomes a spinner; other rows' buttons are not clickable (only one at a time).
    expect(within(rowOf('m-c')).queryByRole('button')).toBeNull();
    expect(rowOf('m-c').querySelector('[data-relay-web-retest-running]')).toBeTruthy();
    const other = within(rowOf('m-a')).getByRole('button', { name: 'pages.relayDetail.webSearch.retest' }) as HTMLButtonElement;
    expect(other.disabled).toBe(true);
    fireEvent.click(other);
    expect(probe.run).toHaveBeenCalledTimes(1);

    finish();
    await vi.waitFor(() => expect(rejectedRows(container)).toEqual(['m-a']));
    expect((within(rowOf('m-a')).getByRole('button') as HTMLButtonElement).disabled).toBe(false);
    expect(readRelayWebProbeAutoHistory()).toEqual([]);
  });

  it('RL2-WEBPROBE-RETEST still rejected after re-test: the row stays, the spinner goes away', async () => {
    const provider = seed('ws-rt3');
    probe.run.mockResolvedValue({ outcome: 'completed', transport: CHAT, result: 'rejected', evidenceUrls: [], overrideWritten: true });
    const { container } = renderPage(provider);
    const row = container.querySelector('[data-relay-web-rejected-model="m-a"]') as HTMLElement;
    fireEvent.click(within(row).getByRole('button'));
    await vi.waitFor(() => expect(row.querySelector('[data-relay-web-retest-running]')).toBeNull());
    expect(rejectedRows(container)).toEqual(['m-a', 'm-c']);
  });

  it('RL2-WEBPROBE-RETEST the notice row sits above the save bar and below the footer; the rejected area comes after the groups', () => {
    const { container } = renderPage(seed('ws-rt4'));
    const disclosure = screen.getByText('pages.relayDetail.webSearch.probeDisclosure');
    const footer = screen.getByText('pages.relayDetail.advanced.localOnly');
    const actionBar = container.querySelector('[data-relay-web-action-bar]')!;
    const rejected = container.querySelector('[data-relay-web-rejected]')!;
    const lastGroup = [...container.querySelectorAll('[data-relay-web-transport], [data-relay-web-group]')].at(-1)!;
    const follows = (a: Node, b: Node) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
    expect(follows(footer, disclosure)).toBe(true);
    expect(follows(disclosure, actionBar)).toBe(true);
    expect(actionBar.contains(disclosure)).toBe(false);
    expect(follows(lastGroup, rejected)).toBe(true);
    expect(lastGroup.contains(rejected)).toBe(false);
    expect(follows(rejected, footer)).toBe(true);
  });
});
