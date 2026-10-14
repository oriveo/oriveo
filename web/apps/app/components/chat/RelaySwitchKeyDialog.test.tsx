import 'fake-indexeddb/auto';
import { fireEvent, render, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider } from '@oriveo/shared';
import { createAppStore } from '../../lib/core/store/app-store';
import { MessageRecoveryCard } from './MessageRecoveryCard';
import { RelaySwitchKeyDialog, relaySwitchKeyChoices } from './RelaySwitchKeyDialog';

/**
 * Chat "switch key": the condition is derived from the persisted relayDeniedKeyID and the alternate,
 * choosing one -> RK-2 rebind (real store persists), the panel closes, no automatic resend.
 */

const mocks = vi.hoisted(() => ({ store: null as unknown }));

vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => {
    const full = namespace ? `${namespace}.${key}` : key;
    return values ? `${full}(${JSON.stringify(values)})` : full;
  },
  useLocale: () => 'en',
}));

vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => mocks.store,
  useAppStore: () => undefined,
}));

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...extra,
  };
}

/** Shape of fixture key-binding.v1.json readCases.two_keys_with_denial; the protocol was set by the user, so rebinding does not trigger lazy verification. */
function deniedProvider(): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'https://api.myrelay.dev/v1';
  const userTransport = { relayTransport: 'openai_chat_completions' as const, relayTransportSource: 'user' as const };
  return {
    id: 'relay-switch-key',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    apiKey: 'sk-a-0123456789abcdef',
    apiKeyPreview: 'sk-a...cdef',
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayKeys: [
      { id: 'initial', name: 'OpenAI', apiKey: '', status: { state: 'ok', httpStatus: 200 } },
      { id: 'k-b', name: 'Claude', apiKey: 'sk-b-0123456789abcdef', status: { state: 'invalid', httpStatus: 401 } },
    ],
    models: [
      model('gpt-4o', { relayKeyID: 'initial', relayDeniedKeyID: 'initial', ...userTransport }),
      model('claude-opus-4', { relayKeyID: 'k-b', relayDeniedKeyID: 'initial', ...userTransport }),
    ],
    catalogModels: [
      model('gpt-4o', { relayListedByKeyIDs: ['initial', 'k-b'] }),
      model('claude-opus-4', { relayListedByKeyIDs: ['k-b'] }),
    ],
  } as Provider;
}

beforeEach(() => {
  mocks.store = null;
});

describe('CHAT-SWITCHKEY-01 failure message switch key', () => {
  it('CHAT-SWITCHKEY-01 condition: still enabled + current key denied + alternate non-empty; otherwise not shown', () => {
    const provider = deniedProvider();
    expect(relaySwitchKeyChoices(provider, 'gpt-4o')).toEqual([
      { id: 'k-b', title: 'Claude', preview: 'sk-b…cdef' },
    ]);
    // The denied key is not the one currently bound -> not counted as denied.
    expect(relaySwitchKeyChoices(provider, 'claude-opus-4')).toBeNull();
    // No longer among the enabled ones.
    expect(relaySwitchKeyChoices(provider, 'gpt-4.1')).toBeNull();
    expect(relaySwitchKeyChoices(provider, undefined)).toBeNull();
    // No alternate.
    const noAlternate = { ...provider, catalogModels: [model('gpt-4o', { relayListedByKeyIDs: ['initial'] })] };
    expect(relaySwitchKeyChoices(noAlternate, 'gpt-4o')).toBeNull();
    // A connection with only one key.
    expect(relaySwitchKeyChoices({ ...provider, relayKeys: undefined }, 'gpt-4o')).toBeNull();
    // Official provider.
    expect(relaySwitchKeyChoices({ ...provider, kind: 'openAI' } as Provider, 'gpt-4o')).toBeNull();
  });

  it('CHAT-SWITCHKEY-01 panel: title carries the model name, hint, lists the alternate; choosing -> rebind persists, clears the denied mark, closes, no resend', async () => {
    const provider = deniedProvider();
    const store = createAppStore();
    store.getState().addProvider(provider);
    mocks.store = store;
    const onClose = vi.fn();
    const onRetry = vi.fn();
    render(<RelaySwitchKeyDialog provider={provider} modelID="gpt-4o" modelName="GPT-4o" onClose={onClose} />);

    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('pages.relayDetail.chatSwitchKeyTitle({"model":"GPT-4o"})')).toBeTruthy();
    expect(within(dialog).getByText('pages.relayDetail.chatSwitchKeyHint')).toBeTruthy();
    const option = within(dialog).getByRole('button', { name: /Claude/ });
    expect(option.textContent).toContain('sk-b…cdef');

    fireEvent.click(option);
    // Choosing closes right away without waiting for the lazy verification after rebind.
    expect(onClose).toHaveBeenCalledTimes(1);
    const stored = store.getState().providers[0]!.models.find((item) => item.id === 'gpt-4o')!;
    expect(stored.relayKeyID).toBe('k-b');
    expect(stored.relayDeniedKeyID).toBeUndefined();
    expect(onRetry).not.toHaveBeenCalled();
  });

  it('CHAT-SWITCHKEY-01 failure card: when switch key is given it replaces the edit cell with "Switch key", retry stays the primary button; unchanged when not given', () => {
    const onSwitchKey = vi.fn();
    const onEdit = vi.fn();
    const { rerender } = render(
      <MessageRecoveryCard state="failed" errorKind="model_access_denied" errorDetail="denied" onRetry={vi.fn()} onEdit={onEdit} onSwitchKey={onSwitchKey} />,
    );
    const buttons = screen.getAllByRole('button').map((button) => button.textContent);
    expect(buttons).toContain('pages.relayDetail.chatSwitchKey');
    expect(buttons).not.toContain('pages.chat.recovery.editBtn');
    expect(buttons[0]).toBe('pages.chat.recovery.retryBtn');
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.chatSwitchKey' }));
    expect(onSwitchKey).toHaveBeenCalledTimes(1);

    rerender(<MessageRecoveryCard state="failed" errorKind="model_access_denied" errorDetail="denied" onRetry={vi.fn()} onEdit={onEdit} />);
    expect(screen.queryByRole('button', { name: 'pages.relayDetail.chatSwitchKey' })).toBeNull();
    expect(screen.getByRole('button', { name: 'pages.chat.recovery.editBtn' })).toBeTruthy();
  });

  it('CHAT-SWITCHKEY-01 still appears when there is a primary action and no edit cell (fills the first empty slot); the appearance condition depends only on the contract', () => {
    const onSwitchKey = vi.fn();
    render(
      <MessageRecoveryCard
        state="failed"
        errorKind="model_access_denied"
        errorDetail="denied"
        primaryActionLabel="Resend"
        onPrimaryAction={vi.fn()}
        onSwitchKey={onSwitchKey}
      />,
    );
    expect(screen.getAllByRole('button').map((button) => button.textContent).slice(0, 2))
      .toEqual(['Resend', 'pages.relayDetail.chatSwitchKey']);
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.chatSwitchKey' }));
    expect(onSwitchKey).toHaveBeenCalledTimes(1);
  });
});
