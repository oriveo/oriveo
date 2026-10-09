import 'fake-indexeddb/auto';
/**
 * The advanced settings parameter list wired to the UI data layer. All data is written through the
 * production stores and profiles go through production resolution (llama.cpp uses the real
 * in-app parameter table); the assertions check the text on screen.
 */
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { writeGenerationParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import type { GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import {
  generationParameterProfileFingerprint,
  loadGenerationParameterOverrides,
  resolveGenerationParameterOverrides,
  saveGenerationParameterOverrides,
  valueOverride,
} from '../../lib/core/chat/generation-parameter-settings';
import { additionalBodyScope, saveAdditionalBody } from '../../lib/core/chat/additional-body-settings';
import { beginCapabilityEvidenceIdentityIfAbsent, resetCapabilityEvidenceIdentitiesForTesting } from '../../lib/core/providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../lib/infra/storage/partition';
import { GenerationParameterPanel } from './GenerationParameterPanel';

// Copy is echoed as "namespace.key(param=value)" so assertions can see which message was used and with which parameters.
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => {
    const full = namespace ? `${namespace}.${key}` : key;
    return values ? `${full}(${Object.entries(values).map(([name, value]) => `${name}=${String(value)}`).join(',')})` : full;
  },
  useLocale: () => 'en',
}));
vi.mock('../Toast', () => ({ showToast: vi.fn() }));

// The cloud connection's parameter table is stubbed only at the metadata boundary (same place as the panel's existing tests); llama.cpp uses the real in-app parameter table and is not stubbed.
const cloudProfile = vi.hoisted(() => ({
  template: 'openai_chat_completions',
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature', top_p: 'top_p', seed: 'seed', stop: 'stop' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata', valueSchema: 'integer', group: 'budget', range: { min: 1, max: 8192 } },
    { id: 'temperature', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 2 } },
    { id: 'top_p', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number', group: 'sampling', conflictsWith: ['temperature'] },
    { id: 'seed', support: 'supported', source: 'authoritative_metadata', valueSchema: 'integer', group: 'reproducibility' },
    { id: 'stop', support: 'supported', source: 'authoritative_metadata', valueSchema: 'string-list', group: 'budget' },
  ],
}));
vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    resolveGenerationProfileRef: (ref?: unknown) => (ref === 'cloud' ? cloudProfile : actual.resolveGenerationProfileRef(ref as never)),
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
  };
});

const CONVERSATION = 'conversation-1';

const cloudModel = {
  id: 'cloud-model', name: 'Cloud Model', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '',
  generationProfile: 'cloud',
} as unknown as AIModel;

const cloudProvider = {
  id: 'relay-cloud', kind: 'relay', customName: 'Relay', models: [cloudModel], catalogModels: [],
  status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '', baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'remote_https' },
} as unknown as Provider;

const localModel = {
  id: 'qwen3-8b', name: 'qwen3-8b', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '', transport: 'openai_chat',
} as unknown as AIModel;

const localProvider = {
  id: 'relay-llama', kind: 'relay', customName: 'llama.cpp', models: [localModel], catalogModels: [],
  status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '', baseURLText: 'http://127.0.0.1:8080/v1',
  relayResolvedBaseURLText: 'http://127.0.0.1:8080/v1', relayResolvedTransport: 'openai_chat_completions',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'none', securityMode: 'local_http', engineProfile: 'llamacpp' },
} as unknown as Provider;

const scopeOf = (provider: Provider, model: AIModel, conversationId?: string) => ({
  providerId: provider.id,
  modelId: model.id,
  profileFingerprint: generationParameterProfileFingerprint(provider, model),
  ...(conversationId ? { conversationId } : {}),
});

const renderSession = (provider: Provider, model: AIModel) => render(
  <GenerationParameterPanel provider={provider} model={model} conversationId={CONVERSATION} scope="session" />,
);
const row = (id: string) => document.querySelector<HTMLElement>(`[data-advanced-row="${id}"]`)!;
const open = (id: string) => fireEvent.click(within(row(id)).getAllByRole('button')[0]);

describe('advanced settings parameter list (data-layer driven)', () => {
  beforeEach(() => {
    localStorage.clear();
    resetCapabilityEvidenceIdentitiesForTesting();
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), cloudProvider.id);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), localProvider.id);
  });
  afterEach(() => cleanup());

  it('the value on the right has three sources: changed in this conversation / inherited model default / decided by the model, and the header subtitle says "this conversation only"', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel), { temperature: valueOverride(0.2) });
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION), { max_output_tokens: valueOverride(4096) });
    renderSession(cloudProvider, cloudModel);

    expect(screen.getByText(`Cloud Model · common.advancedThisConversationOnly`)).toBeTruthy();
    expect(row('max_output_tokens').querySelector('[data-value-source="changedInConversation"]')?.textContent).toBe('4096');
    const inherited = row('temperature').querySelector('[data-value-source="modelDefault"]');
    expect(inherited?.textContent).toContain('0.2');
    expect(inherited?.textContent).toContain('common.advancedYourDefault');
    expect(row('seed').querySelector('[data-value-source="decidedByModel"]')?.textContent).toBe('common.advancedRandomEachTime');
    expect(screen.getByText('common.advancedWriteYourOwn')).toBeTruthy();
    expect(row('additional-body').textContent).toContain('common.customRequestFieldsNotInUse');
  });

  it('an out-of-range value is flagged immediately with the allowed range; input is not blocked and the value is not clamped', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION), { max_output_tokens: valueOverride(9000) });
    renderSession(cloudProvider, cloudModel);

    expect(within(row('max_output_tokens')).getByRole('alert').textContent).toBe('common.advancedErrorMaxTokens(limit=8192)');
    open('temperature');
    const input = within(row('temperature')).getByRole('textbox');
    fireEvent.change(input, { target: { value: '3' } });
    expect(within(row('temperature')).getByRole('alert').textContent).toBe('common.advancedErrorHighest(value=2)');
    expect(row('temperature').textContent).toContain('common.advancedAllowedRange(range=0 – 2)');
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION))?.temperature).toEqual(valueOverride(3));
  });

  it('a cross-layer conflict shows the drop reason under the row and names the other parameter; within one layer the later one wins and the earlier one is removed', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel), { temperature: valueOverride(0.5) });
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION), { top_p: valueOverride(0.9) });
    renderSession(cloudProvider, cloudModel);
    const notes = document.body.textContent ?? '';
    expect(notes).toMatch(/common\.advancedDroppedConflictWith\(parameter=common\.generationParameterName(Temperature|TopP)\)/);

    open('temperature');
    fireEvent.change(within(row('temperature')).getByRole('textbox'), { target: { value: '0.7' } });
    const conversation = loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION));
    expect(conversation?.temperature).toEqual(valueOverride(0.7));
    expect(conversation?.top_p).toBeUndefined();
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel))?.temperature).toEqual(valueOverride(0.5));
  });

  it('llama.cpp real parameter table: max tokens unlimited, Mirostat as its own section, takeover strike-through and footnote, sub-group summary', () => {
    saveGenerationParameterOverrides(scopeOf(localProvider, localModel, CONVERSATION), {
      mirostat: valueOverride(2),
      repeat_penalty: valueOverride(1.15),
    });
    renderSession(localProvider, localModel);

    expect(row('max_output_tokens').textContent).toContain('common.advancedNoLimit');
    const mirostat = document.querySelector<HTMLElement>('[data-advanced-section="family:mirostat"]')!;
    expect(mirostat.textContent).toContain('Mirostat');
    expect(within(mirostat).getByRole('radio', { name: 'v2' }).getAttribute('aria-checked')).toBe('true');
    expect(within(mirostat).getByRole('radio', { name: 'pages.chat.reasoning.off' })).toBeTruthy();
    expect(row('top_k').getAttribute('data-superseded')).toBe('true');
    expect(row('top_k').textContent).not.toContain('common.advancedDropped');
    expect(document.body.textContent).toContain('common.advancedCrossedOutLegend(families=Mirostat)');
    expect(document.body.textContent).toContain('common.advancedGreyDefaultsLegend(engine=llama.cpp)');
    open('top_k');
    expect(row('top_k').textContent).toContain('common.advancedTakenOver(family=Mirostat)');

    const repeat = document.querySelector<HTMLElement>('[data-advanced-cluster="family:repeat"]')!;
    expect(repeat.textContent).toContain('1.15');
    fireEvent.click(within(repeat).getAllByRole('button')[0]);
    expect(row('repeat_last_n')).toBeTruthy();
  });

  it('real evidence projection for a local http connection: the header says "unverified" once and rows do not repeat it', () => {
    renderSession(localProvider, localModel);
    expect(screen.getAllByText('common.generationParameterUnverifiedGroupNote')).toHaveLength(1);
    expect(screen.queryAllByTestId('generation-unverified-badge')).toHaveLength(0);
  });

  it('reset asks for confirmation first; the conversation page clears only what was changed in this conversation and leaves model defaults and the additional body alone', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel), { temperature: valueOverride(0.2) });
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION), { max_output_tokens: valueOverride(4096) });
    saveAdditionalBody(additionalBodyScope(cloudProvider, cloudModel, CONVERSATION), { raw: '{"a":1}', enabled: true });
    renderSession(cloudProvider, cloudModel);

    expect(row('additional-body').textContent).toContain('common.advancedFieldsCount(count=1)');
    fireEvent.click(screen.getByRole('button', { name: 'common.advancedReset' }));
    expect(screen.getByText('common.advancedResetConversationTitle')).toBeTruthy();
    expect(screen.getByText('common.advancedResetConversationBody')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'common.advancedResetConversationAction' }));

    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION))).toBeUndefined();
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel))?.temperature).toEqual(valueOverride(0.2));
    expect(row('additional-body').textContent).toContain('common.advancedFieldsCount(count=1)');
  });

  it('stop sequences become one tag each: sequences with commas and newlines are not split and are made visible; after removing one and adding one the outbound stop is the expected array', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel), { stop: valueOverride(['a, b', '\n\n']) });
    renderSession(cloudProvider, cloudModel);
    open('stop');
    const stopRow = row('stop');
    // Inherited model default: the tags show the two entries from the lower layer
    expect(within(stopRow).getByText('a,␣b')).toBeTruthy();
    expect(within(stopRow).getByText('↵↵')).toBeTruthy();
    // The parameter table declares no count limit, so no counter is shown
    expect(stopRow.textContent).not.toMatch(/\d+ \/ \d+/);

    fireEvent.click(within(stopRow).getByRole('button', { name: 'common.advancedStopSequenceRemove(sequence=↵↵)' }));
    // Any edit is written to this layer; the model default stays untouched
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION))?.stop).toEqual(valueOverride(['a, b']));
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel))?.stop).toEqual(valueOverride(['a, b', '\n\n']));

    fireEvent.click(within(stopRow).getByRole('button', { name: 'common.advancedStopSequenceAdd' }));
    const input = within(stopRow).getByPlaceholderText('common.advancedNewStopSequence');
    fireEvent.change(input, { target: { value: 'END,\nx' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(within(stopRow).getByText('END,↵x')).toBeTruthy();

    // The request body produced by the production resolver and the production writer
    const overrides = resolveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION));
    const body: Record<string, unknown> = { model: 'cloud-model' };
    writeGenerationParameters(body as never, overrides, cloudProfile as unknown as GenerationParameterProfile);
    expect(body.stop).toEqual(['a, b', 'END,\nx']);
  });

  it('stop sequences: empty and duplicate entries are not added and no alert is shown', () => {
    saveGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION), { stop: valueOverride(['###']) });
    renderSession(cloudProvider, cloudModel);
    open('stop');
    const stopRow = row('stop');
    fireEvent.click(within(stopRow).getByRole('button', { name: 'common.advancedStopSequenceAdd' }));
    const input = within(stopRow).getByPlaceholderText('common.advancedNewStopSequence');
    for (const value of ['', '###']) {
      fireEvent.change(input, { target: { value } });
      fireEvent.keyDown(input, { key: 'Enter' });
    }
    expect(loadGenerationParameterOverrides(scopeOf(cloudProvider, cloudModel, CONVERSATION))?.stop).toEqual(valueOverride(['###']));
    expect(within(stopRow).getAllByRole('button', { name: /common.advancedStopSequenceRemove/ })).toHaveLength(1);
    expect(within(stopRow).queryByRole('alert')).toBeNull();
  });
});
