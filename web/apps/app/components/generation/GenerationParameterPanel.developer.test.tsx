import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { capabilityRuntimeIdentity } from '../../lib/core/chat/capability-preference-settings';
import {
  customFragmentScope,
  saveCustomFragmentSettings,
} from '../../lib/core/chat/custom-fragment-settings';
import { GenerationParameterPanel } from './GenerationParameterPanel';

/**
 * Developer group at the bottom of the advanced settings page - the only entry point for
 * custom request fields.
 *
 * Kept in its own file rather than in GenerationParameterPanel.test.tsx because this group
 * needs `getCapabilityRuntime()` to return a real runtime with controlDefinitions (without
 * one every model reports "not supported by this model"), and that runtime also changes the
 * evidence-layer verdicts, which would shift the premise of 27 other assertions.
 */
const runtime = vi.hoisted(() => ({
  revision: 'runtime-r7',
  controlDefinitions: {
    'qwen.web.enable_search': { id: 'qwen.web.enable_search', owner: 'web', targetPointer: '/enable_search', sourceRefs: ['qwen.web_search'] },
  },
  sourceIndex: { 'qwen.web_search': {} },
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${Object.values(values).join(',')}` : key
  ),
}));

vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    getCapabilityRuntime: () => runtime,
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
    // With no profile the panel falls into its empty state. The developer group must still
    // be present there (a feature row vanishing along with the parameter table reads as a
    // fault), and this group pins that down too.
    resolveGenerationProfileRef: () => undefined,
  };
});

const provider = {
  id: 'relay-1',
  kind: 'relay',
  customName: 'Relay',
  models: [] as AIModel[],
  catalogModels: [],
  status: { kind: 'connected' },
  apiKey: '',
  apiKeyPreview: '',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'remote_https' },
} as unknown as Provider;

const model = {
  id: 'model-1', name: 'Model 1', capabilities: ['text'], reasoningModeAvailable: true,
  isAvailable: true, isDefault: true, priceTier: '',
  capabilityControls: { web: { state: 'auto_available', customControlRefs: ['qwen.web.enable_search'] } },
} as unknown as AIModel;

const bareModel = { ...model, id: 'model-2', name: 'Model 2', capabilityControls: {} } as AIModel;

describe('advanced settings developer group', () => {
  beforeEach(() => localStorage.clear());
  afterEach(cleanup);

  it('shows the row as unused with a schema, opens the multi-owner editor and comes back', () => {
    render(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);

    const row = screen.getByTestId('generation-developer-row');
    expect(row.textContent).toContain('customRequestFieldsCustom');
    expect(row.textContent).toContain('customRequestFieldsNotInUse');

    fireEvent.click(row);
    expect(screen.getByTestId('custom-request-fields')).toBeTruthy();
    fireEvent.click(screen.getByText('back'));
    expect(screen.getByTestId('generation-developer-row')).toBeTruthy();
  });

  it('flips the row to enabled as soon as something is filled in inside the editor', () => {
    render(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);
    fireEvent.click(screen.getByTestId('generation-developer-row'));

    fireEvent.change(document.querySelector('textarea')!, { target: { value: '{"enable_search":true}' } });
    fireEvent.click(screen.getByText('back'));

    expect(screen.getByTestId('generation-developer-row').textContent).toContain('customRequestFieldsInUse');
  });

  it('hands navigation off instead of pushing when the mounting side owns that layer', () => {
    const onOpenCustomFields = vi.fn();
    render(
      <GenerationParameterPanel
        provider={provider}
        model={model}
        conversationId="conversation-1"
        scope="session"
        onOpenCustomFields={onOpenCustomFields}
      />,
    );

    fireEvent.click(screen.getByTestId('generation-developer-row'));
    expect(onOpenCustomFields).toHaveBeenCalledTimes(1);
    expect(screen.queryByTestId('custom-request-fields')).toBeNull();
  });

  it('keeps the row present and tappable when unsupported, naming models on this connection that do work', () => {
    const onSelectCustomFieldsModel = vi.fn();
    const withCandidates = { ...provider, models: [model, bareModel] } as unknown as Provider;
    render(
      <GenerationParameterPanel
        provider={withCandidates}
        model={bareModel}
        onSelectCustomFieldsModel={onSelectCustomFieldsModel}
      />,
    );

    const row = screen.getByTestId('generation-developer-row');
    expect(row.textContent).toContain('capabilityControlNotSupportedByModel');
    fireEvent.click(row);

    const explanation = screen.getByTestId('generation-developer-explanation');
    expect(explanation.textContent).toContain('customRequestFieldsRequiresSchema');
    expect(explanation.textContent).not.toContain('capabilityControlNoSupportedModels');
    fireEvent.click(screen.getByText('Model 1'));
    expect(onSelectCustomFieldsModel).toHaveBeenCalledWith(model);
  });

  it('keeps the entry reachable for a model with stored configuration even after the server withdraws the schema, so it can still be turned off', () => {
    saveCustomFragmentSettings(customFragmentScope(provider, bareModel, transportIdentity(), 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });

    render(<GenerationParameterPanel provider={provider} model={bareModel} />);

    expect(screen.getByTestId('generation-developer-row').textContent).toContain('customRequestFieldsInUse');
  });

  // Of the three refresh moments, "read once on mount" is already covered above. The other
  // two were never really exercised: the model-switch case always started a fresh render
  // (which proves the initial read, not that the dependency array re-runs), and the edit
  // broadcast case unmounted the whole group in the editor, so coming back went through the
  // mount path again. Both are covered here.
  it('re-reads the same panel in place when the model changes, not only on a fresh mount', () => {
    const withBoth = { ...provider, models: [model, bareModel] } as unknown as Provider;
    const { rerender } = render(<GenerationParameterPanel provider={withBoth} model={model} conversationId="conversation-1" scope="session" />);
    expect(screen.getByTestId('generation-developer-row').textContent).toContain('customRequestFieldsNotInUse');

    rerender(<GenerationParameterPanel provider={withBoth} model={bareModel} conversationId="conversation-1" scope="session" />);
    expect(screen.getByTestId('generation-developer-row').textContent).toContain('capabilityControlNotSupportedByModel');

    rerender(<GenerationParameterPanel provider={withBoth} model={model} conversationId="conversation-1" scope="session" />);
    expect(screen.getByTestId('generation-developer-row').textContent).toContain('customRequestFieldsNotInUse');
  });

  it('re-reads in place when an edit broadcast arrives, with the group still mounted rather than picking state back up on remount', async () => {
    // Passing onOpenCustomFields means the mounting side owns the editor and this group is
    // not unmounted. That is the only way to exercise the `CUSTOM_FRAGMENT_SETTINGS_EVENT`
    // subscription; when the group pushes the subpage itself it is not in the DOM at all.
    render(
      <GenerationParameterPanel
        provider={provider}
        model={bareModel}
        onOpenCustomFields={vi.fn()}
      />,
    );
    expect(screen.getByTestId('generation-developer-row').textContent).toContain('capabilityControlNotSupportedByModel');

    // Go through the production write function so it emits the broadcast itself (a
    // microtask rather than a synchronous dispatch). The test does not synthesize the event:
    // a synthetic one would only prove the consumer works and say nothing about whether the
    // producer actually broadcasts.
    await act(async () => {
      saveCustomFragmentSettings(customFragmentScope(provider, bareModel, transportIdentity(), 'web'), {
        configurationMode: 'custom', raw: '{"enable_search":true}',
      });
      await Promise.resolve();
    });

    expect(screen.getByTestId('generation-developer-row').textContent).toContain('customRequestFieldsInUse');
  });
});

/** Call the production encoder directly: hand-writing this string would copy the implementation into the test, so one encoding change breaks both. */
function transportIdentity(): string {
  return capabilityRuntimeIdentity(provider, bareModel)!.transportIdentity;
}
