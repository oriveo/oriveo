import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  customFragmentScope,
  loadCustomFragmentSettings,
  saveCustomFragmentSettings,
} from '../../lib/core/chat/custom-fragment-settings';
import { CustomRequestFieldsEditor } from './CustomRequestFieldsEditor';

/**
 * Editor page behavior: **every owner on one page, and the content itself is the state**.
 *
 * There is no one-owner-at-a-time flow, no automatic-versus-custom radio pair deciding what takes
 * effect, and no Apply button gating persistence.
 */
const runtime = vi.hoisted(() => ({
  controlDefinitions: {
    'qwen.web.enable_search': { id: 'qwen.web.enable_search', owner: 'web', targetPointer: '/enable_search', sourceRefs: ['qwen.web_search'] },
    'openai.reasoning.effort': { id: 'openai.reasoning.effort', owner: 'reasoning', targetPointer: '/reasoning/effort', sourceRefs: ['qwen.web_search'] },
  },
  sourceIndex: { 'qwen.web_search': {} },
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${Object.values(values).join(',')}` : key
  ),
}));

vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>(),
  getCapabilityRuntime: () => runtime,
}));

vi.mock('../../lib/core/chat/capability-preference-settings', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/chat/capability-preference-settings')>(),
  capabilityRuntimeIdentity: () => ({
    providerId: '00000000-0000-4000-8000-000000000001',
    canonicalModelId: 'model-1',
    finalTransport: 'openai_chat_completions',
    runtimeRevision: 'r1',
    transportIdentity: 'transport-a',
  }),
}));

const provider = {
  id: 'connection-1', kind: 'qwen', models: [], catalogModels: [],
  status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
} as unknown as Provider;

const model = {
  id: 'model-1', name: 'Model 1', capabilities: ['text'], reasoningModeAvailable: true,
  isAvailable: true, isDefault: true, priceTier: '',
  capabilityControls: {
    web: { state: 'auto_available', customControlRefs: ['qwen.web.enable_search'] },
    reasoning: { state: 'auto_available', customControlRefs: ['openai.reasoning.effort'] },
  },
} as unknown as AIModel;

const webScope = () => customFragmentScope(provider, model, 'transport-a', 'web');

describe('CustomRequestFieldsEditor with every owner on one page', () => {
  beforeEach(() => localStorage.clear());
  afterEach(cleanup);

  it('holds every owner for one connection, model and transport on a single page, ordered web, reasoning, generation, with user-facing section titles', () => {
    render(<CustomRequestFieldsEditor provider={provider} model={model} />);

    const sections = [...document.querySelectorAll('[data-testid^="custom-fields-"]')]
      .map((node) => node.getAttribute('data-testid'))
      .filter((id) => id === 'custom-fields-web' || id === 'custom-fields-reasoning' || id === 'custom-fields-generation');
    expect(sections).toEqual(['custom-fields-web', 'custom-fields-reasoning']);
    // Section titles use the user-facing wording, not the internal web / reasoning identifiers.
    expect(screen.getByText('capabilityControlWebSearch')).toBeTruthy();
    expect(screen.getByText('capabilityControlThinking')).toBeTruthy();
    // There is no automatic-versus-custom radio pair, so the page must contain no radio at all.
    expect(screen.queryAllByRole('radio')).toHaveLength(0);
    // The fixed footer line is always present.
    expect(screen.getByTestId('custom-fields-footer').textContent).toBe('customRequestFieldsFooter');
  });

  it('takes effect once filled and stops once cleared, with no third arm/disarm state in between', () => {
    render(<CustomRequestFieldsEditor provider={provider} model={model} />);
    const textarea = within('custom-fields-web').querySelector('textarea')!;

    fireEvent.change(textarea, { target: { value: '{"enable_search":true}' } });
    expect(loadCustomFragmentSettings(webScope())).toEqual({
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });
    expect(within('custom-fields-web').textContent).toContain('customRequestFieldsInUse');

    fireEvent.change(textarea, { target: { value: '' } });
    expect(loadCustomFragmentSettings(webScope()).configurationMode).toBe('auto');
    // Clearing must not make the whole section vanish while the user is still editing, which would take focus with it.
    expect(screen.getByTestId('custom-fields-web')).toBeTruthy();
    expect(within('custom-fields-web').textContent).not.toContain('customRequestFieldsInUse');
  });

  it('shows three validation preview states: a hint when empty, a redacted path when valid, and the fields this model allows when rejected', () => {
    render(<CustomRequestFieldsEditor provider={provider} model={model} />);
    const web = within('custom-fields-web');
    expect(web.textContent).toContain('customRequestFieldsPreviewHint');

    fireEvent.change(web.querySelector('textarea')!, { target: { value: '{"enable_search":true}' } });
    expect(screen.getByLabelText('customRequestFieldsPreview').textContent).toBe('/enable_search: <redacted>');

    fireEvent.change(within('custom-fields-web').querySelector('textarea')!, { target: { value: '{"not_declared":1}' } });
    expect(screen.getByTestId('custom-fields-error-web').textContent)
      .toBe('customRequestFieldsNotAllowed:/enable_search');
  });

  // Custom field keys on web have no conversation dimension (`storageKey` is connection x model x
  // transport x owner), so arriving from the chat page with a conversationId edits the same record
  // as arriving from the provider detail page. Saying "this conversation" would promise a scope that does not exist.
  it('always describes the scope as connection and model, with or without a conversationId', () => {
    const { unmount } = render(<CustomRequestFieldsEditor provider={provider} model={model} conversationId="conversation-1" />);
    expect(within('custom-fields-web').textContent).toContain('customRequestFieldsScopeConnectionModel');
    expect(within('custom-fields-web').textContent).not.toContain('customRequestFieldsScopeConversation');
    unmount();

    render(<CustomRequestFieldsEditor provider={provider} model={model} />);
    expect(within('custom-fields-web').textContent).toContain('customRequestFieldsScopeConnectionModel');
  });

  it('uses the same connection-and-model wording in the delete confirmation, never saying "this conversation" even with a conversationId', () => {
    saveCustomFragmentSettings(webScope(), { configurationMode: 'custom', raw: '{"enable_search":true}' });
    render(<CustomRequestFieldsEditor provider={provider} model={model} conversationId="conversation-1" />);
    fireEvent.click(screen.getAllByText('customRequestFieldsRemoveConfirm')[0]);
    expect(within('custom-fields-web').textContent)
      .toContain('customRequestFieldsDeleteConnection:capabilityControlWebSearch');
    expect(within('custom-fields-web').textContent).not.toContain('customRequestFieldsDeleteConversation');
  });

  it('requires a second confirmation to remove, and leaves the button disabled while the content is empty', () => {
    saveCustomFragmentSettings(webScope(), { configurationMode: 'custom', raw: '{"enable_search":true}' });
    render(<CustomRequestFieldsEditor provider={provider} model={model} />);

    const reasoningRemove = within('custom-fields-reasoning')
      .querySelector('button') as HTMLButtonElement;
    expect(reasoningRemove.disabled).toBe(true);

    fireEvent.click(screen.getAllByText('customRequestFieldsRemoveConfirm')[0]);
    // The confirmation line also splits by context, and must spell out exactly what this click deletes.
    expect(within('custom-fields-web').textContent).toContain('customRequestFieldsDeleteConnection:capabilityControlWebSearch');
    // The first click only opens the confirmation; not a byte of the config has changed.
    expect(loadCustomFragmentSettings(webScope()).configurationMode).toBe('custom');

    const confirm = [...within('custom-fields-web').querySelectorAll('button')]
      .find((button) => button.textContent === 'customRequestFieldsRemoveConfirm')!;
    fireEvent.click(confirm);
    expect(loadCustomFragmentSettings(webScope())).toEqual({ configurationMode: 'auto', raw: '' });
  });

  it('reports an existing "custom selected but empty" record as an error and offers switching back to automatic', () => {
    // Only older data can reach this state, since clearing the content is what disables it in the current UI.
    localStorage.setItem('oriveo.local-custom-fragments.v2', JSON.stringify({
      [`${provider.id}\u0000${model.id}\u0000transport-a\u0000web`]: { configurationMode: 'custom', raw: '' },
    }));
    render(<CustomRequestFieldsEditor provider={provider} model={model} />);

    expect(screen.getByTestId('custom-fields-legacy-web').textContent).toBe('customRequestFieldsLegacyEmpty');
    fireEvent.click(screen.getByText('customRequestFieldsSwitchBackToAutomatic'));

    expect(loadCustomFragmentSettings(webScope()).configurationMode).toBe('auto');
    expect(screen.queryByTestId('custom-fields-legacy-web')).toBeNull();
  });

  it('shows a single line rather than an empty editor when no owner has a schema for this model and transport', () => {
    const bare = { ...model, capabilityControls: {} } as AIModel;
    render(<CustomRequestFieldsEditor provider={provider} model={bare} />);

    expect(screen.getByTestId('custom-fields-empty').textContent).toBe('customRequestFieldsNoSchemaForModel');
    expect(document.querySelector('textarea')).toBeNull();
  });
});

function within(testID: string): HTMLElement {
  const node = document.querySelector(`[data-testid="${testID}"]`);
  if (!node) throw new Error(`${testID} was not rendered`);
  return node as HTMLElement;
}
