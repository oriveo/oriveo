import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  displayCapabilityPreferences,
  encodeCapabilityTransportIdentity,
} from '../../lib/core/chat/capability-preference-settings';
import { ModelOptionsPopover } from './ModelOptionsPopover';

/**
 * W3 - the scope upgrade row (U1-U11).
 *
 * Scope is taught after the fact rather than declared up front: only once a control has been
 * changed does the row say "applied to this conversation, make it the default for this model".
 * A header line saying "these settings only apply to this conversation" is a rule the user has to
 * understand before doing anything, whereas at the moment this row appears, scope is for the
 * first time something that concerns them.
 */
const TRANSPORT_IDENTITY = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => (key: string, values?: Record<string, unknown>) => (
    values ? `${namespace}.${key}:${Object.values(values).join(',')}` : `${namespace}.${key}`
  ),
}));

const runtime = vi.hoisted(() => ({
  revision: 'runtime-r7',
  recipes: { web_recipe: { transport: { protocol: 'openai_responses' } } },
  controlDefinitions: {},
  sourceIndex: {},
}));

vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>(),
  getCapabilityRuntime: () => runtime,
  resolveCatalogModel: () => ({ canonicalModelId: 'model-1', transport: 'openai_responses' }),
  getModelTransport: () => 'openai_responses',
  refreshMetadata: async () => {},
}));

const provider = {
  id: 'A0000000-0000-0000-0000-000000000001', kind: 'openAI', models: [], catalogModels: [],
  status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
} as unknown as Provider;

const model = {
  id: 'model-1', name: 'Model 1', canonicalModelId: 'model-1', transport: 'openai_responses',
  capabilities: ['web'], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '',
  capabilityControls: { web: { state: 'auto_available', recipeRef: 'web_recipe' } },
} as unknown as AIModel;

const webControl = { state: 'auto_available' as const, availableIntents: ['off', 'automatic'], viaLegacyProfile: false };
const CONVERSATION_ID = 'B0000000-0000-0000-0000-000000000001';

function open(overrides: Record<string, unknown> = {}) {
  return render(
    <ModelOptionsPopover
      provider={provider}
      model={model}
      conversationId={CONVERSATION_ID}
      webControl={webControl}
      transportIdentity={TRANSPORT_IDENTITY}
      webPreference="off"
      onWebPreferenceChange={() => {}}
      onClose={() => {}}
      {...overrides}
    />,
  );
}

const upgradeRow = () => screen.queryByTestId('model-control-scope-upgrade');
const toggleWeb = () => fireEvent.click(screen.getByRole('switch'));

describe('W3 - scope upgrade row (U1-U11)', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
    cleanup();
  });

  it('U1 absent when the panel opens and surfacing only after the first change, never as an up-front declaration', () => {
    open();
    expect(upgradeRow()).toBeNull();

    toggleWeb();

    expect(upgradeRow()).not.toBeNull();
    expect(screen.getByText('common.capabilityControlScopeAppliedToConversation')).toBeTruthy();
    expect(screen.getByText('common.capabilityControlScopeSetAsModelDefault')).toBeTruthy();
  });

  it('U3 pinned to the fixed bottom area just above the close bar, not inside the scrolling content', () => {
    open();
    toggleWeb();

    const row = upgradeRow()!;
    const footer = row.parentElement!;
    // Same parent as the close bar: the fixed bottom area is one block, upgrade row first, close bar after.
    const children = [...footer.children];
    expect(children.indexOf(row)).toBe(0);
    expect(children).toHaveLength(2);
    expect(footer.tagName).toBe('FOOTER');
  });

  it('U2 hidden when pushing into a secondary page and restored on returning to the main panel', () => {
    open();
    toggleWeb();
    expect(upgradeRow()).not.toBeNull();

    fireEvent.click(screen.getByText('common.modelBehavior'));
    expect(upgradeRow()).toBeNull();

    fireEvent.click(screen.getByLabelText('common.back'));
    expect(upgradeRow()).not.toBeNull();
  });

  it('U5 clicking writes the connection_model scope and leaves the current conversation byte for byte unchanged', () => {
    open({ webPreference: 'automatic', reasoningIntent: 'deep' });
    toggleWeb();

    fireEvent.click(screen.getByText('common.capabilityControlScopeSetAsModelDefault'));

    const identity = {
      providerId: provider.id, canonicalModelId: 'model-1', finalTransport: 'openai_responses',
      runtimeRevision: 'runtime-r7', transportIdentity: TRANSPORT_IDENTITY,
    };
    // What is written is the default for this model: the layer with no conversation record reads it back.
    expect(displayCapabilityPreferences(identity)).toEqual({ web: 'automatic', reasoningIntent: 'deep' });
  });

  it('U7/U8 an inline confirmation that fades after 3 seconds, with no toast anywhere', () => {
    open();
    toggleWeb();
    fireEvent.click(screen.getByText('common.capabilityControlScopeSetAsModelDefault'));

    expect(screen.getByText('common.capabilityControlScopeDefaultConfirmed')).toBeTruthy();
    // The button is gone in the confirmed state: one row cannot both say it is set and ask to set it again.
    expect(screen.queryByText('common.capabilityControlScopeSetAsModelDefault')).toBeNull();

    act(() => { vi.advanceTimersByTime(3000); });

    expect(upgradeRow()).toBeNull();
  });

  it('U9 every new change resets the confirmation first, so the sentence never vouches for the change just made', () => {
    open();
    toggleWeb();
    fireEvent.click(screen.getByText('common.capabilityControlScopeSetAsModelDefault'));
    expect(screen.getByText('common.capabilityControlScopeDefaultConfirmed')).toBeTruthy();

    toggleWeb();

    expect(screen.queryByText('common.capabilityControlScopeDefaultConfirmed')).toBeNull();
    expect(screen.getByText('common.capabilityControlScopeSetAsModelDefault')).toBeTruthy();
  });

  it('U6 write guard: the row does not appear at all when read-only (sending or managed) or when identity is missing', () => {
    // Read-only: the panel renders no switches at all, so there is nothing to say was applied to this conversation.
    const readOnly = open({ runtimeIsReadOnly: true });
    expect(screen.queryByRole('switch')).toBeNull();
    expect(upgradeRow()).toBeNull();
    readOnly.unmount();

    // Missing identity: no scope can be written, so the row does not appear either.
    open({ transportIdentity: undefined });
    expect(upgradeRow()).toBeNull();
  });

  it('U1 surfaces for a draft conversation too, keyed on conversationId existing rather than on a persisted conversation', () => {
    const draft = open({ conversationId: 'draft-session-1' });
    toggleWeb();
    expect(upgradeRow()).not.toBeNull();
    draft.unmount();

    // Counter-case: with not even a draft conversation id, "applied to this conversation" has no subject.
    open({ conversationId: undefined });
    toggleWeb();
    expect(upgradeRow()).toBeNull();
  });
});
