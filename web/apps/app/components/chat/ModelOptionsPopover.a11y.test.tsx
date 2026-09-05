import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { encodeCapabilityTransportIdentity } from '../../lib/core/chat/capability-preference-settings';
import { MODEL_OPTIONS_POPOVER_ID, ModelOptionsPopover } from './ModelOptionsPopover';

/**
 * Keyboard and screen reader contract for the model options popover.
 *
 * Every case here targets a defect only a keyboard or screen reader user would hit: the panel
 * opens but focus stays elsewhere, `role="radiogroup"` promises arrow keys and does nothing, Esc
 * blows away the whole panel from a third-level pane, or a fully disabled advanced settings page
 * explains nothing. None of it is visible with a mouse, so assertions are the only guard.
 *
 * Each assertion is written so that it fails without the behavior it names:
 *  - focus: without it, activeElement is body after opening and Tab goes to the send button;
 *  - Esc: without it, Esc inside advanced settings closes the whole popover;
 *  - radiogroup: without it, every pill is tabIndex 0 and the arrow keys do nothing;
 *  - read-only banner: without it, the banner renders only in the main pane;
 *  - customOnly: without it, the expanded block reprints the status line verbatim.
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

const CONVERSATION_ID = 'B0000000-0000-0000-0000-000000000001';
/** Web search on plus a recipe declaring force => the two "search timing" pills appear. */
const webControl = { state: 'auto_available' as const, availableIntents: ['off', 'automatic', 'force'], viaLegacyProfile: false };
/** All six thinking tiers sent => pillRow layout. */
const reasoningControl = {
  state: 'auto_available' as const,
  availableIntents: ['off', 'low', 'balanced', 'deep', 'max'],
  viaLegacyProfile: false,
};

function popoverElement(overrides: Record<string, unknown>) {
  return (
    <ModelOptionsPopover
      provider={provider}
      model={model}
      conversationId={CONVERSATION_ID}
      webControl={webControl}
      reasoningControl={reasoningControl}
      transportIdentity={TRANSPORT_IDENTITY}
      webPreference="automatic"
      onWebPreferenceChange={() => {}}
      onReasoningIntentChange={() => {}}
      onClose={() => {}}
      {...overrides}
    />
  );
}

/**
 * The panel is controlled: the selection comes from a prop, not from internal state. An assertion
 * about two arrow presses in a row therefore has to feed the new value back in -- without that,
 * the second press starts from the same selection and the test is not measuring movement at all.
 */
function open(overrides: Record<string, unknown> = {}) {
  const view = render(popoverElement(overrides));
  return {
    ...view,
    apply: (next: Record<string, unknown>) => view.rerender(popoverElement({ ...overrides, ...next })),
  };
}

const popover = () => screen.getByRole('dialog', { name: 'common.modelControls' });
const openAdvanced = () => fireEvent.click(screen.getByText('common.modelBehavior'));

describe('WQA-6 / WSM-11 - focus and aria wiring', () => {
  afterEach(cleanup);

  it('the container is a named dialog carrying an id the mounting aria-controls can reach', () => {
    open();
    expect(popover().id).toBe(MODEL_OPTIONS_POPOVER_ID);
    // A non-modal popover does not trap focus, so it must not claim aria-modal, which would be a promise it cannot keep.
    expect(popover().getAttribute('aria-modal')).toBeNull();
  });

  it('opening moves focus into the panel instead of leaving it on body', () => {
    open();
    // The chip comes after the popover in the DOM, so without moving focus the next Tab stop is the send button rather than a control in the panel.
    expect(document.activeElement).toBe(popover());
    expect(popover().getAttribute('tabindex')).toBe('-1');
  });

  it('entering a secondary pane puts focus on the back button, the only way out of that screen', () => {
    open();
    openAdvanced();
    expect(document.activeElement).toBe(screen.getByLabelText('common.back'));
  });

  it('returning to the main pane puts focus back on the panel container, not on body', () => {
    open();
    openAdvanced();
    fireEvent.click(screen.getByLabelText('common.back'));
    expect(document.activeElement).toBe(popover());
  });

  it('Esc in a secondary pane goes back one level rather than closing the popover', () => {
    const onClose = vi.fn();
    open({ onClose });
    openAdvanced();
    expect(screen.getByLabelText('common.back')).toBeTruthy();

    fireEvent.keyDown(document, { key: 'Escape' });

    // Back on the main pane: the secondary header back button is gone and the web search card is present again.
    expect(screen.queryByLabelText('common.back')).toBeNull();
    expect(screen.getByRole('switch')).toBeTruthy();
    // The close listener lives on the mounting side (InputComposer); this only asserts it was not triggered by that key.
    expect(onClose).not.toHaveBeenCalled();
  });

  it('Esc in the main pane is not swallowed, so the mounting close listener still receives it', () => {
    open();
    const seen: string[] = [];
    const listener = (event: KeyboardEvent) => seen.push(event.key);
    document.addEventListener('keydown', listener);
    try {
      fireEvent.keyDown(document, { key: 'Escape' });
    } finally {
      document.removeEventListener('keydown', listener);
    }
    expect(seen).toEqual(['Escape']);
  });
});

describe('WQA-9 - roving tabindex and arrow keys in the radiogroup', () => {
  afterEach(cleanup);

  const timingGroup = () => screen.getByRole('radiogroup', { name: 'common.capabilityControlSearchTiming' });
  const thinkingGroup = () => screen.getByRole('radiogroup', { name: 'common.capabilityControlThinking' });

  it('the whole group occupies a single Tab stop: only the selected pill has tabIndex=0', () => {
    open();
    for (const group of [timingGroup(), thinkingGroup()]) {
      const radios = within(group).getAllByRole('radio');
      expect(radios.length).toBeGreaterThan(1);
      const focusable = radios.filter((radio) => radio.tabIndex === 0);
      expect(focusable, `${group.getAttribute('aria-label')} should expose exactly one tab stop`).toHaveLength(1);
      expect(focusable[0].getAttribute('aria-checked')).toBe('true');
    }
  });

  it('arrow keys move the selection, the standard radio group behavior, not focus alone', () => {
    const onWebPreferenceChange = vi.fn();
    const { apply } = open({ onWebPreferenceChange });
    const radios = within(timingGroup()).getAllByRole('radio');

    fireEvent.keyDown(timingGroup(), { key: 'ArrowRight' });
    expect(onWebPreferenceChange).toHaveBeenLastCalledWith('force');
    // Focus follows the selection; changing the selection without moving focus leaves a screen reader silent about the new choice.
    expect(document.activeElement).toBe(radios[1]);

    apply({ webPreference: 'force' });
    fireEvent.keyDown(timingGroup(), { key: 'ArrowLeft' });
    expect(onWebPreferenceChange).toHaveBeenLastCalledWith('automatic');

    // Wraps around: pressing right on the last pill returns to the first.
    apply({ webPreference: 'force' });
    fireEvent.keyDown(timingGroup(), { key: 'ArrowRight' });
    expect(onWebPreferenceChange).toHaveBeenLastCalledWith('automatic');
  });

  it('Home / End jump to either end', () => {
    const onReasoningIntentChange = vi.fn();
    open({ onReasoningIntentChange });
    fireEvent.keyDown(thinkingGroup(), { key: 'End' });
    expect(onReasoningIntentChange).toHaveBeenLastCalledWith('max');
    fireEvent.keyDown(thinkingGroup(), { key: 'Home' });
    expect(onReasoningIntentChange).toHaveBeenLastCalledWith('off');
  });

  it('selecting the pseudo intent "automatic" stores an empty value and injects no tier', () => {
    const onReasoningIntentChange = vi.fn();
    open({ onReasoningIntentChange, reasoningIntent: 'deep' });
    fireEvent.click(screen.getByRole('radio', { name: 'pages.chat.reasoning.supplierDefault' }));
    expect(onReasoningIntentChange).toHaveBeenCalledWith(undefined);
  });

  it('in RTL the left and right arrows follow the reading direction, while up and down do not', () => {
    document.documentElement.dir = 'rtl';
    try {
      const onReasoningIntentChange = vi.fn();
      const { apply } = open({ onReasoningIntentChange, reasoningIntent: 'balanced' });
      // Tier order: off -> automatic -> fast (low) -> balanced -> deep -> max.
      // In LTR, ArrowRight means "next" = deep; in RTL it has to mean "previous" = low.
      fireEvent.keyDown(thinkingGroup(), { key: 'ArrowRight' });
      expect(onReasoningIntentChange).toHaveBeenLastCalledWith('low');

      apply({ reasoningIntent: 'balanced' });
      fireEvent.keyDown(thinkingGroup(), { key: 'ArrowLeft' });
      expect(onReasoningIntentChange).toHaveBeenLastCalledWith('deep');

      // Up and down are independent of reading direction; they mean next and previous in both layouts.
      apply({ reasoningIntent: 'balanced' });
      fireEvent.keyDown(thinkingGroup(), { key: 'ArrowDown' });
      expect(onReasoningIntentChange).toHaveBeenLastCalledWith('deep');
    } finally {
      document.documentElement.dir = '';
    }
  });
});

describe('WQA-1 - the read-only banner also renders in the advanced settings pane', () => {
  afterEach(cleanup);

  const banner = () => screen.queryByTestId('model-control-read-only-banner');

  it('runtimeReadOnly: both the main pane and the advanced settings pane state the reason', () => {
    open({ runtimeIsReadOnly: true, runtimeReadOnlyReason: ' ' });
    expect(banner()?.textContent).toContain(' ');

    openAdvanced();

    // Without the banner this pane is fully disabled with no explanation and no way out.
    expect(banner(), 'the advanced settings pane is missing the read-only explanation').not.toBeNull();
    expect(banner()!.textContent).toContain(' ');
  });

  it('missing identity: the advanced settings pane also carries the action that resolves it', () => {
    const onOpenModelSwitcher = vi.fn();
    // Runtime ready and not a relay => the gap is that this model is not in the catalog, and the only way out is switching models.
    open({ transportIdentity: undefined, onOpenModelSwitcher });
    openAdvanced();
    expect(banner()!.textContent).toContain('common.capabilityControlIdentityModelMissing');
    fireEvent.click(within(banner()!).getByText('common.capabilityControlChooseAnotherModel'));
    expect(onOpenModelSwitcher).toHaveBeenCalled();
  });

  it('when writable, neither pane renders a banner, so the normal state has no extra grey block', () => {
    open();
    expect(banner()).toBeNull();
    openAdvanced();
    expect(banner()).toBeNull();
  });
});

describe('WSM-17 - expanding a customOnly status line does not repeat the same sentence', () => {
  afterEach(cleanup);

  const customOnly = { state: 'custom_only' as const, availableIntents: [], viaLegacyProfile: false };

  const otherModel = { ...model, id: 'model-2', name: 'Model 2' } as AIModel;

  it(' ', () => {
    // customOnly with no locally editable schema => the way out is "view supported models", provided candidates exist.
    open({ webControl: customOnly, alternativeModels: { web: [otherModel] } });
    fireEvent.click(screen.getByRole('button', { name: /capabilityControlCustomOnlyReason/ }));

    const printed = screen.getAllByText('common.capabilityControlCustomOnlyReason');
    expect(printed, ' ').toHaveLength(1);
    expect(screen.getByText('common.capabilityControlViewSupportedModels')).toBeTruthy();
  });

  it(' ', () => {
    open({ webControl: customOnly });
    fireEvent.click(screen.getByRole('button', { name: /capabilityControlCustomOnlyReason/ }));
    expect(screen.getAllByText('common.capabilityControlCustomOnlyReason')).toHaveLength(1);
    expect(screen.getByText('common.capabilityControlNoSupportedModels')).toBeTruthy();
  });

  it(' ', () => {
    open({ webControl: { state: 'unavailable' as const, availableIntents: [], viaLegacyProfile: false } });
    fireEvent.click(screen.getByRole('button', { name: /capabilityControlNotSupportedByModel/ }));
    expect(screen.getByText('common.capabilityControlWebNoOfficialConfig')).toBeTruthy();
  });
});

describe('AQA-11 - the advanced settings row does not hang a false "not ready" badge', () => {
  beforeEach(() => localStorage.clear());
  afterEach(cleanup);

  const advancedRow = () => screen.getByText('common.modelBehavior').closest('button')!;

  it('no generationControl (relay, or nothing sent) renders no "not ready"', () => {
    open();
    // The default generationControl is UNKNOWN_CONTROL, which must not leave a permanent "not ready" here.
    expect(within(advancedRow()).queryByText('pages.chat.reasoning.notReady')).toBeNull();
  });

  it('when the server says unsupported the "unavailable" badge stays, since this row has no status line to say it', () => {
    open({ generationControl: { state: 'unavailable' as const, availableIntents: [], viaLegacyProfile: false } });
    expect(within(advancedRow()).getByText('pages.chat.reasoning.unavailable')).toBeTruthy();
  });

  it('a managed connection still shows the "managed by Oriveo" badge', () => {
    open({
      generationControl: {
        state: 'managed_only' as const, availableIntents: [], viaLegacyProfile: false,
      },
    });
    expect(within(advancedRow()).getByText('common.managedByOriveo')).toBeTruthy();
  });
});
