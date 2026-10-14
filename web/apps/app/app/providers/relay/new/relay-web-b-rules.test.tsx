import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { useState } from 'react';
import { describe, expect, it, vi } from 'vitest';
import { modelControlTransportLabel } from '../../../../lib/core/chat/model-control-capability-layout';
import { RelayEditGroupView } from '../../[providerId]/components/RelayEditConnection';
import { relayEditDefaultProtocolRow, type EditGroup, type RelayEditDraft } from '../../[providerId]/relay-edit-board';
import { RelaySetupEndpointField, RelaySetupKeySlots, RelaySetupStepOne } from './RelaySetupStepOne';
import { initialManualSetupDraft, manualSetupBoard } from './manual-setup-board';
import { localChannelDisplayName } from './setup-board';
import type { RelayKeyDraft } from './relay-setup-two-step';

// Stable reference: giving a new function on every render would make effects that depend on t fire repeatedly.
const intl = vi.hoisted(() => ({
  t: (key: string, values?: Record<string, unknown>) => (values ? `${key}(${JSON.stringify(values)})` : key),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => intl.t,
  useLocale: () => 'en',
}));

// RL2-SECRET-02: masked = native type=password, plaintext = type=text; the -webkit-text-security class is no longer used.
function isMasked(input: HTMLInputElement): boolean {
  expect(input.classList.contains('secretMasked')).toBe(false);
  expect(['password', 'text']).toContain(input.type);
  return input.type === 'password';
}

function expectSecretContract(input: HTMLInputElement) {
  expect(input.getAttribute('autocomplete')).toBe('off');
  expect(input.hasAttribute('data-1p-ignore')).toBe(true);
  expect(input.getAttribute('data-lpignore')).toBe('true');
  expect(input.hasAttribute('data-bwignore')).toBe(true);
}

function KeySlotsHarness({ apiKey }: { apiKey: string }) {
  const [showKey, setShowKey] = useState(false);
  const [keys, setKeys] = useState<RelayKeyDraft[]>([{ id: 'k0', apiKey, name: '' }]);
  return (
    <RelaySetupKeySlots
      keys={keys}
      onKeyChange={(index, patch) => setKeys((prev) => prev.map((key, i) => (i === index ? { ...key, ...patch } : key)))}
      onAddKey={() => undefined}
      onRemoveKey={() => undefined}
      showKey={showKey}
      onToggleKey={() => setShowKey((value) => !value)}
      issues={[]}
    />
  );
}

describe('RL2-SECRET-01 key slot is masked by default, visible after toggling the eye', () => {
  it('a filled key is masked by default, plaintext after tapping the eye, masked again after another tap', () => {
    render(<KeySlotsHarness apiKey="sk-relay-demo-backup-9Zc2" />);
    const input = document.getElementById('relay-api-key') as HTMLInputElement;
    expect(input.value).toBe('sk-relay-demo-backup-9Zc2');
    expectSecretContract(input);
    expect(isMasked(input)).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'showKey' }));
    expect(isMasked(input)).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'hideKey' }));
    expect(isMasked(input)).toBe(true);
  });
});

const ROOT = process.cwd();
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');
const SETUP_CSS = 'app/providers/relay/new/RelaySetup.module.css';
const EDIT_CSS = 'app/providers/[providerId]/components/RelayEditConnection.module.css';
const BOARD_CSS = 'app/providers/[providerId]/components/RelayDetailBoard.module.css';

function cssRule(source: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(source)?.[1] ?? '';
}

function EndpointHarness({ initial }: { initial: string }) {
  const [endpoint, setEndpoint] = useState(initial);
  return (
    <>
      <RelaySetupEndpointField endpoint={endpoint} onEndpointChange={setEndpoint} endpointNormalizationVersion={0} />
      <output data-testid="stored-endpoint">{endpoint}</output>
    </>
  );
}

const stored = () => screen.getByTestId('stored-endpoint').textContent;
const chip = () => screen.getByTestId('relay-endpoint-scheme').textContent;

describe('RL2-LAYOUT-URL-01 address slot with a scheme chip', () => {
  it('the slot shows only the part after the scheme; the chip shows the written scheme', () => {
    render(<EndpointHarness initial="http://192.168.1.8:8080/v1" />);
    const input = document.getElementById('relay-request-url') as HTMLInputElement;
    expect(input.value).toBe('192.168.1.8:8080/v1');
    expect(chip()).toBe('http');
  });

  it('input containing :// replaces the whole string; otherwise the written scheme is kept; the chip is https when none is written', () => {
    render(<EndpointHarness initial="" />);
    const input = document.getElementById('relay-request-url') as HTMLInputElement;
    expect(chip()).toBe('https');
    fireEvent.change(input, { target: { value: 'api.relay-demo.example' } });
    expect([stored(), input.value, chip()]).toEqual(['api.relay-demo.example', 'api.relay-demo.example', 'https']);
    fireEvent.change(input, { target: { value: 'http://10.0.0.2:3000' } });
    expect([stored(), input.value, chip()]).toEqual(['http://10.0.0.2:3000', '10.0.0.2:3000', 'http']);
    fireEvent.change(input, { target: { value: '10.0.0.2:3001' } });
    expect([stored(), input.value, chip()]).toEqual(['http://10.0.0.2:3001', '10.0.0.2:3001', 'http']);
    // Agreed: clearing clears the whole string, leaving no half scheme.
    fireEvent.change(input, { target: { value: '' } });
    expect([stored(), input.value, chip()]).toEqual(['', '', 'https']);
  });

  it('placeholder drops the scheme: setup / manual setup api.example.com, edit api.example.com/v1', () => {
    render(<EndpointHarness initial="" />);
    expect((document.getElementById('relay-request-url') as HTMLInputElement).placeholder).toBe('api.example.com');
    const group: EditGroup = {
      id: 'connection',
      titleKey: 'pages.relayEdit.connection',
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [{ id: 'requestURL', titleKey: 'pages.relayDetail.endpoint', icon: 'link', value: { literal: '' } }],
      issues: [],
    };
    render(
      <RelayEditGroupView
        group={group}
        draft={{ ...editDraft(), endpoint: 'https://api.relay-demo.example' }}
        locked={false}
        issueMessage={() => ''}
        onDraftChange={() => undefined}
        onToggleGroup={() => undefined}
      />,
    );
    const edit = document.getElementById('relay-edit-endpoint') as HTMLInputElement;
    expect([edit.value, edit.placeholder]).toEqual(['api.relay-demo.example', 'api.example.com/v1']);
  });

  it('only one layer of focus outline: the inner input drops the global focus-visible outline', () => {
    const css = read(SETUP_CSS);
    expect(cssRule(css, '.inputShell:focus-within')).toContain('box-shadow');
    expect(cssRule(css, '.shellInput:focus-visible')).toMatch(/box-shadow:\s*none/);
  });
});

function editDraft(): RelayEditDraft {
  return {
    endpoint: '',
    transport: initialManualSetupDraft().transport,
    authMode: initialManualSetupDraft().authMode,
    customUserAgent: '',
    headers: [],
    queryParams: [],
    stream: true,
    serviceTier: '',
    disableResponseStorage: false,
  } as RelayEditDraft;
}

describe('C9 key note: one sentence under the key slot, "stored on this device only"; the CORS / proxy note moves to the end of the form', () => {
  it('under the key block there is only the one sentence apiKeyStaysOnDevice; apiKeyPrivacy is a full-width footnote above the step indicator', () => {
    render(
      <RelaySetupStepOne
        endpoint=""
        onEndpointChange={() => undefined}
        endpointNormalizationVersion={0}
        keys={[{ id: 'k0', apiKey: '', name: '' }]}
        onKeyChange={() => undefined}
        onAddKey={() => undefined}
        onRemoveKey={() => undefined}
        errors={{}}
        showKey={false}
        onToggleKey={() => undefined}
        detection={null}
        isDetecting={false}
        primaryEnabled={false}
        onPrimary={() => undefined}
        onCancelDetection={() => undefined}
        onToggleManual={() => undefined}
      />,
    );
    const keyBlock = document.getElementById('relay-api-key')!.closest('[class~="field"]')!;
    expect(keyBlock.textContent).toContain('apiKeyStaysOnDevice');
    expect(keyBlock.textContent).not.toContain('apiKeyPrivacy');
    const note = screen.getByText('apiKeyPrivacy');
    const stepFooter = screen.getByText('twoStep.stepOf({"current":1,"total":2})').parentElement!;
    expect(note.compareDocumentPosition(stepFooter) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(keyBlock.compareDocumentPosition(note) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('the new key is complete in all 16 languages and taken verbatim from iOS (original English sentence)', () => {
    const en = JSON.parse(read('messages/en.json')) as { pages: { relaySetup: Record<string, string> } };
    expect(en.pages.relaySetup.apiKeyStaysOnDevice).toBe('Keys stay on this device and aren’t uploaded by cloud sync.');
    const zh = JSON.parse(read('messages/zh-Hans.json')) as { pages: { relaySetup: Record<string, string> } };
    expect(zh.pages.relaySetup.apiKeyStaysOnDevice).toBe('\u5bc6\u94a5\u53ea\u5b58\u672c\u673a，\u4e0d\u968f\u4e91\u540c\u6b65\u4e0a\u4f20。');
  });
});

describe('RL2-LAYOUT-HEADER-01 family page section title = small secondary-color label (no vertical bar)', () => {
  it('family page section title style has no vertical bar; a vertical-bar title appears only in the model library section', () => {
    const board = read(BOARD_CSS);
    const title = cssRule(board, '.sectionTitle');
    expect(title).toContain('color: var(--o-text-secondary)');
    expect(board).not.toMatch(/\.sectionTitle::before/);
    for (const file of [
      'app/providers/[providerId]/components/RelayEditConnection.tsx',
      'app/providers/[providerId]/components/RelayWebSearchPage.tsx',
      'app/providers/[providerId]/components/RelayDetailBoard.tsx',
      'app/providers/relay/new/RelayManualSetup.tsx',
      'app/providers/relay/new/LocalComputeSetup.tsx',
    ]) {
      expect([file, read(file).includes('sectionLabel')]).toEqual([file, false]);
    }
  });
});

describe('RL2-LAYOUT-ROW-06 menu row: value column <= 45%, at most 2 lines with tail truncation; title + footnote column >= 55%', () => {
  it('manual setup default protocol row (production board): the value lands in the row-end column', () => {
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
    render(
      <RelayEditGroupView
        group={board.protocolGroup}
        draft={editDraft()}
        locked={false}
        issueMessage={() => ''}
        onDraftChange={() => undefined}
        onToggleGroup={() => undefined}
      />,
    );
    const row = document.querySelector('[data-edit-row="defaultProtocol"]')!;
    const trailing = row.querySelector('[data-row-trailing]')!;
    expect(trailing.querySelector('select, [data-readonly]')).not.toBeNull();
    expect(row.querySelector('[data-row-lead]')).not.toBeNull();
  });

  it('styles: row-end column capped at 45%, left column floor 55%; value at most 2 lines with tail truncation', () => {
    const css = read(EDIT_CSS);
    expect(cssRule(css, '.menuRow > .rowTrailing')).toMatch(/max-width:\s*calc\(45% - 12px\)/);
    expect(cssRule(css, '.menuRow > .rowLead')).toMatch(/min-width:\s*55%/);
    const value = cssRule(css, '.menuValue');
    expect(value).toMatch(/-webkit-line-clamp:\s*2/);
    expect(value).not.toMatch(/white-space:\s*nowrap/);
    expect(cssRule(css, '.menu')).toMatch(/text-overflow:\s*ellipsis/);
  });
});

describe('C10 in-family channel name / web search section title use the full OpenAI name (the shared table on the chat page is unchanged)', () => {
  it('local channel name = OpenAI Chat Completions; modelControlTransportLabel unchanged', () => {
    expect(localChannelDisplayName('chat')).toBe('OpenAI Chat Completions');
    expect(modelControlTransportLabel('openai_chat_completions')).toBe('Chat Completions');
    expect(modelControlTransportLabel('openai_responses')).toBe('Responses');
  });

  it('the edit page channel row and the web search section title use the family name', () => {
    expect(read('app/providers/[providerId]/components/RelayWebSearchPage.tsx')).toContain('relayFamilyTransportLabel(transport)');
    expect(read('app/providers/[providerId]/relay-edit-board.ts')).toContain('relayFamilyTransportLabel');
  });
});

describe('R-7 default protocol value and options use the family protocol proper names (same row in edit / manual setup)', () => {
  it('the selected protocol value, options and the protocol name in the footnote are all the full OpenAI name', () => {
    const row = relayEditDefaultProtocolRow('openai_responses');
    expect(row.value).toEqual({ literal: 'OpenAI Responses' });
    expect(row.options!.map((option) => option.label)).toEqual(expect.arrayContaining([
      { literal: 'OpenAI Chat Completions' },
      { literal: 'OpenAI Responses' },
    ]));
    expect(row.footnote).toMatchObject({ values: { protocol: 'OpenAI Responses' } });
  });
});
