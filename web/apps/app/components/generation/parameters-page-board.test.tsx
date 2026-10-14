import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { SlidersHorizontalIcon, ThermometerSimpleIcon } from '@phosphor-icons/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { generationParameterSummary } from '../../lib/core/chat/generation-parameter-rows';
import type { ModelOptionsPanelModel } from '../../lib/core/chat/model-options-panel-model';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../lib/core/providers/capability-evidence-identity';
import { ModelOptionsParametersCard } from '../chat/ModelOptionsMainCards';
import { ProviderSettingsPanel } from '../../app/providers/[providerId]/components/ProviderSettingsPanel';
import { GenerationParameterPanel, parametersMoreSections } from './GenerationParameterPanel';

// Parameters page board (BOARD-PARAMS-01 to 05, same names on all three platforms). Copy comes from the real en language pack; assertions are on the English users see.
type Messages = Record<string, unknown>;
const messagesRoot = resolve(process.cwd(), 'messages');
const en = vi.hoisted(() => ({ messages: {} as Record<string, unknown> }));
en.messages = JSON.parse(readFileSync(resolve(messagesRoot, 'en.json'), 'utf8')) as Messages;

function lookup(path: string): string | undefined {
  const value = path.split('.').reduce<unknown>((current, key) => (
    current && typeof current === 'object' ? (current as Record<string, unknown>)[key] : undefined
  ), en.messages);
  return typeof value === 'string' ? value : undefined;
}

vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => {
    const path = namespace ? `${namespace}.${key}` : key;
    const raw = path.split('.').reduce<unknown>((current, part) => (
      current && typeof current === 'object' ? (current as Record<string, unknown>)[part] : undefined
    ), en.messages);
    if (typeof raw !== 'string') return path;
    return values ? raw.replace(/\{(\w+)\}/g, (match, name: string) => (name in values ? String(values[name]) : match)) : raw;
  },
  useLocale: () => 'en',
}));

const profile = vi.hoisted(() => ({
  template: 'openai_chat_completions',
  wire: { temperature: 'temperature', top_p: 'top_p', seed: 'seed' },
  parameters: [
    // Parameters declared by a relay user are also adjustable in session scope (sessionActionable), so both scopes can render the group.
    { id: 'temperature', support: 'unknown', source: 'user_declared', valueSchema: 'number' },
    { id: 'top_p', support: 'unknown', source: 'user_declared', valueSchema: 'number' },
    { id: 'seed', support: 'unknown', source: 'user_declared', valueSchema: 'integer' },
  ],
}));

vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    resolveGenerationProfileRef: () => profile,
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
  };
});

const provider = {
  id: 'relay-board',
  kind: 'relay',
  customName: 'Relay',
  models: [],
  catalogModels: [],
  status: { kind: 'connected' },
  apiKey: '',
  apiKeyPreview: '',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'remote_https' },
} as Provider;

const model = {
  id: 'model-board',
  name: 'Board Model',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
} as AIModel;

const parametersCardModel = {
  temperature: { id: 'temperature', source: 'decidedByModel', standing: 'unset', isOmitted: false, unsetLabel: 'randomEachTime' },
  parameters: generationParameterSummary([]),
} as unknown as ModelOptionsPanelModel;

function moreToggle(): HTMLButtonElement | null {
  return document.querySelector<HTMLButtonElement>('[data-parameters-more] > button');
}

function moreSectionsInDom(): string[] {
  return [...document.querySelectorAll<HTMLElement>('[data-parameters-more-section]')]
    .map((node) => node.dataset.parametersMoreSection!);
}

/** a is after b in document order. */
function follows(a: Element, b: Element): boolean {
  return Boolean(b.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING);
}

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.') || name === 'messages' || name === 'public') continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) sourceFiles(path, out);
    else if (/\.(ts|tsx)$/.test(name) && !/\.test\.(ts|tsx)$/.test(name)) out.push(path);
  }
  return out;
}

const svgOf = (ui: Parameters<typeof render>[0]) => {
  const { container, unmount } = render(ui);
  const html = container.querySelector('svg')!.innerHTML;
  unmount();
  return html;
};

describe('D-56 parameters page board', () => {
  beforeEach(() => {
    localStorage.clear();
    // With a local identity present: relay-declared parameters are adjustable in session scope, and "clear learned capabilities" also has a real target to clear.
    resetCapabilityEvidenceIdentitiesForTesting();
    beginCapabilityEvidenceIdentityIfAbsent('guest', provider.id);
  });
  afterEach(() => cleanup());

  it('BOARD-PARAMS-01 the parameters page title, the parameter card entry row and the provider settings row are all called Parameters; production code no longer references the old key', () => {
    expect(lookup('common.generationParameters')).toBe('Parameters');

    const panel = render(<GenerationParameterPanel provider={provider} model={model} />);
    expect(screen.getByRole('region', { name: 'Parameters' })).toBeTruthy();
    expect(screen.getByText('Parameters', { selector: 'strong' })).toBeTruthy();
    panel.unmount();

    const card = render(<ModelOptionsParametersCard model={parametersCardModel} onOpen={() => {}} />);
    const buttons = screen.getAllByRole('button');
    expect(buttons.at(-1)!.textContent).toContain('Parameters');
    card.unmount();

    render(
      <ProviderSettingsPanel provider={provider} onSaveBaseURL={() => {}} endpointSectionLabel="Base URL" onOpenAdvanced={() => {}} />,
    );
    expect(screen.getByRole('button', { name: /^Parameters/ })).toBeTruthy();

    const legacy = /\btc?\(\s*'modelBehavior'\s*\)|tCommon\(\s*'modelBehavior'\s*\)|'common\.modelBehavior'|tSettings\(\s*'advanced'\s*\)|capabilityControlGoToAdvancedSettings|sectionAdvancedHttp/;
    const offenders = sourceFiles(process.cwd()).filter((file) => legacy.test(readFileSync(file, 'utf8')));
    expect(offenders).toEqual([]);
    expect(lookup('common.modelBehavior')).toBeUndefined();
    expect(lookup('pages.providerDetail.settings.advanced')).toBeUndefined();
    expect(lookup('common.capabilityControlGoToAdvancedSettings')).toBeUndefined();
    expect(lookup('common.capabilityControlGoToParameters')).toBe('Go to Parameters');
  });

  it('BOARD-PARAMS-02 connection scope: five blocks are folded into More after Developer, collapsed by default, expanded in order', () => {
    // Pure function: fixed order, each block keeps its original visibility rule, and when none of the five appears the whole row is hidden.
    expect(parametersMoreSections({
      scope: 'default', showsConnectionTools: true, canViewDiagnostics: true, hasCompatibilityIssues: true, canClearLearned: true,
    })).toEqual(['presets', 'connection', 'diagnostics', 'compatibility', 'clearLearned']);
    expect(parametersMoreSections({
      scope: 'default', showsConnectionTools: false, canViewDiagnostics: true, hasCompatibilityIssues: true, canClearLearned: true,
    })).toEqual(['compatibility']);
    expect(parametersMoreSections({
      scope: 'default', showsConnectionTools: false, canViewDiagnostics: true, hasCompatibilityIssues: false, canClearLearned: true,
    })).toEqual([]);

    render(<GenerationParameterPanel provider={provider} model={model} />);
    const toggle = moreToggle()!;
    expect(toggle).toBeTruthy();
    expect(toggle.textContent).toContain('More');
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(moreSectionsInDom()).toEqual([]);
    expect(screen.queryByLabelText(lookup('common.generationPresetName')!)).toBeNull();
    const developer = screen.getByTestId('generation-developer-group');
    expect(follows(toggle, developer)).toBe(true);

    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(moreSectionsInDom()).toEqual(['presets', 'connection', 'diagnostics', 'clearLearned']);
    const lastGroup = [...document.querySelectorAll('[data-advanced-section]')].at(-1)!;
    for (const section of document.querySelectorAll('[data-parameters-more-section]')) {
      expect(follows(section, lastGroup)).toBe(true);
      expect(follows(section, developer)).toBe(true);
    }
  });

  it('BOARD-PARAMS-02 no More row when all five blocks are invisible', () => {
    render(<GenerationParameterPanel provider={provider} model={model} isReadOnly />);
    expect(moreToggle()).toBeNull();
  });

  it('BOARD-PARAMS-03 chat scope has no More ops row, group order Basic -> More -> Write your own unchanged', () => {
    render(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);
    expect(moreToggle()).toBeNull();
    expect(moreSectionsInDom()).toEqual([]);
    expect(parametersMoreSections({
      scope: 'session', showsConnectionTools: false, canViewDiagnostics: true, hasCompatibilityIssues: true, canClearLearned: true,
    })).toEqual([]);
    const sections = [...document.querySelectorAll<HTMLElement>('[data-advanced-section]')].map((node) => node.dataset.advancedSection);
    expect(sections).toEqual(['common', 'more', 'writeYourOwn']);
  });

  it('BOARD-PARAMS-04 edit connection page headers section title = Headers & query params', () => {
    // The real render assertion is in the same-named case in RelayDetail.test.tsx (edit connection subview); here the English value is pinned, and production references to the old key are covered by the source scan in 01.
    expect(lookup('pages.relayDetail.sectionHeadersQuery')).toBe('Headers & query params');
  });

  it('BOARD-PARAMS-05 the two parameter card rows are prefixed with a 22pt duotone icon: thermometer-simple / sliders-horizontal', () => {
    const thermometer = svgOf(<ThermometerSimpleIcon size={22} weight="duotone" />);
    const sliders = svgOf(<SlidersHorizontalIcon size={22} weight="duotone" />);

    render(<ModelOptionsParametersCard model={parametersCardModel} onOpen={() => {}} />);
    const [temperatureRow, entryRow] = screen.getAllByRole('button');
    for (const [row, expected] of [[temperatureRow!, thermometer], [entryRow!, sliders]] as const) {
      const icon = row.querySelector('svg')!;
      expect(row.firstElementChild).toBe(icon);
      expect(icon.getAttribute('width')).toBe('22');
      expect(icon.innerHTML).toBe(expected);
      expect(icon.getAttribute('fill')).toBe('var(--o-text-secondary)');
    }
  });
});
