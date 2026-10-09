import 'fake-indexeddb/auto';
/**
 * Rendering of the main "Model options" pane: the capability card drawn per shape, the header status
 * badge, the parameter card pills and the thinking linkage. All data goes through production paths:
 * the additional body and parameter values are written and read through the production stores, the
 * UI shape is computed by the production presentation functions inside the popover, and copy comes
 * from the real en language pack.
 */
import React, { useState } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import en from '../../messages/en.json';
import { encodeCapabilityTransportIdentity } from '../../lib/core/chat/capability-preference-settings';
import { additionalBodyScope, loadAdditionalBody } from '../../lib/core/chat/additional-body-settings';
import {
  generationParameterProfileFingerprint,
  saveGenerationParameterOverrides,
  valueOverride,
} from '../../lib/core/chat/generation-parameter-settings';
import { beginCapabilityEvidenceIdentityIfAbsent, resetCapabilityEvidenceIdentitiesForTesting } from '../../lib/core/providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../lib/infra/storage/partition';
import { ModelOptionsPopover } from './ModelOptionsPopover';

function lookup(path: string): string | undefined {
  const value = path.split('.').reduce<unknown>((node, key) => (
    node && typeof node === 'object' ? (node as Record<string, unknown>)[key] : undefined
  ), en);
  return typeof value === 'string' ? value : undefined;
}

vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => {
    const path = namespace ? `${namespace}.${key}` : key;
    const message = lookup(path) ?? path;
    return message.replace(/\{(\w+)\}/g, (_placeholder, name: string) => String(values?.[name] ?? `{${name}}`));
  },
  useLocale: () => 'en',
}));
vi.mock('../Toast', () => ({ showToast: vi.fn() }));

const REVISION = 'runtime-r7';
const runtime = vi.hoisted(() => ({
  revision: 'runtime-r7',
  recipes: {},
  controlDefinitions: {},
  sourceIndex: {},
}));
// The cloud parameter table is stubbed only at the metadata boundary (same place as the advanced settings list test); local engines and Relay use the real in-app parameter table.
const cloudProfile = vi.hoisted(() => ({
  template: 'openai_chat_completions',
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata', valueSchema: 'integer', group: 'budget', range: { min: 1, max: 8192 } },
    { id: 'temperature', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 2 } },
  ],
}));
// A Relay connection on the Anthropic transport: the parameter table follows the Anthropic Messages template (temperature is dropped on the wire when thinking is on).
const anthropicProfile = vi.hoisted(() => ({
  template: 'anthropic_messages',
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata', valueSchema: 'integer', group: 'budget', range: { min: 1 } },
    { id: 'temperature', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 } },
  ],
}));
vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    getCapabilityRuntime: () => runtime,
    resolveGenerationProfileRef: (ref?: unknown) => (ref === 'cloud' ? cloudProfile
      : ref === 'anthropic' ? anthropicProfile
        : actual.resolveGenerationProfileRef(ref as never)),
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
    refreshMetadata: async () => {},
  };
});

const CONVERSATION = 'B0000000-0000-0000-0000-000000000003';

const cloudModel = {
  id: 'cloud-model', name: 'Cloud Model', canonicalModelId: 'cloud-model', transport: 'openai_chat',
  capabilities: ['text', 'web'], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '',
  generationProfile: 'cloud',
} as unknown as AIModel;
const officialProvider = {
  id: 'A0000000-0000-0000-0000-000000000001', kind: 'openAI', models: [cloudModel], catalogModels: [],
  status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
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

const claudeModel = {
  id: 'claude-sonnet-4-5', name: 'Claude Sonnet', capabilities: ['text', 'reasoning'], reasoningModeAvailable: true,
  isAvailable: true, isDefault: true, priceTier: '', generationProfile: 'anthropic',
} as unknown as AIModel;
const anthropicRelay = {
  id: 'relay-anthropic', kind: 'relay', customName: 'Claude Relay', models: [claudeModel], catalogModels: [],
  status: { kind: 'connected' }, apiKey: 'k', apiKeyPreview: '', baseURLText: 'https://relay.example/v1',
  relayResolvedBaseURLText: 'https://relay.example/v1', relayResolvedTransport: 'anthropic_messages',
  relayRequested: { transport: 'anthropic_messages', authMode: 'bearer', securityMode: 'remote_https' },
} as unknown as Provider;

const control = (state: string, availableIntents: string[] = []) => ({ state, availableIntents, viaLegacyProfile: false }) as never;

type PopoverProps = React.ComponentProps<typeof ModelOptionsPopover>;
function open(props: Partial<PopoverProps>) {
  return render(
    <ModelOptionsPopover
      provider={officialProvider}
      model={cloudModel}
      conversationId={CONVERSATION}
      webControl={control('auto_available', ['off', 'automatic'])}
      reasoningControl={control('auto_available', ['off', 'low', 'deep'])}
      transportIdentity={encodeCapabilityTransportIdentity('openai_chat_completions', REVISION)}
      webPreference="off"
      onWebPreferenceChange={() => {}}
      onReasoningIntentChange={() => {}}
      onClose={() => {}}
      {...props}
    />,
  );
}

const header = () => screen.getByTestId('model-options-header-line');
const capabilities = () => screen.getByRole('region', { name: 'Capabilities' });
const row = (name: 'Web Search' | 'Thinking Mode') => screen.getByRole('group', { name });

describe('model options main pane (rendering)', () => {
  beforeEach(() => {
    localStorage.clear();
    resetCapabilityEvidenceIdentitiesForTesting();
    for (const provider of [officialProvider, localProvider, anthropicRelay]) {
      beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    }
  });
  afterEach(() => cleanup());

  it('official model: the header shows "Official configuration", web search is a switch and thinking is a segmented control', () => {
    const onWebPreferenceChange = vi.fn();
    const onReasoningIntentChange = vi.fn();
    open({ onWebPreferenceChange, onReasoningIntentChange });

    expect(within(header()).getByText('Official configuration')).toBeTruthy();
    fireEvent.click(within(row('Web Search')).getByRole('switch', { name: 'Web Search' }));
    expect(onWebPreferenceChange).toHaveBeenCalledWith('automatic');

    const tiers = within(row('Thinking Mode')).getByRole('radiogroup', { name: 'Thinking Mode' });
    expect(within(tiers).getAllByRole('radio').map((node) => node.textContent)).toEqual(['Off', 'Fast', 'Deep']);
    fireEvent.click(within(tiers).getByRole('radio', { name: 'Deep' }));
    expect(onReasoningIntentChange).toHaveBeenCalledWith('deep');
  });

  it('local connection: the header says "Local", thinking is a chat template switch placed before web search; toggling it puts enable_thinking into the additional body in the production store', async () => {
    open({
      provider: localProvider, model: localModel,
      webControl: control('unknown'), reasoningControl: control('unknown'),
    });

    expect(header().textContent).toContain('Local');
    const order = within(capabilities()).getAllByRole('group').map((node) => node.getAttribute('aria-label'));
    expect(order).toEqual(['Thinking Mode', 'Web Search']);
    expect(within(row('Web Search')).getByText('This connection can’t do this')).toBeTruthy();
    expect(within(row('Web Search')).queryByRole('switch')).toBeNull();

    const scope = additionalBodyScope(localProvider, localModel, CONVERSATION);
    expect(loadAdditionalBody(scope)).toBeNull();
    const toggle = within(row('Thinking Mode')).getByRole('switch', { name: 'Thinking Mode' }) as HTMLInputElement;
    expect(toggle.checked).toBe(false);
    fireEvent.click(toggle);

    const stored = loadAdditionalBody(scope);
    expect(stored?.enabled).toBe(true);
    expect(JSON.parse(stored!.raw)).toEqual({ chat_template_kwargs: { enable_thinking: true } });
    // The store change notifies the popover to re-read through an event (dispatched in a microtask).
    await act(async () => {});
    expect((within(row('Thinking Mode')).getByRole('switch') as HTMLInputElement).checked).toBe(true);
  });

  it('undecided transport: the whole capability card says one thing and the way out is to choose a transport', () => {
    const onOpenConnectionSettings = vi.fn();
    const undecided = {
      ...anthropicRelay, relayResolvedTransport: undefined,
      relayRequested: { transport: 'auto', authMode: 'bearer', securityMode: 'remote_https' },
    } as unknown as Provider;
    open({ provider: undecided, model: claudeModel, transportIdentity: undefined, onOpenConnectionSettings });

    const card = within(capabilities());
    expect(card.getByText('Choose this connection’s protocol first')).toBeTruthy();
    expect(card.queryAllByRole('group')).toHaveLength(0);
    expect(card.queryByRole('switch')).toBeNull();
    fireEvent.click(card.getByRole('button', { name: 'Choose protocol' }));
    expect(onOpenConnectionSettings).toHaveBeenCalledOnce();
  });

  it('parameter card: two items written for this conversation in the production store -> two pills', () => {
    saveGenerationParameterOverrides({
      providerId: officialProvider.id, modelId: cloudModel.id, conversationId: CONVERSATION,
      profileFingerprint: generationParameterProfileFingerprint(officialProvider, cloudModel),
    }, { temperature: valueOverride(0.7), max_output_tokens: valueOverride(4096) });
    open({});

    const card = screen.getByRole('button', { name: /^Advanced Settings/ });
    expect(within(card).getByText(/^Temperature 0\.7$/)).toBeTruthy();
    expect(card.querySelectorAll('[data-kind="set"]')).toHaveLength(2);
  });

  it('thinking linkage: after choosing a thinking tier on a Relay Anthropic connection, the temperature row in advanced settings says the model does not accept this item while thinking is on', async () => {
    saveGenerationParameterOverrides({
      providerId: anthropicRelay.id, modelId: claudeModel.id, conversationId: CONVERSATION,
      profileFingerprint: generationParameterProfileFingerprint(anthropicRelay, claudeModel),
    }, { temperature: valueOverride(0.5) });
    // The host (ChatView) projects the chosen tier into reasoningMode and passes it back to the popover; it is fed back the same controlled way here.
    const MODE_BY_INTENT: Record<string, ReasoningMode> = { low: 'fast', balanced: 'balanced', deep: 'deep', max: 'max' };
    function Host() {
      const [intent, setIntent] = useState<string | undefined>();
      const mode = intent ? MODE_BY_INTENT[intent] : undefined;
      return (
        <ModelOptionsPopover
          provider={anthropicRelay}
          model={claudeModel}
          conversationId={CONVERSATION}
          webControl={control('unavailable')}
          reasoningControl={control('auto_available', ['off', 'low', 'deep'])}
          transportIdentity={encodeCapabilityTransportIdentity('anthropic_messages', REVISION)}
          webPreference="off"
          onWebPreferenceChange={() => {}}
          {...(intent ? { reasoningIntent: intent as never } : {})}
          {...(mode ? { reasoningMode: mode } : {})}
          onReasoningIntentChange={(next) => setIntent(next ?? undefined)}
          onClose={() => {}}
        />
      );
    }
    render(<Host />);

    fireEvent.click(within(row('Thinking Mode')).getByRole('radio', { name: 'Deep' }));
    fireEvent.click(screen.getByRole('button', { name: /^Advanced Settings/ }));
    await act(async () => {});
    const temperature = await waitFor(() => {
      const node = document.querySelector<HTMLElement>('[data-advanced-row="temperature"]');
      expect(node?.textContent).toContain(en.common.advancedDroppedThinking);
      return node!;
    });
    await act(async () => {});
    expect(temperature.textContent).toContain(en.common.advancedDroppedThinking);
  });
});
