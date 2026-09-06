import React from 'react';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { InputComposer } from './InputComposer';

type Messages = Record<string, unknown>;
const messagesRoot = resolve(process.cwd(), 'messages');
const localeMessages: Record<string, Messages> = Object.fromEntries(
  readdirSync(messagesRoot)
    .filter((file) => file.endsWith('.json'))
    .map((file) => [file.slice(0, -5), JSON.parse(readFileSync(resolve(messagesRoot, file), 'utf8')) as Messages]),
);
let activeLocale = 'en';
const legacyEnglishTestCopy: Record<string, string> = {
  'pages.chat.placeholder': 'Type a message…', 'pages.chat.send': 'Send', 'pages.chat.stop': 'Stop generating', 'pages.chat.aiAnswering': 'AI is answering…',
  'pages.chat.attachFile': 'Attach file', 'pages.chat.attachmentTooLargeTitle': 'File too large', 'pages.chat.attachmentTooLargeMessage': 'Files and images over 50 MB cannot be uploaded. Large uploads are slow on your network and are difficult for AI models to read reliably.', 'pages.chat.attachmentTooLargeAction': 'OK',
  'pages.chat.quoteSelectedContent': 'Selected content', 'pages.chat.quoteFullContext': 'Full quoted context', 'pages.chat.quoteRemove': 'Remove quote', 'pages.chat.relatedNotesTitle': 'Related notes', 'pages.chat.attachNoteContext': 'Attach', 'pages.chat.dismissNoteSuggestion': 'Dismiss',
  'pages.chat.reasoning.auto': 'Search when needed', 'pages.chat.reasoning.fast': 'Fast', 'pages.chat.reasoning.balanced': 'Balanced', 'pages.chat.reasoning.deep': 'Deep', 'pages.chat.reasoning.max': 'Max', 'pages.chat.reasoning.off': 'Off', 'pages.chat.reasoning.supplierDefault': 'Automatic', 'pages.chat.reasoning.force': 'Search every message', 'pages.chat.reasoning.unavailable': 'Unavailable',
  'capability.reasoning': 'Reasoning', 'capability.web': 'Web', 'common.modelBehavior': 'Advanced Settings', 'common.currentConversation': 'Current Conversation', 'common.capabilityControlFixedByConnection': 'Set by this connection',
  'capability.customRequestFieldsConfigurationMode': 'Request field configuration', 'capability.customRequestFieldsAutomatic': 'Oriveo automatic configuration', 'capability.customRequestFieldsCustom': 'Custom request fields', 'capability.customRequestFieldsUnavailable': 'No reviewed custom fields are available for this exact request transport.',
  'library.title': 'Library', 'library.researchButton': 'Research Library', 'library.addContext': 'Add context', 'library.contextDocumentsLabel': 'Document context', 'library.removeDocumentContext': 'Remove document context',
};
function translation(messages: Messages, path: string): string | undefined {
  const value = path.split('.').reduce<unknown>((current, key) => (
    current && typeof current === 'object' ? (current as Record<string, unknown>)[key] : undefined
  ), messages);
  return typeof value === 'string' ? value : undefined;
}

function openModelControls(): HTMLElement {
  const common = localeMessages[activeLocale]!.common as Record<string, string>;
  const button = screen.getByRole('button', { name: common.modelControls });
  if (button.getAttribute('aria-expanded') !== 'true') fireEvent.click(button);
  return button;
}

/** Query scope for the panel once it is open. */
function modelOptionsPanel() {
  openModelControls();
  return within(screen.getByRole('dialog', {
    name: (localeMessages[activeLocale]!.common as Record<string, string>).modelControls,
  }));
}

function escapeForRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Switches to the Advanced Settings pane. The row's accessible name is the whole row text
 * (title + subtitle + "N adjusted"), so match the title as a substring.
 */
function openAdvancedPane() {
  const common = localeMessages[activeLocale]!.common as Record<string, string>;
  fireEvent.click(modelOptionsPanel().getByRole('button', {
    name: new RegExp(escapeForRegExp(common.modelBehavior!)),
  }));
  return modelOptionsPanel();
}

function connectedProvider(kind: Provider['kind'] = 'siliconFlow'): Provider {
  return {
    id: `${kind}-1`,
    kind,
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
  };
}

describe('model controls entry', () => {
  // The entry ignores controlsDisabled / model / identity: anything missing is stated inside the panel, never hidden at the entry.
  it('stays reachable with every capability prop absent and states an honest not-ready list', () => {
    render(<InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false} />);

    const entry = screen.getByRole('button', { name: 'Model Options' }) as HTMLButtonElement;
    expect(entry.disabled).toBe(false);
    fireEvent.click(entry);
    const panel = within(screen.getByRole('dialog', { name: 'Model Options' }));
    for (const name of ['Web Search', 'Thinking Mode', 'Advanced Settings']) {
      expect(panel.getByText(name)).toBeTruthy();
    }
    expect(panel.getAllByText('Not ready')).toHaveLength(3);
    // Pin this read-only sentence verbatim. The save-state sentence ("...can't be saved until the
    // connection...") is easy to swap in here by mistake, but it says the write is blocked rather than
    // "you have not picked a model", and it sends the user off to check a route that does not exist.
    expect(panel.getByText(
      'The connection or model is not ready, so these settings are read-only. Choose a connection and model to continue.',
    )).toBeTruthy();
    expect(panel.queryByText(/can’t be saved until the connection/)).toBeNull();
    // With no model, render no operable control: clicking one would not change any request.
    expect(panel.queryByRole('switch')).toBeNull();
    expect(panel.queryByRole('radio')).toBeNull();
  });
});

const { mockValidateAndConvertFiles, mockLoadAttachmentUtils } = vi.hoisted(() => ({
  mockValidateAndConvertFiles: vi.fn().mockResolvedValue([
    {
      id: 'attachment-1',
      kind: 'image',
      fileName: 'image.jpg',
      mimeType: 'image/jpeg',
      thumbnailBase64: 'thumb',
      localImageID: 'image-1',
    },
  ]),
  mockLoadAttachmentUtils: vi.fn(),
}));

const { mockCapabilityRuntime } = vi.hoisted(() => ({
  mockCapabilityRuntime: { current: undefined as undefined | Record<string, unknown> },
}));

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => (key: string, values?: Record<string, unknown>) => {
    const path = `${namespace}.${key}`;
    const message = translation(localeMessages[activeLocale]!, path) ?? legacyEnglishTestCopy[path] ?? key;
    return message.replace(/\{(\w+)\}/g, (_placeholder, name: string) => String(values?.[name] ?? `{${name}}`));
  },
}));

vi.mock('../../lib/utils/attachment-utils-lazy', () => ({
  loadAttachmentUtils: mockLoadAttachmentUtils,
}));

// Component tests have no metadata cache, so stub only this boundary and let the model's own profile through;
// entry visibility (entryVisible / sessionActionable) keeps the production implementation and is not mocked.
vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    resolveGenerationProfileRef: (ref: unknown) => ref ?? undefined,
    getCapabilityRuntime: () => mockCapabilityRuntime.current,
  };
});

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: {
    preferences: { sendShortcut: 'enter' };
    conversations: unknown[];
    providers: unknown[];
    activeConversationId: null;
  }) => unknown) => selector({
    preferences: { sendShortcut: 'enter' },
    conversations: [],
    providers: [],
    activeConversationId: null,
  }),
}));

afterEach(() => {
  mockValidateAndConvertFiles.mockClear();
  mockLoadAttachmentUtils.mockReset();
  mockLoadAttachmentUtils.mockResolvedValue({
    validateAndConvertFiles: mockValidateAndConvertFiles,
  });
  mockCapabilityRuntime.current = undefined;
  activeLocale = 'en';
  localStorage.clear();
  cleanup();
});

function SentDraftHarness({ initial }: { initial: string }) {
  const [value, setValue] = React.useState(initial);
  return (
    <InputComposer
      value={value}
      onChange={setValue}
      onSend={() => setValue('')}
      isStreaming={false}
    />
  );
}

describe('InputComposer send clears draft', () => {
  const sentText = 'mac ';

  function textarea() {
    return screen.getByRole('textbox', { name: 'Type a message…' }) as HTMLTextAreaElement;
  }

  it('clears the textarea after send', () => {
    render(<SentDraftHarness initial={sentText} />);
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    expect(textarea().value).toBe('');
  });

  it('ignores an IME compositionend that replays the sent text', () => {
    render(<SentDraftHarness initial={sentText} />);
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    fireEvent.compositionEnd(textarea(), { data: sentText });
    fireEvent.change(textarea(), { target: { value: sentText } });
    expect(textarea().value).toBe('');
  });

  it('still accepts a new draft after send', () => {
    render(<SentDraftHarness initial={sentText} />);
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    fireEvent.change(textarea(), { target: { value: 'next question' } });
    expect(textarea().value).toBe('next question');
  });

  it('clears after Enter send and ignores a replayed change', () => {
    render(<SentDraftHarness initial={sentText} />);
    fireEvent.keyDown(textarea(), { key: 'Enter' });
    expect(textarea().value).toBe('');
    fireEvent.change(textarea(), { target: { value: sentText } });
    expect(textarea().value).toBe('');
  });
});

describe('InputComposer', () => {
  // ── "Model Options" panel ─────────────────────────────────────
  //
  // There is no three-section accordion: web search and thinking are one step away on the first
  // screen (high traffic), request parameters live in a second pane (lower traffic), and custom JSON
  // sits one level deeper inside advanced settings (very rare).
  // General rule: there are no greyed-out options. What is selectable renders as selectable; what is
  // not degrades into a clickable status line that gives the reason and a way forward.

  const layoutModel = (overrides: Partial<AIModel> = {}) => ({
    id: 'layout-model', name: 'Layout Model', capabilities: ['text'], isAvailable: true,
    isDefault: true, priceTier: '', transport: 'openai_chat', ...overrides,
  } as unknown as AIModel);

  const control = (
    state: 'auto_available' | 'managed_only' | 'custom_only' | 'unavailable' | 'unknown',
    availableIntents: string[] = [],
    reasonCode?: string,
  ) => ({ state, availableIntents, viaLegacyProfile: false, ...(reasonCode ? { reasonCode } : {}) });

  function renderPanel(props: Partial<React.ComponentProps<typeof InputComposer>> = {}) {
    const result = render(<InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
      currentModel={layoutModel()} generationParameterProvider={connectedProvider()}
      generationParameterConversationId="draft-panel" capabilityTransportIdentity="r1.transport.rev"
      {...props} />);
    openModelControls();
    return result;
  }

  it('uses the model name as the panel header and freezes card order to web search -> thinking -> advanced settings', () => {
    renderPanel({
      webControl: control('auto_available', ['force']),
      reasoningControl: control('auto_available', ['off', 'low']),
      generationControl: control('auto_available'),
      webPreference: 'off', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
    });
    const panel = modelOptionsPanel();
    expect(panel.getByText('Layout Model')).toBeTruthy();
    const sections = screen.getByRole('dialog', { name: 'Model Options' }).textContent ?? '';
    expect(sections.indexOf('Web Search')).toBeLessThan(sections.indexOf('Thinking Mode'));
    expect(sections.indexOf('Thinking Mode')).toBeLessThan(sections.indexOf('Advanced Settings'));
    // Web search and thinking expand in place, so there are no aria-expanded disclosure rows.
    expect(panel.queryByRole('button', { name: 'Web Search' })).toBeNull();
    expect(panel.getByRole('switch', { name: 'Web Search' })).toBeTruthy();
  });

  it('treats web search as a single toggle: on writes automatic, off writes off, and strength is expressed only by search timing', () => {
    const onWebPreferenceChange = vi.fn();
    renderPanel({
      webControl: control('auto_available', ['force']),
      reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange,
    });
    const toggle = modelOptionsPanel().getByRole('switch', { name: 'Web Search' }) as HTMLInputElement;
    expect(toggle.checked).toBe(false);
    // Search timing is not shown while the toggle is off: it asks how eager to be while on.
    expect(screen.queryByRole('radiogroup', { name: 'Search timing' })).toBeNull();
    fireEvent.click(toggle);
    expect(onWebPreferenceChange).toHaveBeenCalledWith('automatic');

    cleanup();
    renderPanel({
      webControl: control('auto_available', ['force']),
      reasoningControl: control('auto_available', ['low']),
      webPreference: 'automatic', onWebPreferenceChange,
    });
    const timing = within(screen.getByRole('radiogroup', { name: 'Search timing' }));
    expect(timing.getAllByRole('radio').map((node) => node.textContent))
      .toEqual(['Search when needed', 'Search every message']);
    expect(timing.getByRole('radio', { name: 'Search when needed' }).getAttribute('aria-checked')).toBe('true');
    fireEvent.click(timing.getByRole('radio', { name: 'Search every message' }));
    expect(onWebPreferenceChange).toHaveBeenLastCalledWith('force');
    expect(screen.getByText('When on, the model searches the web when it helps before answering.')).toBeTruthy();
    // "Search timing" is not a visible heading on iOS or Android.
    // Web keeps the phrase only because `role="radiogroup"` needs an accessible name, and this group
    // cannot reuse the card title: "Web Search" already names the toggle, and two controls sharing a
    // name is the same as no name. So it lives in aria-label only; seeing it in visible text means the
    // dropped heading grew back.
    expect(screen.queryByText('Search timing')).toBeNull();
  });

  it('drops the whole search timing block when the recipe declares no force option, instead of showing a dead grey choice', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'automatic', onWebPreferenceChange: vi.fn(),
    });
    expect(screen.queryByRole('radiogroup', { name: 'Search timing' })).toBeNull();
    expect(screen.queryByRole('radio', { name: 'Search every message' })).toBeNull();
  });

  // Clamping only computes, it never writes: narrowing happens in `persist()`, and `restore()` writes
  // nothing. Writing back on open would fire the mutual-exclusion side effect via `onWebPreferenceChange`
  // (clearing attached library documents) and push an inherited connection-level value down into a
  // session record, when the user only looked at the panel.
  it('shows a stored force value as automatic once the recipe drops that level, without writing back on open', () => {
    const onWebPreferenceChange = vi.fn();
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'force', onWebPreferenceChange,
    });
    expect(onWebPreferenceChange).not.toHaveBeenCalled();
    // The toggle stays on after clamping: the user asked for web search, only the strength was narrowed.
    expect((modelOptionsPanel().getByRole('switch', { name: 'Web Search' }) as HTMLInputElement).checked).toBe(true);
    // Narrowing really happens in the display layer: force is not in the selectable set, so "search when needed" is the checked pill.
    expect(screen.queryByRole('radiogroup', { name: 'Search timing' })).toBeNull();
  });

  it('degrades pending and unknown into honest status lines rather than an escape-hatch toggle', () => {
    renderPanel({
      webControl: control('unknown'), reasoningControl: control('unknown'),
      webPreference: 'automatic', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
      capabilityAlternativeModels: { web: [], reasoning: [] },
    });
    const panel = modelOptionsPanel();
    expect(panel.queryByRole('switch', { name: 'Web Search' })).toBeNull();
    expect(panel.queryByRole('radiogroup', { name: 'Thinking Mode' })).toBeNull();
    expect(panel.getAllByText('Cannot adjust yet')).toHaveLength(2);
  });

  it('gives a reason and a way to switch models when unsupported, without stacking an Unavailable badge on the status line', () => {
    const alternative = { id: 'web-capable', name: 'Web Capable', capabilities: ['text'], isAvailable: true, isDefault: false, priceTier: '' } as unknown as AIModel;
    const onSelectAlternativeModel = vi.fn();
    renderPanel({
      webControl: control('unavailable', [], 'transport_not_supported'),
      reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
      capabilityAlternativeModels: { web: [alternative] }, onSelectAlternativeModel,
    });
    const card = within(screen.getByRole('region', { name: 'Web Search' }));
    expect(card.getByText('Not supported by this model')).toBeTruthy();
    // The status line already says the model does not support this; a badge on the title row says it twice.
    expect(card.queryByText('Unavailable')).toBeNull();
    // A raw reasonCode never reaches the UI.
    expect(screen.getByRole('region', { name: 'Web Search' }).textContent).not.toContain('transport_not_supported');

    fireEvent.click(card.getByRole('button', { name: /Not supported by this model/ }));
    expect(screen.getByText('This model has no official web search configuration. Oriveo doesn’t guess, to avoid failed requests.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'View supported models' }));
    fireEvent.click(screen.getByRole('button', { name: /Web Capable/ }));
    expect(onSelectAlternativeModel).toHaveBeenCalledWith(alternative);
    // The panel closes once the model has been switched.
    expect(screen.queryByRole('dialog', { name: 'Model Options' })).toBeNull();
  });

  it('appends the truth to the description when there are no candidates, offering no dead end into an empty list', () => {
    renderPanel({
      webControl: control('unavailable'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
      capabilityAlternativeModels: { web: [] }, onSelectAlternativeModel: vi.fn(),
    });
    const card = within(screen.getByRole('region', { name: 'Web Search' }));
    fireEvent.click(card.getByRole('button', { name: /Not supported by this model/ }));
    expect(card.getByText('No models in this connection support this capability yet.')).toBeTruthy();
    expect(card.queryByRole('button', { name: 'View supported models' })).toBeNull();
  });

  it('sends the user to advanced settings when customOnly has a schema, and to model switching when it does not', () => {
    mockCapabilityRuntime.current = {
      controlDefinitions: { 'official.web': { id: 'official.web', owner: 'web', targetPointer: '/enable_search', sourceRefs: ['web-doc'] } },
      sourceIndex: { 'web-doc': {} },
    };
    const model = layoutModel({
      capabilityControls: { web: { state: 'custom_only', customControlRefs: ['official.web'] } },
    } as Partial<AIModel>);
    renderPanel({
      currentModel: model,
      generationParameterProvider: connectedProvider('openAI'),
      webControl: control('custom_only'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
      capabilityAlternativeModels: { web: [] },
    });
    const card = within(screen.getByRole('region', { name: 'Web Search' }));
    fireEvent.click(card.getByRole('button', { name: /This connection supports custom configuration only\./ }));
    expect(card.getByRole('button', { name: 'Go to Advanced Settings' })).toBeTruthy();

    cleanup();
    mockCapabilityRuntime.current = undefined;
    renderPanel({
      webControl: control('custom_only'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
      capabilityAlternativeModels: { web: [{ id: 'alt', name: 'Alt', capabilities: ['text'], isAvailable: true, isDefault: false, priceTier: '' } as unknown as AIModel] },
      onSelectAlternativeModel: vi.fn(),
    });
    const noSchema = within(screen.getByRole('region', { name: 'Web Search' }));
    fireEvent.click(noSchema.getByRole('button', { name: /This connection supports custom configuration only\./ }));
    expect(noSchema.queryByRole('button', { name: 'Go to Advanced Settings' })).toBeNull();
    expect(noSchema.getByRole('button', { name: 'View supported models' })).toBeTruthy();
  });

  it('renders thinking as a row of pills: only the levels the recipe ships, Auto always present, annotation following the selection', () => {
    const onReasoningIntentChange = vi.fn();
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['off', 'low', 'deep']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(), onReasoningIntentChange,
    });
    const tiers = within(screen.getByRole('radiogroup', { name: 'Thinking Mode' }));
    expect(tiers.getAllByRole('radio').map((node) => node.textContent))
      .toEqual(['Off', 'Automatic', 'Fast', 'Deep']);
    expect(tiers.getByRole('radio', { name: 'Automatic' }).getAttribute('aria-checked')).toBe('true');
    expect(screen.getByText('The model decides on its own.')).toBeTruthy();
    // There is no separate deep-thinking switch: `off` is simply the first pill in this row.
    expect(screen.queryByRole('switch', { name: 'Deep thinking' })).toBeNull();

    fireEvent.click(tiers.getByRole('radio', { name: 'Fast' }));
    expect(onReasoningIntentChange).toHaveBeenCalledWith('low');
    // "Auto" is a pseudo intent: choosing it injects no level at all.
    fireEvent.click(tiers.getByRole('radio', { name: 'Automatic' }));
    expect(onReasoningIntentChange).toHaveBeenLastCalledWith(undefined);
    fireEvent.click(tiers.getByRole('radio', { name: 'Off' }));
    expect(onReasoningIntentChange).toHaveBeenLastCalledWith('off');
  });

  it('moves the annotation with the selected level instead of listing all six at once', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low', 'deep']),
      reasoningIntent: 'deep', webPreference: 'off', onWebPreferenceChange: vi.fn(),
      onReasoningIntentChange: vi.fn(),
    });
    expect(screen.getByText('Hard questions, take more time.')).toBeTruthy();
    expect(screen.queryByText('Simple questions, fast answers.')).toBeNull();
  });

  it('keeps the "thinking cannot be turned off" footnote when the recipe has no off level', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low', 'deep']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
    });
    expect(screen.queryByRole('radio', { name: 'Off' })).toBeNull();
    expect(screen.getByText('This model cannot turn thinking off.')).toBeTruthy();
  });

  it('degrades a single fixed level into one status line that is deliberately not clickable', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', []),
      webPreference: 'off', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
    });
    const card = within(screen.getByRole('region', { name: 'Thinking Mode' }));
    expect(card.getByText('This model runs at a fixed thinking level and can’t be adjusted.')).toBeTruthy();
    expect(card.queryByRole('radiogroup')).toBeNull();
    expect(card.queryByRole('button')).toBeNull();
  });

  // The catalog can report a capability as fixed for a model. The panel then states that once and
  // offers no control, because nothing the user set here would reach the wire.
  it('renders managed_only controls as view-only', () => {
    const onOpenModelSwitcher = vi.fn();
    renderPanel({
      generationParameterProvider: connectedProvider('openAI'),
      webControl: control('managed_only', []),
      reasoningControl: control('managed_only', []),
      generationControl: control('managed_only'),
      webPreference: 'force', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
      onOpenModelSwitcher,
    });
    const panel = modelOptionsPanel();
    expect(panel.queryByRole('switch')).toBeNull();
    expect(panel.queryByRole('radio')).toBeNull();
    expect(panel.getAllByText('Set by this connection').length).toBeGreaterThanOrEqual(2);
    expect(onOpenModelSwitcher).not.toHaveBeenCalled();
  });

  it('keeps the panel viewable while sending, degrading controls into read-only status lines showing the current value', () => {
    renderPanel({
      isStreaming: true,
      webControl: control('auto_available', ['force']), reasoningControl: control('auto_available', ['low', 'deep']),
      webPreference: 'force', reasoningIntent: 'deep',
      onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
    });
    const panel = modelOptionsPanel();
    expect(panel.getByText('AI is answering…')).toBeTruthy();
    expect(panel.queryByRole('switch')).toBeNull();
    expect(panel.getByText('Search every message')).toBeTruthy();
    expect(panel.getByText('Deep')).toBeTruthy();
  });

  it('pairs every missing-identity reason with the action that actually resolves it', () => {
    // The snapshot never arrived: only fetching again changes this state, so do not send the user off to fix something that is not broken.
    renderPanel({
      capabilityTransportIdentity: undefined,
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    let panel = modelOptionsPanel();
    expect(panel.getByText("Model settings haven't loaded yet, so these are read-only.")).toBeTruthy();
    expect(panel.getByRole('button', { name: 'Fetch again' })).toBeTruthy();
    // Read-only applies to writing, not reading: controls degrade to status lines but the panel still shows the stored values.
    expect(panel.queryByRole('switch')).toBeNull();

    // Snapshot present but the model is not in the catalog: this is the case that should offer "choose another model".
    cleanup();
    const onOpenModelSwitcher = vi.fn();
    mockCapabilityRuntime.current = { recipes: {}, controlDefinitions: {}, sourceIndex: {} };
    renderPanel({
      capabilityTransportIdentity: undefined,
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(), onOpenModelSwitcher,
    });
    panel = modelOptionsPanel();
    expect(panel.getByText("This model isn't in the catalog, so which settings it supports can't be determined.")).toBeTruthy();
    fireEvent.click(panel.getByRole('button', { name: 'Choose another model' }));
    expect(onOpenModelSwitcher).toHaveBeenCalledOnce();
  });

  it('switches to advanced settings horizontally inside the same overlay, with a back key returning to the main pane', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    const advanced = openAdvancedPane();
    // In the second pane the main panel cards are absent: this is the same layer swapping content, not a stacked overlay.
    expect(advanced.queryByRole('region', { name: 'Web Search' })).toBeNull();
    fireEvent.click(advanced.getByRole('button', { name: 'Back' }));
    expect(modelOptionsPanel().getByRole('region', { name: 'Web Search' })).toBeTruthy();
    // The close bar sits outside the scroll area and is reachable from both panes.
    expect(modelOptionsPanel().getByRole('button', { name: 'Close' })).toBeTruthy();
  });

  // "N adjusted" is derived by reading local storage, but the place that changes it is another pane.
  // Switching panes inside the same component does not change provider/model/conversationId, so the
  // useMemo keeps hitting its cache and the row would still show the value from before.
  // This assertion has to go through the real input rather than writing storage directly: only letting
  // production code persist the value proves the row re-reads what it just wrote.
  it('recomputes "N adjusted" after returning from advanced settings instead of showing the stale count', () => {
    const provider = connectedProvider();
    const model = {
      id: 'tuned-model', name: 'Tuned Model', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '', transport: 'openai_chat',
      generationProfile: {
        template: 'openai_chat_completions',
        wire: { temperature: 'temperature' },
        parameters: [{ id: 'temperature', support: 'supported', source: 'user_declared', group: 'sampling', valueSchema: 'number' }],
      },
    } as unknown as AIModel;
    render(
      <InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
        generationParameterProvider={provider} generationParameterConversationId="p16-conversation"
        currentModel={model} />,
    );
    openModelControls();
    expect(modelOptionsPanel().queryByText('1 adjusted')).toBeNull();

    const advanced = openAdvancedPane();
    fireEvent.change(advanced.getByLabelText('Sampling temperature'), { target: { value: '0.7' } });
    fireEvent.click(advanced.getByRole('button', { name: 'Back' }));
    expect(modelOptionsPanel().getByText('1 adjusted')).toBeTruthy();

    // The reverse holds too: after resetting to defaults the row must disappear rather than stick at 1.
    const again = openAdvancedPane();
    fireEvent.change(again.getByLabelText('Sampling temperature'), { target: { value: '' } });
    fireEvent.click(again.getByRole('button', { name: 'Back' }));
    expect(modelOptionsPanel().queryByText('1 adjusted')).toBeNull();
  });

  it('shows no extra explanation group on either card in the normal state', () => {
    renderPanel({
      webControl: control('auto_available', ['force']), reasoningControl: control('auto_available', ['off', 'low']),
      webPreference: 'automatic', onWebPreferenceChange: vi.fn(), onReasoningIntentChange: vi.fn(),
    });
    const web = within(screen.getByRole('region', { name: 'Web Search' }));
    expect(web.queryByRole('button', { name: 'View supported models' })).toBeNull();
    expect(web.queryByText('This field can increase what the provider charges.')).toBeNull();
    const reasoning = within(screen.getByRole('region', { name: 'Thinking Mode' }));
    expect(reasoning.queryByRole('button', { name: 'View supported models' })).toBeNull();
    expect(reasoning.queryByText('This field can increase what the provider charges.')).toBeNull();
  });

  it('says so plainly when the upstream has rejected this setting', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'automatic', onWebPreferenceChange: vi.fn(), webRuntimeRejected: true,
    });
    expect(within(screen.getByRole('region', { name: 'Web Search' }))
      .getByText('The provider rejected this setting for this model. Send again without it, or pick another model.'))
      .toBeTruthy();
  });

  it('closes the panel from both the close bar and Escape', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(screen.queryByRole('dialog', { name: 'Model Options' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Model Options' }).getAttribute('aria-expanded')).toBe('false');

    openModelControls();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog', { name: 'Model Options' })).toBeNull();
  });

  /**
   * Two a11y wires between the entry chip and the overlay.
   *
   * `aria-expanded` on its own is an adjective with no object: a screen reader can say "expanded" but
   * not what is expanded. And failing to return focus on close drops keyboard users back to `<body>`,
   * so the next Tab restarts from the top of the page.
   */
  it('points the chip at the overlay with aria-controls and returns focus to itself on close', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    const chip = screen.getByRole('button', { name: 'Model Options' });
    expect(chip.getAttribute('aria-controls')).toBe(screen.getByRole('dialog', { name: 'Model Options' }).id);

    // Focus is inside the overlay right now (the overlay moved it there on open); this close must hand it back.
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(document.activeElement).toBe(chip);
    // While closed it must not point at an id that does not exist.
    expect(chip.getAttribute('aria-controls')).toBeNull();
  });

  /**
   * Composite behavior: the overlay and the close listener live in two components, so both can pass
   * their own unit tests while being wrong together. Escape inside advanced settings must not blow away
   * the whole panel and force the user back through two levels after editing three parameters.
   */
  it('makes Escape leave only the second pane, keeping the overlay open (behavior of the two components combined)', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    fireEvent.click(modelOptionsPanel().getByText('Advanced Settings'));
    const back = screen.getByRole('button', { name: 'Back' });

    fireEvent.keyDown(back, { key: 'Escape' });

    expect(screen.getByRole('dialog', { name: 'Model Options' }), 'Escape must not close the whole overlay').toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Back' }), 'should have returned to the main pane').toBeNull();

    // Back on the main pane, the same key closes the whole overlay.
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog', { name: 'Model Options' })).toBeNull();
  });

  it('does not steal focus when focus sits outside the overlay (the click-away close)', () => {
    renderPanel({
      webControl: control('auto_available'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
    });
    const textarea = screen.getByRole('textbox');
    textarea.focus();
    expect(document.activeElement).toBe(textarea);

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(screen.queryByRole('dialog', { name: 'Model Options' })).toBeNull();
    // The input the user just clicked must not be taken over: a non-modal overlay owes nothing to "focus returns to the trigger".
    expect(document.activeElement).toBe(textarea);
  });

  // InputComposer only consumes the resolved outbound result; it does not recompute from raw preferences or control state.
  it('lights the chip dot only when the outbound decision actually sends a setting', () => {
    const props = { value: '', onChange: vi.fn(), onSend: vi.fn(), isStreaming: false };
    render(<InputComposer {...props} webControl={control('unknown')} webOutboundActive />);
    expect(screen.getByRole('button', { name: 'Model Options' }).getAttribute('data-emphasized')).toBe('true');

    cleanup();
    render(<InputComposer {...props} webControl={control('auto_available')} webOutboundActive={false} />);
    expect(screen.getByRole('button', { name: 'Model Options' }).getAttribute('data-emphasized')).toBe('false');

    cleanup();
    render(<InputComposer {...props} webControl={control('auto_available')} webOutboundActive webRuntimeRejected />);
    expect(screen.getByRole('button', { name: 'Model Options' }).getAttribute('data-emphasized')).toBe('false');
  });

  it('echoes the real outbound web and reasoning icons on the model options entry, in that order', () => {
    const props = { value: '', onChange: vi.fn(), onSend: vi.fn(), isStreaming: false };
    render(<InputComposer {...props} webOutboundActive reasoningOutboundActive />);

    const entry = screen.getByRole('button', { name: 'Model Options' });
    expect(Array.from(entry.querySelectorAll('[data-capability]')).map((node) =>
      node.getAttribute('data-capability'))).toEqual(['web', 'reasoning']);
    expect(entry.getAttribute('aria-description')).toBe('Web Search - Thinking Mode');

    cleanup();
    render(<InputComposer {...props} webOutboundActive webRuntimeRejected reasoningOutboundActive={false} />);
    const rejectedEntry = screen.getByRole('button', { name: 'Model Options' });
    expect(rejectedEntry.querySelector('[data-capability="web"]')).toBeNull();
    expect(rejectedEntry.querySelector('[data-capability="reasoning"]')).toBeNull();
    expect(rejectedEntry.getAttribute('aria-description')).toBeNull();

  });

  it('renders this panel in all 16 locales without leaking a single key', () => {
    expect(Object.keys(localeMessages)).toHaveLength(16);
    for (const [locale, messages] of Object.entries(localeMessages)) {
      const common = messages.common as Record<string, string>;
      const reasoning = (messages.pages as Record<string, Record<string, Record<string, string>>>).chat!.reasoning!;
      activeLocale = locale;
      render(<InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
        currentModel={layoutModel({ id: `model-${locale}` } as Partial<AIModel>)}
        generationParameterProvider={connectedProvider()}
        generationParameterConversationId={`draft-${locale}`}
        capabilityTransportIdentity="r1.transport.rev"
        webControl={control('auto_available', ['force'])}
        reasoningControl={control('auto_available', ['off', 'low', 'max'])}
        generationControl={control('auto_available')}
        webPreference="automatic" onWebPreferenceChange={vi.fn()} onReasoningIntentChange={vi.fn()} />);
      openModelControls();
      const panel = modelOptionsPanel();
      expect(panel.getByText(common.capabilityControlWebSearch!), `${locale} web card`).toBeTruthy();
      expect(panel.getByText(common.capabilityControlThinking!), `${locale} reasoning card`).toBeTruthy();
      expect(panel.getByRole('radio', { name: reasoning.supplierDefault! }), `${locale} automatic tier`).toBeTruthy();
      expect(panel.getByRole('radio', { name: reasoning.max! }), `${locale} max tier`).toBeTruthy();
      expect(document.body.textContent, `${locale} leaks no key`).not.toMatch(/capabilityControl[A-Z]/);
      cleanup();
    }
  });

  it('drops the duplicate footer link when the status line already offers "view supported models"', () => {
    const alternative = { id: 'alt', name: 'Alt', capabilities: ['text'], isAvailable: true, isDefault: false, priceTier: '' } as unknown as AIModel;
    renderPanel({
      webControl: control('unavailable'), reasoningControl: control('auto_available', ['low']),
      webPreference: 'off', onWebPreferenceChange: vi.fn(),
      capabilityAlternativeModels: { web: [alternative] }, onSelectAlternativeModel: vi.fn(),
    });
    const card = within(screen.getByRole('region', { name: 'Web Search' }));
    // The footer omits the link while the description is collapsed; once expanded it shows inside the description, still only once.
    expect(card.queryAllByRole('button', { name: 'View supported models' })).toHaveLength(0);
    fireEvent.click(card.getByRole('button', { name: /Not supported by this model/ }));
    expect(card.getAllByRole('button', { name: 'View supported models' })).toHaveLength(1);
  });

  it('keeps the model behavior entry for every chat model, stating a missing auto configuration honestly inside the panel', () => {
    const provider = connectedProvider();
    const model = {
      id: 'model-1', name: 'Model 1', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '', transport: 'openai_chat',
      generationProfile: {
        template: 'openai_chat_completions',
        wire: { temperature: 'temperature' },
        parameters: [{ id: 'temperature', support: 'supported', source: 'user_declared', group: 'sampling', valueSchema: 'number' }],
      },
    } as unknown as AIModel;
    const { rerender } = render(
      <InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
        generationParameterProvider={provider} generationParameterConversationId="draft-1" currentModel={model} />,
    );
    // The entry row is always present: a model without a generationProfile only changes the empty state of the second pane.
    expect(modelOptionsPanel().getByRole('button', {
      name: new RegExp(escapeForRegExp('Advanced Settings')),
    })).toBeTruthy();

    rerender(
      <InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
        generationParameterProvider={provider}
        generationParameterConversationId="draft-1"
        currentModel={{ ...model, generationProfile: undefined } as AIModel} />,
    );
    expect(modelOptionsPanel().getByRole('button', {
      name: new RegExp(escapeForRegExp('Advanced Settings')),
    })).toBeTruthy();
  });

  // Rule: an unavailable chip is hidden, and an available chip always has content behind it.
  // Session scope ignores the engine_runtime permission, so a model that only declares
  // engine_runtime parameters still shows the chip when a host withholds it. A second filter here
  // would produce "the chip says yes, opening it says no".
  // That filter belongs to connection scope only (the detail page container).
  it('keeps the model behavior entry for engine_runtime parameters even when a host withholds them', () => {
    const provider = connectedProvider();
    const model = {
      id: 'model-2', name: 'Model 2', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '', transport: 'openai_chat',
      generationProfile: {
        template: 'openai_chat_completions',
        wire: { n_ctx: 'n_ctx' },
        parameters: [{ id: 'n_ctx', support: 'supported', source: 'user_declared', group: 'engine_runtime', valueSchema: 'integer' }],
      },
    } as unknown as AIModel;

    render(
      <InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
        generationParameterProvider={provider} generationParameterConversationId="draft-2" currentModel={model} />,
    );
    openAdvancedPane();
    expect(screen.getAllByLabelText('Advanced Settings').length).toBeGreaterThanOrEqual(1);
  });

  it('shows pending quote above the editor, removes it accessibly, and quote alone keeps Send disabled', () => {
    const onRemoveQuote = vi.fn();
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        quoteContext={{
          schemaVersion: 1,
          sourceMessageId: 'source-1',
          sourceRole: 'assistant',
          contentKind: 'prose',
          leadingText: 'before ',
          selectedText: 'selected content',
          trailingText: ' after',
          contextTruncated: false,
        }}
        onRemoveQuote={onRemoveQuote}
      />,
    );

    expect((screen.getByRole('button', { name: 'Send' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('button', { name: /Selected content: selected content/ })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Remove quote' }));
    expect(onRemoveQuote).toHaveBeenCalledOnce();
  });

  // The composer carries a single Library button: it does not toggle research directly but opens the
  // unified panel, where both scope search and specific documents are chosen. The button shows an
  // active state while research is on, which is the only state left on the composer.
  it('exposes a single Library entry that opens the panel and reflects research state', () => {
    const onAddLibraryContext = vi.fn();
    const { rerender } = render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        libraryResearchEnabled={false}
        onAddLibraryContext={onAddLibraryContext}
      />,
    );

    // There are no separate side-by-side buttons.
    expect(screen.queryByRole('button', { name: 'Research Library' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Add context' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Library' }));
    expect(onAddLibraryContext).toHaveBeenCalledOnce();

    rerender(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        libraryResearchEnabled
        onAddLibraryContext={onAddLibraryContext}
      />,
    );
    expect(
      screen.getByRole('button', { name: 'Library' }).getAttribute('data-active'),
    ).toBe('true');
  });

  it('opens the Library panel and renders removable selected document chips', () => {
    const onAddLibraryContext = vi.fn();
    const onDetachLibraryContext = vi.fn();
    const document = {
      docId: 'roadmap',
      source: 'notion' as const,
      title: 'Q3 Roadmap',
    };

    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        libraryContextDocuments={[document]}
        onAddLibraryContext={onAddLibraryContext}
        onDetachLibraryContext={onDetachLibraryContext}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Library' }));
    expect(onAddLibraryContext).toHaveBeenCalledOnce();
    expect(screen.getByText('Q3 Roadmap')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Remove document context: Q3 Roadmap' }));
    expect(onDetachLibraryContext).toHaveBeenCalledWith(document);
  });

  it('grows the textarea immediately as multiline input is typed', () => {
    const onChange = vi.fn();

    render(
      <InputComposer
        value=""
        onChange={onChange}
        onSend={vi.fn()}
        isStreaming={false}
      />,
    );

    const textarea = screen.getByRole('textbox', { name: 'Type a message…' }) as HTMLTextAreaElement;
    Object.defineProperty(textarea, 'scrollHeight', {
      configurable: true,
      value: 156,
    });

    fireEvent.change(textarea, { target: { value: 'first\nsecond\nthird\nfourth' } });

    expect(onChange).toHaveBeenCalledWith('first\nsecond\nthird\nfourth');
    expect(textarea.style.height).toBe('156px');
  });

  it('caps textarea growth and scrolls internally for very long drafts', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
      />,
    );

    const textarea = screen.getByRole('textbox', { name: 'Type a message…' }) as HTMLTextAreaElement;
    Object.defineProperty(textarea, 'scrollHeight', {
      configurable: true,
      value: 260,
    });

    fireEvent.change(textarea, { target: { value: Array.from({ length: 20 }, (_, i) => `line ${i}`).join('\n') } });

    expect(textarea.style.height).toBe('200px');
    expect(textarea.style.overflowY).toBe('auto');
  });

  it('hides attachment button when provider supports no attachment types', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        currentModel={{
          id: 'model-1',
          name: 'Model 1',
          capabilities: ['text', 'image'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: false, nativeFile: false, textFileInline: false }}
      />,
    );

    expect(screen.queryByRole('button', { name: 'Attach file' })).toBeNull();
  });

  it('shows attachment button when provider supports text files only (no image)', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        currentModel={{
          id: 'model-1',
          name: 'Model 1',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: false, nativeFile: false, textFileInline: true }}
      />,
    );

    // A textFileInline=true provider receives text attachments through local extraction, so the attachment button shows even without image support
    expect(screen.getByRole('button', { name: 'Attach file' })).toBeTruthy();
  });

  it('shows attachment button when both model and provider support image', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        onAttachmentsChange={vi.fn()}
        currentModel={{
          id: 'model-1',
          name: 'Model 1',
          capabilities: ['text', 'image'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: true, nativeFile: false, textFileInline: true }}
      />,
    );

    expect(screen.getByRole('button', { name: 'Attach file' })).toBeTruthy();
  });

  it('shows attachment button for textFileInline provider with file capability (SiliconFlow VL)', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        onAttachmentsChange={vi.fn()}
        generationParameterProvider={connectedProvider()}
        currentModel={{
          id: 'qwen-vl',
          name: 'Qwen VL',
          capabilities: ['text', 'image', 'file'],
          transport: 'openai_chat',
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: true, nativeFile: false, textFileInline: true }}
      />,
    );

    expect(screen.getByRole('button', { name: 'Attach file' })).toBeTruthy();

    // The file picker accept list must not include .pdf (textFileInline does not support PDF)
    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    expect(fileInput).toBeTruthy();
    expect(fileInput.accept).not.toContain('.pdf');
    expect(fileInput.accept).toContain('.txt');
    expect(fileInput.accept).toContain('.py');
    expect(fileInput.accept).toContain('image/*');
  });

  it('includes .pdf in accept when provider supports nativeFile', () => {
    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        onAttachmentsChange={vi.fn()}
        currentModel={{
          id: 'claude-sonnet',
          name: 'Claude Sonnet',
          capabilities: ['text', 'image', 'file'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: true, nativeFile: true, textFileInline: true }}
      />,
    );

    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    expect(fileInput).toBeTruthy();
    expect(fileInput.accept).toContain('.pdf');
  });

  it('loads attachment conversion lazily when selecting files', async () => {
    const onAttachmentsChange = vi.fn();

    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        onAttachmentsChange={onAttachmentsChange}
        currentModel={{
          id: 'model-1',
          name: 'Model 1',
          capabilities: ['text', 'image'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: true, nativeFile: false, textFileInline: true }}
      />,
    );

    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    const file = new File(['img'], 'photo.png', { type: 'image/png' });

    fireEvent.change(fileInput, { target: { files: [file] } });

    expect(mockLoadAttachmentUtils).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      expect(mockValidateAndConvertFiles).toHaveBeenCalledWith([file], 'file', undefined);
      expect(onAttachmentsChange).toHaveBeenCalledWith([
        expect.objectContaining({ id: 'attachment-1', kind: 'image' }),
      ]);
    });
  });

  it('snapshots selected files before clearing a live file input', async () => {
    const onAttachmentsChange = vi.fn();
    mockLoadAttachmentUtils.mockImplementation(async () => {
      await Promise.resolve();
      return {
        validateAndConvertFiles: mockValidateAndConvertFiles,
      };
    });

    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        onAttachmentsChange={onAttachmentsChange}
        currentModel={{
          id: 'model-1',
          name: 'Model 1',
          capabilities: ['text', 'image'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '$',
        }}
        providerAttachmentSupport={{ image: true, nativeFile: false, textFileInline: true }}
      />,
    );

    const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
    const file = new File(['img'], 'photo.png', { type: 'image/png' });
    let cleared = false;
    let currentValue = '';
    const liveFiles = {
      0: file,
      length: 1,
      item: (index: number) => (cleared || index !== 0 ? null : file),
      *[Symbol.iterator]() {
        if (!cleared) {
          yield file;
        }
      },
    } as unknown as FileList;

    Object.defineProperty(fileInput, 'files', {
      configurable: true,
      get: () => liveFiles,
    });
    Object.defineProperty(fileInput, 'value', {
      configurable: true,
      get: () => currentValue,
      set: (next: string) => {
        currentValue = next;
        cleared = true;
      },
    });

    fireEvent.change(fileInput);

    await vi.waitFor(() => {
      expect(mockValidateAndConvertFiles).toHaveBeenCalledWith([file], 'file', undefined);
    });
    expect(onAttachmentsChange).toHaveBeenCalledWith([
      expect.objectContaining({ id: 'attachment-1', kind: 'image' }),
    ]);
  });

  it('shows related note suggestions and calls attach/dismiss actions', () => {
    const onAttach = vi.fn();
    const onDismiss = vi.fn();

    render(
      <InputComposer
        value="vector database"
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        relatedNotes={[
          { id: 'note-1', title: 'Vector recall', score: 12, sourceLabel: 'OpenAI - GPT-5' },
          { id: 'note-2', title: 'Prompt context', score: 8, sourceLabel: 'Claude Sonnet' },
        ]}
        onAttachRelatedNote={onAttach}
        onDismissRelatedNote={onDismiss}
      />,
    );

    expect(screen.getByText('Notes you can bring into this chat')).toBeTruthy();
    expect(screen.getByText('Vector recall')).toBeTruthy();
    expect(screen.getByText('OpenAI - GPT-5')).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: 'Bring in' })[0]);
    expect(onAttach).toHaveBeenCalledWith('note-1');
    fireEvent.click(screen.getAllByRole('button', { name: 'Dismiss' })[1]);
    expect(onDismiss).toHaveBeenCalledWith('note-2');
  });

  it('renders attached note chips with a placeholder override and detaches on click', () => {
    const onDetach = vi.fn();

    render(
      <InputComposer
        value=""
        onChange={vi.fn()}
        onSend={vi.fn()}
        isStreaming={false}
        attachedNotes={[{ id: 'note-1', title: 'My hometown' }]}
        onDetachNote={onDetach}
        placeholderOverride="Ask anything about “My hometown”…"
      />,
    );

    // The chip shows pinned note titles; the input stays empty with a tailored placeholder that prompts the real intent
    expect(screen.getByText('My hometown')).toBeTruthy();
    expect(screen.getByPlaceholderText('Ask anything about “My hometown”…')).toBeTruthy();

    // The remove button (aria uses the removeNoteContext key) calls back with the right noteId
    fireEvent.click(screen.getByRole('button', { name: 'Remove context: My hometown' }));
    expect(onDetach).toHaveBeenCalledWith('note-1');
  });
});

// ── Vocabulary freeze ─────────────────────
//
// Layout assertions live in `lib/core/chat/model-control-capability-layout.test.ts` as direct
// pure-function tests; what stays here is the vocabulary check, which must read the real locale
// bundles and cannot be covered by a pure function.
describe('model control vocabulary', () => {
  it('freezes the English wording for the thinking and web search levels', () => {
    activeLocale = 'en';
    const reasoning = (localeMessages.en!.pages as Record<string, Record<string, Record<string, string>>>)
      .chat!.reasoning!;
    expect(reasoning.max).toBe('Max');
    expect(reasoning.force).toBe('Search every message');
    expect(reasoning.auto).toBe('Search when needed');
    // The `automatic` level is labelled "auto"; there is no "supplier default" concept.
    // Web search levels use their own wording, so the two groups never compete for the same word.
    expect(reasoning.supplierDefault).toBe('Automatic');

    render(<InputComposer value="" onChange={vi.fn()} onSend={vi.fn()} isStreaming={false}
      currentModel={{ id: 'en-model', name: 'Model', capabilities: ['text'], isAvailable: true, isDefault: true, priceTier: '', transport: 'openai_chat' } as unknown as AIModel}
      generationParameterProvider={connectedProvider()} generationParameterConversationId="draft-en"
      capabilityTransportIdentity="r1.transport.rev"
      webControl={{ state: 'auto_available', availableIntents: ['force'], viaLegacyProfile: false }}
      reasoningControl={{ state: 'auto_available', availableIntents: ['off', 'low', 'balanced', 'deep', 'max'], viaLegacyProfile: false }}
      webPreference="automatic" onWebPreferenceChange={vi.fn()} onReasoningIntentChange={vi.fn()} />);
    const panel = modelOptionsPanel();
    expect(panel.getByRole('radio', { name: 'Max' })).toBeTruthy();
    expect(panel.getByRole('radio', { name: 'Search every message' })).toBeTruthy();
    expect(panel.getByRole('radio', { name: 'Automatic' })).toBeTruthy();
  });

  it('keeps the zh-Hans wording byte-identical to Android', () => {
    // The vocabulary freeze spans clients: checking only the web bundle lets the next change drift.
    // The Android resource table lives in the same repository, so compare against it directly.
    const android = readFileSync(
      resolve(process.cwd(), '../../../android/app/src/main/res/values-zh-rCN/strings.xml'),
      'utf8',
    );
    const androidString = (name: string) => {
      const match = android.match(new RegExp(`<string name="${name}">([\\s\\S]*?)</string>`));
      if (!match) throw new Error(`Android   ${name}`);
      return match[1]!;
    };
    const web = (localeMessages['zh-Hans']!.pages as Record<string, Record<string, Record<string, string>>>)
      .chat!.reasoning!;
    const common = localeMessages['zh-Hans']!.common as Record<string, string>;
    expect(web.max).toBe(androidString('reasoning_max'));
    expect(web.force).toBe(androidString('model_control_web_search_every_message'));
    expect(web.supplierDefault).toBe(androidString('model_control_supplier_default'));
    expect(web.off).toBe(androidString('model_control_off'));
    expect(web.auto).toBe(androidString('model_control_web_search_when_needed'));
    expect(common.modelControls).toBe(androidString('model_controls'));
    expect(common.modelBehavior).toBe(androidString('generation_model_behavior'));
    // The six level annotations are frozen across clients in the same way.
    for (const [webKey, androidKey] of [
      ['capabilityControlReasoningNoteOff', 'model_control_reasoning_note_off'],
      ['capabilityControlReasoningNoteAutomatic', 'model_control_reasoning_note_automatic'],
      ['capabilityControlReasoningNoteFast', 'model_control_reasoning_note_fast'],
      ['capabilityControlReasoningNoteBalanced', 'model_control_reasoning_note_balanced'],
      ['capabilityControlReasoningNoteDeep', 'model_control_reasoning_note_deep'],
      ['capabilityControlReasoningNoteMax', 'model_control_reasoning_note_max'],
    ] as const) {
      expect(common[webKey]).toBe(androidString(androidKey));
    }
  });

  it('ships the panel copy in all 16 locales, with no non-English bundle left in English', () => {
    expect(Object.keys(localeMessages)).toHaveLength(16);
    const keys = [
      'modelControls', 'modelBehavior', 'capabilityControlFixedByConnection',
      'capabilityControlWebSearch', 'capabilityControlThinking', 'capabilityControlWebSwitchNote',
      'capabilityControlSearchTiming', 'capabilityControlNotSupportedByModel',
      'capabilityControlCannotAdjustYet', 'capabilityControlWebNoOfficialConfig',
      'capabilityControlReasoningNoOfficialConfig', 'capabilityControlReasoningFixedLevel',
      'capabilityControlReasoningOffUnavailable', 'capabilityControlCustomOnlyReason',
      'capabilityControlUnavailableForConnection', 'capabilityControlViewSupportedModels',
      'capabilityControlNoSupportedModels', 'capabilityControlGoToAdvancedSettings',
      'capabilityControlChooseAnotherModel',
      'capabilityControlSupportedModelsIntro', 'capabilityControlSwitchToModel',
      'capabilityControlBadgeCustom', 'capabilityControlBadgeManual',
      'capabilityControlUpstreamRejected', 'capabilityControlAdjustedCount',
      'capabilityControlIdentityRuntimeMissing', 'capabilityControlIdentityRelayTransport',
      'capabilityControlIdentityModelMissing', 'capabilityControlFetchAgain',
      'capabilityControlFetching', 'capabilityControlFetchFailed', 'capabilityControlSetProtocol',
      'capabilityPreferencesUnavailable', 'capabilityControlsReadOnlyConversation',
      'capabilityControlMissingModelReadOnly',
    ];
    const SHARED_WORD_KEYS = new Set(['capabilityControlBadgeManual', 'capabilityControlBadgeCustom']);
    const english = localeMessages.en!.common as Record<string, string>;
    for (const [locale, messages] of Object.entries(localeMessages)) {
      const common = messages.common as Record<string, string>;
      for (const key of keys) {
        expect(common[key]?.trim(), `${locale} has ${key}`).toBeTruthy();
        // Short badge words are identical to English in several languages (Manual / Custom), so forcing "must differ" would produce fake translations.
        if (locale !== 'en' && !SHARED_WORD_KEYS.has(key)) {
          expect(common[key], `${locale} translates ${key}`).not.toBe(english[key]);
        }
      }
    }
  });

  // These shapes do not exist in the panel, so their keys must not exist in the 16 locale bundles
  // either: an unused entry makes the next reader think it is still in use.
  it('retires the vocabulary of the forms that no longer exist', () => {
    const retired = [
      'capabilityControlForceUnavailable', 'capabilityControlWebAutoExpectation',
      'capabilityControlReasoningSwitch', 'capabilityControlReasoningOffNote',
      'capabilityControlTierCostNote', 'capabilityControlFixedTier',
      'capabilityControlAutomatic', 'capabilityControlStateRuntimeRejected',
      'capabilityControlStateFree', 'capabilityControlStateManagedAI',
      'capabilityControlManagedFreeReason', 'capabilityControlManagedAIReason',
      'capabilityControlSwitchModel', 'capabilityControlNoAlternativeModel',
      // The upgrade row has its own `capabilityControlScope*` keys, and these three synonyms are
      // word-for-word identical to them: from the bundles alone you cannot tell which set is live.
      // A translation with zero references is a trap.
      'capabilityControlAppliedToConversation', 'capabilityControlSetAsModelDefault',
      'capabilityControlModelDefaultSaved',
    ];
    for (const [locale, messages] of Object.entries(localeMessages)) {
      const common = messages.common as Record<string, unknown>;
      for (const key of retired) expect(common[key], `${locale} still ships ${key}`).toBeUndefined();
    }
  });

  it('replaces the clear-learned-capabilities wording with one that names its object, in all 16 locales', () => {
    const english = (localeMessages.en!.common as Record<string, string>).generationParameterClearLearnedCapabilities;
    expect(english).toBe('Clear learned parameter support');
    for (const [locale, messages] of Object.entries(localeMessages)) {
      const value = (messages.common as Record<string, string>).generationParameterClearLearnedCapabilities;
      expect(value?.trim(), `${locale} has the key`).toBeTruthy();
      if (locale !== 'en') expect(value, `${locale} translates it`).not.toBe(english);
    }
  });

  /**
   * The delete-confirmation sentence follows a single wording shape across clients:
   * "This removes ..., and cannot be undone." Two shapes coexisting means the bundles cannot say
   * which one is live.
   */
  it('keeps the delete-confirmation sentence in the shared wording shape', () => {
    const english = (localeMessages.en!.common as Record<string, string>).customRequestFieldsDeleteConnection;
    expect(english).toMatch(/cannot be undone/i);
    for (const [locale, messages] of Object.entries(localeMessages)) {
      const value = (messages.common as Record<string, string>).customRequestFieldsDeleteConnection;
      expect(value?.trim(), `${locale} has the key`).toBeTruthy();
      if (locale !== 'en') expect(value, `${locale} translates it`).not.toBe(english);
    }
  });
});
