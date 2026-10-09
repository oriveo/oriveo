import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  droppedUnsupportedParams,
  markUnsupportedParamDropped,
  resetUnsupportedParamCacheForTesting,
} from '@oriveo/core/providers/unsupported-param';
import { relayGenerationEndpointFingerprint } from '@oriveo/core/providers/relay-orchestrator';
import { generationParameterProfileFingerprint, loadGenerationParameterOverrides, saveGenerationParameterOverrides, valueOverride } from '../../lib/core/chat/generation-parameter-settings';
import { buildProviderStreamOptions } from '../../lib/core/chat/stream-options';
import { relayCapabilityEvidenceIdentity } from '../../lib/core/chat/capability-evidence';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../lib/core/providers/capability-evidence-identity';
import { showToast } from '../Toast';
import { GenerationParameterPanel } from './GenerationParameterPanel';

const profile = vi.hoisted(() => ({
  template: 'openai_chat_completions',
  wire: {
    reasoning_effort: 'reasoning_effort',
    temperature: 'temperature',
    reasoning_mode: 'reasoning_mode',
  },
  parameters: [
    { id: 'reasoning_effort', support: 'supported', source: 'authoritative_metadata', valueSchema: 'enum', enumValues: ['low', 'high'] },
    { id: 'reasoning_budget', support: 'fixed', source: 'provider_metadata', valueSchema: 'integer', fixedValue: 4096 },
    { id: 'reasoning_mode', support: 'mode_dependent', source: 'authoritative_metadata', valueSchema: 'string' },
    { id: 'temperature', support: 'unknown', source: 'user_declared', valueSchema: 'number' },
  ],
}));

/** Profile proving another model on the same connection really does accept top_p. */
const richProfile = vi.hoisted(() => ({
  template: 'openai_chat_completions',
  wire: { top_p: 'top_p' },
  parameters: [
    { id: 'top_p', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number' },
  ],
}));

// Keys carrying placeholders echo back as `key:value` so counts inside summaries stay
// assertable; keys without placeholders are returned as-is, so `/…$/` anchored assertions hold.
const localizedTestCopy: Record<string, string> = {
  generationParameterNameReasoningEffort: 'reasoning effort',
  generationParameterNameReasoningBudget: 'reasoning budget',
  generationParameterNameReasoningMode: 'reasoning mode',
  generationParameterNameTemperature: 'temperature',
  generationParameterNameSeed: 'random seed',
  generationParameterNameTopP: 'top p',
  generationParameterNameTopK: 'top k',
  generationParameterNameMaxOutputTokens: 'maximum output length',
  generationParameterNameFrequencyPenalty: 'frequency penalty',
  generationSourceOther: 'catalog or runtime evidence',
  generationTransportOther: 'request protocol',
};
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${Object.values(values).join(',')}` : localizedTestCopy[key] ?? key
  ),
  useLocale: () => 'en',
}));

vi.mock('../Toast', () => ({ showToast: vi.fn() }));

// Only the metadata boundary is mocked; all three named `stream-options` predicates run the
// production implementation, since panel visibility is exactly what this file is testing.
vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    // Models keep the shared profile by default (existing assertions untouched); only a model
    // that explicitly asks for `generationProfile: 'rich'` resolves to the other one.
    resolveGenerationProfileRef: (ref?: string) => (ref === 'rich' ? richProfile : profile),
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
  };
});

const provider = {
  id: 'relay-1',
  kind: 'relay',
  customName: 'Relay',
  models: [],
  catalogModels: [],
  status: { kind: 'connected' },
  apiKey: '',
  apiKeyPreview: '',
  baseURLText: 'https://relay.example/v1',
  relayRequested: {
    transport: 'openai_chat_completions',
    authMode: 'bearer',
    securityMode: 'remote_https',
  },
} as Provider;

const model = {
  id: 'model-1',
  name: 'Model 1',
  capabilities: ['text'],
  reasoningModeAvailable: true,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
} as AIModel;

/**
 * Parameter rows are collapsed and only show an input once opened: the assertions below were written for
 * always-visible inputs, so this renders the panel and then opens every cluster and row without
 * changing them. Rows that are not editable have no input even when opened (only an explanation),
 * and those cases are adjusted individually.
 */
function expandAll() {
  for (const selector of ['[data-advanced-cluster] > button[aria-expanded="false"]', '[data-advanced-row] > button[aria-expanded="false"]']) {
    document.querySelectorAll<HTMLButtonElement>(selector).forEach((button) => fireEvent.click(button));
  }
}
function renderPanel(ui: Parameters<typeof render>[0]) {
  const result = render(ui);
  expandAll();
  return result;
}

describe('GenerationParameterPanel', () => {
  beforeEach(() => {
    localStorage.clear();
    resetCapabilityEvidenceIdentitiesForTesting();
    beginCapabilityEvidenceIdentityIfAbsent('guest', provider.id);
  });
  afterEach(() => {
    cleanup();
  });

  it('reports fixed, mode-dependent and unknown capabilities honestly and enables only the allowed controls', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    expect(screen.getByText('4096')).toBeTruthy();
    // Eight engine-level states collapse into three user-visible classes. fixed and
    // mode_dependent are both not adjustable and are told apart by their own detail copy.
    // reasoning_budget has no wire: it is a reasoning-group row with no write path, so it says that one sentence and gives no support state.
    expect(document.querySelector('[data-parameter="reasoning_budget"]')?.textContent).toContain('advancedReasoningSetByThinking');
    expect(supportRow('reasoning_budget').detail).toBe('');
    // On this profile more than half of the rows are unverified, so the page-level tone holds (the
    // data layer's tone class is "not adjustable"): the header carries reasoning_mode's annotation
    // and the row does not repeat it, while the "switch model" exit stays.
    expect(supportRow('reasoning_mode').detail).toBe('');
    expect(document.querySelector('[data-parameter="reasoning_mode"] [data-testid="generation-not-adjustable-action"]')).toBeTruthy();
    expect(supportRow('temperature').line).toMatch(/^generationParameterClassNoData · /);
    // generation_parameter_contract.v1 relay.connectionDefaults.reasoning_mode:
    // a mode_dependent row is entryVisible=true but editable=false, same rule as official.
    // A row that is not editable has no input once opened (the old UI drew a disabled input).
    expect(screen.queryByLabelText('reasoning mode')).toBeNull();
    expect((screen.getByLabelText('temperature') as HTMLInputElement).disabled).toBe(false);
  });

  it('projects production parameter metadata through localized labels without visible wire identifiers', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    const visibleText = document.body.textContent ?? '';

    expect(screen.getByLabelText('reasoning effort')).toBeTruthy();
    expect(visibleText).not.toMatch(/reasoning_effort|reasoning_budget|reasoning_mode|authoritative_metadata|provider_metadata|user_declared|openai_chat_completions/);
  });

  // ── One title, a developer group, and no global gate ────────────────────
  //
  // There is no auto/custom segmented control and no global developer switch deciding whether it
  // shows. Custom request fields are reachable only through the developer group at the bottom.
  it('uses the same advanced-settings title in both forms and leaves the scope difference to the subtitle', () => {
    const { unmount } = renderPanel(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);
    expect(screen.getByLabelText('modelBehavior')).toBeTruthy();
    expect(screen.getByText(`${model.name} · advancedThisConversationOnly`)).toBeTruthy();
    // The scope is carried by the "this conversation only" subtitle; there is no separate scope sentence.
    // Connection-level operations belong on the provider detail side only; this path in chat is
    // about changing this one conversation, and putting presets, backup or diagnostics here
    // would bury the task at hand.
    expect(screen.queryByLabelText('generationPresetName')).toBeNull();
    unmount();

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    expect(screen.getByLabelText('modelBehavior')).toBeTruthy();
    expect(screen.getByText(model.name, { selector: 'p' })).toBeTruthy();
    expect(screen.getByLabelText('generationPresetName')).toBeTruthy();
  });

  // "Leave it empty and it is not sent" is what BYOK users care about most on this page: the
  // field is absent from the request body rather than filled with a default. Having all 16
  // locales present while the string never renders is exactly what translation-existence
  // assertions cannot catch.
  it('tells the conversation form that empty parameters are not sent and stays silent in the connection form', () => {
    const { unmount } = renderPanel(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);
    // "Left empty means not sent" is carried by the three-way source (decided by the model = not sent) and the footer legend, not a separate sentence.
    expect(screen.queryByTestId('generation-unset-note')).toBeNull();
    expect(screen.getByText('advancedChangedInConversation')).toBeTruthy();
    unmount();

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    expect(screen.queryByText('advancedChangedInConversation')).toBeNull();
  });

  it('annotates temperature and maximum output length in plain language and adds nothing to the other parameters', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    const annotations = screen.getAllByTestId('generation-parameter-annotation').map((node) => node.textContent);
    expect(annotations).toEqual(['generationParameterTemperatureNote']);
    expect(document.querySelector('[data-parameter="reasoning_effort"] [data-testid="generation-parameter-annotation"]')).toBeNull();
  });

  it('read-only degrades the parameter area, renders no write action and keeps the developer group', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} isReadOnly />);

    // Read-only: an opened row no longer draws a disabled input, it has no input at all (and no pair of ghost buttons).
    expect(screen.queryByLabelText('temperature')).toBeNull();
    expect(screen.queryByText('advancedDontSend')).toBeNull();
    expect(screen.queryByText('advancedReset')).toBeNull();
    expect(screen.queryByLabelText('generationPresetName')).toBeNull();
    // Read-only means the values cannot be changed right now, not that the feature is absent;
    // making the whole group vanish reads as a fault. It degrades to one non-interactive status
    // line instead, with no chevron and no navigation.
    const row = screen.getByTestId('generation-developer-row');
    expect(row.tagName).toBe('DIV');
    expect(screen.queryByTestId('generation-developer-explanation')).toBeNull();
  });

  /**
   * Restoring defaults is an irreversible full reset, so it has to be confirmed first. The
   * action once sat in the top-right corner, where muscle memory made users wipe every
   * parameter by accident.
   *
   * Persistence assertions go through the production read path rather than component state:
   * inspecting state cannot prove a value really left the store.
   */
  it('restore defaults enters a confirm state on the first click, cancel keeps the values and confirm clears them', () => {
    const storageKey = {
      providerId: provider.id,
      modelId: model.id,
      profileFingerprint: generationParameterProfileFingerprint(provider, model),
    };
    const saved = { reasoning_effort: valueOverride('high') };
    saveGenerationParameterOverrides(storageKey, saved);

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    fireEvent.click(screen.getByRole('button', { name: /advancedReset$/ }));

    // The first click only opens the confirm bar; nothing on disk may change.
    expect(loadGenerationParameterOverrides(storageKey)).toEqual(saved);
    const confirm = screen.getByRole('group', { name: /advancedResetModelTitle/ });
    expect(confirm.textContent).toContain('advancedResetModelBody');

    // Cancel collapses the confirm bar and leaves the values alone.
    fireEvent.click(within(confirm).getByRole('button', { name: /^cancel$/ }));
    expect(screen.queryByRole('group', { name: /advancedResetModelTitle/ })).toBeNull();
    expect(loadGenerationParameterOverrides(storageKey)).toEqual(saved);

    // Going through again and confirming is what actually clears the stored values.
    fireEvent.click(screen.getByRole('button', { name: /advancedReset$/ }));
    const reopened = screen.getByRole('group', { name: /advancedResetModelTitle/ });
    fireEvent.click(within(reopened).getByRole('button', { name: /advancedResetModelAction/ }));
    expect(loadGenerationParameterOverrides(storageKey) ?? {}).toEqual({});
  });

  it('keeps the custom-field row present and clickable when unsupported, giving the reason and a way forward', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    const row = screen.getByTestId('generation-developer-row');
    expect(row.textContent).toContain('capabilityControlNotSupportedByModel');
    fireEvent.click(row);
    const explanation = screen.getByTestId('generation-developer-explanation');
    expect(explanation.textContent).toContain('customRequestFieldsRequiresSchema');
    // Say outright that switching models will not help when this connection has no candidate,
    // otherwise the user clicks through into an empty list.
    expect(explanation.textContent).toContain('capabilityControlNoSupportedModels');
  });

  it('keeps a stored enum value the profile does not declare visible instead of silently downgrading it', () => {
    saveGenerationParameterOverrides(
      { providerId: provider.id, modelId: model.id, profileFingerprint: generationParameterProfileFingerprint(provider, model) },
      { reasoning_effort: valueOverride('ultra') },
    );

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    const select = screen.getByLabelText('reasoning effort') as HTMLSelectElement;
    expect(select.value).toBe('ultra');
    expect(screen.getByRole('option', { name: 'ultra' })).toBeTruthy();
  });

  // The container never collapses, and the empty state has four variants. A and B differ only
  // by whether this machine has ever seen a non-empty profile.
  it('renders the not-yet-verified state with title and explanation when no non-empty profile has ever been seen', () => {
    const originalParameters = profile.parameters;
    (profile as { parameters: unknown[] }).parameters = [];

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    expect(screen.getByText(/generationParameters$/)).toBeTruthy();
    expect(screen.getByText(/generationParameterEmptyNotVerified$/)).toBeTruthy();
    expect(screen.getByText(/generationParameterEmptyNotVerifiedBody/)).toBeTruthy();
    // The panel section is still there; it does not render as null.
    expect(screen.getByText(model.name, { selector: 'p' })).toBeTruthy();
    // The copy must not contain any percentage or progress number.
    expect(document.body.textContent).not.toMatch(/\d+\s*%/);

    (profile as { parameters: unknown[] }).parameters = originalParameters;
  });

  it('renders the taken-over-by-catalog state once a non-empty profile has been seen and then withdrawn', () => {
    // First render with a non-empty profile: the history flag is written by the production
    // useEffect, not by the test writing localStorage directly.
    const { unmount } = renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    unmount();

    const originalParameters = profile.parameters;
    (profile as { parameters: unknown[] }).parameters = [];
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    expect(screen.getByText(/generationParameterCatalogManaged/)).toBeTruthy();
    expect(screen.queryByText(/generationParameterEmptyNotVerified$/)).toBeNull();

    (profile as { parameters: unknown[] }).parameters = originalParameters;
  });

  // Locally synthesized unknown relay parameters stay adjustable, but the badge and the group
  // explanation line are mandatory.
  it('badges every unknown relay parameter row as unverified and shows the group explanation', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    // Relay may only treat every parameter as connection-local unverified;
    // an official model profile cannot silently authorize this endpoint.
    // The badge covers only relay declaration rows the user can actually try (reasoning_effort
    // and temperature). fixed / mode_dependent produce no accepted_unverified candidate since
    // they are neither editable nor sent, and badging an unadjustable row would dilute the badge
    // into "nothing on this page is verified".
    const badges = screen.getAllByTestId('generation-unverified-badge');
    expect(badges).toHaveLength(2);
    expect(badges[0].textContent).toMatch(/generationParameterUnverifiedBadge/);
    expect(screen.getByText(/generationParameterUnverifiedGroupNote/)).toBeTruthy();
  });

  // Clearing is connection-scoped: every endpoint and revision variant of that connection and
  // model. The revision at learn time is usually not the one at clear time, so matching on the
  // full identity would mean the entry can never be cleared.
  it('clearing learned capabilities on a relay panel drops the learned negative cache', async () => {
    resetUnsupportedParamCacheForTesting();
    const streamOptions = buildProviderStreamOptions(provider, undefined, model);
    // Identity and endpoint fingerprint both come from the production helpers the panel uses.
    const identity = relayCapabilityEvidenceIdentity(provider, model, streamOptions)!;
    expect(identity.endpointFingerprint).toBe(
      relayGenerationEndpointFingerprint(provider.baseURLText, model.id, streamOptions),
    );
    // The revision at learn time is rarely the revision at clear time; connection-scoped
    // clearing exists so that drift cannot block it (matching a full identity never clears).
    const learned = {
      ...identity,
      providerKind: 'relay' as const,
      modelID: model.id,
      transport: 'openai_chat_completions',
      metadataRevision: 'W/"metadata-when-learned"',
      generationRevision: 'W/"generation-when-learned"',
    };
    expect(markUnsupportedParamDropped(learned, 'temperature')).toBe('stored_first');
    expect(droppedUnsupportedParams(learned)).toEqual(['temperature']);
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    fireEvent.click(screen.getByRole('button', { name: /generationParameterClearLearnedCapabilities/ }));

    await waitFor(() => {
      expect(droppedUnsupportedParams(learned)).toEqual([]);
    });
    // Parameter values are unaffected: this is not a restore-default-values action.
    expect(screen.getByLabelText(/temperature/)).toBeTruthy();
  });

  // Fail-closed: with no local identity entry nothing is learned, and no clear action is offered
  // that could not clear anything.
  it('marks the negative cache ineligible without a local identity and renders no fake clear action', () => {
    resetUnsupportedParamCacheForTesting();
    resetCapabilityEvidenceIdentitiesForTesting();
    const endpointFingerprint = relayGenerationEndpointFingerprint(
      provider.baseURLText,
      model.id,
      buildProviderStreamOptions(provider, undefined, model),
    )!;
    const scope = { providerKind: 'relay' as const, modelID: model.id, endpointFingerprint };

    expect(markUnsupportedParamDropped(scope, 'temperature')).toBe('ineligible');
    expect(droppedUnsupportedParams(scope)).toEqual([]);

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    expect(screen.queryByRole('button', { name: /generationParameterClearLearnedCapabilities/ })).toBeNull();
  });

  it('does not let a relay catalog reasoning inference cross the explicit-value threshold', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    expect((screen.getByLabelText('reasoning effort') as HTMLSelectElement).disabled).toBe(false);
    // support=fixed / mode_dependent stays non-editable: the editable set must be a subset of
    // the outbound allow list. A non-editable row has no input.
    expect(screen.queryByLabelText('reasoning mode')).toBeNull();
  });

  it('renders no reasoning group in conversation scope and leaves it to the composer reasoning chip', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} scope="session" conversationId="conversation-a" />);

    expect(screen.queryByLabelText('reasoning effort')).toBeNull();
    expect(screen.queryByLabelText('reasoning mode')).toBeNull();
    expect(screen.getByText(/controlledByReasoningShortcut/)).toBeTruthy();
  });
  // ── Inactive values (shown as kept but currently ineffective; wire wording stays out of the UI) ──
  //
  // Every inactive value here comes from production logic: the panel computes the partition from
  // the production profile resolution, and the test only stores, through the production write
  // API, a parameter the current profile does not declare.

  /** Store a parameter ID absent from the current profile, the shape an old value takes after transport is corrected. */
  function saveWithOrphanValue() {
    saveGenerationParameterOverrides(
      { providerId: provider.id, modelId: model.id, profileFingerprint: generationParameterProfileFingerprint(provider, model) },
      { reasoning_effort: valueOverride('high'), top_p: valueOverride(0.9) },
    );
  }

  it('labels the row-end button "do not send this", shows "not sent" as the value afterwards, and labels restore "use the model default"', () => {
    // The old implementation borrowed common.remove (delete) and providerDetail.defaultURL (default URL), neither of which means this.
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    const input = screen.getByLabelText('temperature') as HTMLInputElement;
    fireEvent.click(within(input.parentElement!).getByRole('button', { name: 'advancedDontSend' }));

    // "Not sent" is shown in the value slot on the right of the row, no longer as the input's placeholder.
    const row = document.querySelector<HTMLElement>('[data-parameter="temperature"]')!;
    expect(row.querySelector('[data-value-source]')?.textContent).toBe('generationParameterOmittedValue');
    expect((within(row).getByRole('button', { name: 'advancedUseModelDefault' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('shows a summary line with a count when the panel is non-empty but holds inactive values', () => {
    saveWithOrphanValue();

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    const summary = screen.getByTestId('generation-dormant-summary');
    expect(summary.textContent).toMatch(/generationParameterDormantSummary:1/);
    // Wording checks for the user-facing label live in messages/message-schema.test.ts; the
    // next-intl mock here echoes keys, so asserting wording on it would only test the mock.
  });

  it('expands a read-only list echoing the values the user originally set', () => {
    saveWithOrphanValue();

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    fireEvent.click(screen.getByRole('button', { name: /generationParameterDormantView/ }));

    const summary = screen.getByTestId('generation-dormant-summary');
    expect(summary.textContent).toMatch(/top p/);
    expect(summary.textContent).toMatch(/0\.9/);
  });

  it('clears only the inactive half and keeps the values still in effect', () => {
    saveWithOrphanValue();

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    fireEvent.click(screen.getByRole('button', { name: /generationParameterDormantClear/ }));

    expect(screen.queryByTestId('generation-dormant-summary')).toBeNull();
    // Re-read through the production path: the active reasoning_effort must still be there.
    expect(loadGenerationParameterOverrides({
      providerId: provider.id, modelId: model.id,
      profileFingerprint: generationParameterProfileFingerprint(provider, model),
    })).toEqual({ reasoning_effort: valueOverride('high') });
  });

  it('renders the summary at the bottom of the empty state as well', () => {
    saveWithOrphanValue();
    const originalParameters = profile.parameters;
    (profile as { parameters: unknown[] }).parameters = [];

    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    expect(screen.getByText(/generationParameterEmptyNotVerified$/)).toBeTruthy();
    // With the profile emptied, neither value can be sent, so the summary reports 2.
    expect(screen.getByTestId('generation-dormant-summary').textContent)
      .toMatch(/generationParameterDormantSummary:2/);

    (profile as { parameters: unknown[] }).parameters = originalParameters;
  });

  it('restores compatible values automatically once the profile matches again and shows a one-off toast', () => {
    saveWithOrphanValue();
    const { rerender } = renderPanel(<GenerationParameterPanel provider={provider} model={model} />);
    expect(showToast).not.toHaveBeenCalled();

    // Upstream or protocol recovery: the profile declares top_p again. The value was never
    // dropped, so it should come back on its own once the verdict changes.
    const originalParameters = profile.parameters;
    (profile as { parameters: unknown[] }).parameters = [
      ...originalParameters,
      { id: 'top_p', support: 'supported', source: 'authoritative_metadata', valueSchema: 'number' },
    ];
    (profile.wire as Record<string, string>).top_p = 'top_p';
    rerender(<GenerationParameterPanel provider={provider} model={model} />);

    expect(screen.queryByTestId('generation-dormant-summary')).toBeNull();
    expect(showToast).toHaveBeenCalledTimes(1);
    expect(vi.mocked(showToast).mock.calls[0][0]).toMatch(/generationParameterDormantRestored:1/);

    (profile as { parameters: unknown[] }).parameters = originalParameters;
    delete (profile.wire as Record<string, string>).top_p;
  });

  // ── The normal case says nothing ───────────────
  //
  // `supported` is the normal case, and the normal case should not repeat a line of grey text
  // under every row. The cases that do need attention (unverified, fixed, mode_dependent,
  // unknown) may never be dropped and must always carry their Source, which is the only clue to
  // where the verdict came from.
  //
  // Only an official connection can produce `supported` evidence: a relay declaration is always
  // downgraded to unknown (see capability-evidence-facade.generationParameterEvidenceCandidates).
  const officialProvider = {
    id: 'openai-1',
    kind: 'openAI',
    models: [],
    catalogModels: [],
    status: { kind: 'connected' },
    apiKey: '',
    apiKeyPreview: '',
  } as unknown as Provider;
  // An empty or literal 'unknown' transport is judged unknown by the evidence layer, so it never
  // reaches the normal-case row.
  const officialModel = { ...model, transport: 'openai_chat' } as unknown as AIModel;

  it('renders no support line on supported rows and keeps state and Source intact on every other row', () => {
    beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
    renderPanel(<GenerationParameterPanel provider={officialProvider} model={officialModel} />);

    // The normal row is still rendered; it simply does not carry that line of grey text.
    expect(screen.getByLabelText('reasoning effort')).toBeTruthy();

    // The normal (silent) class renders no line at all, not even a Source.
    expect(supportRow('reasoning_effort').line).toBe('');
    // Not one state that needs attention may be dropped, and Source must be kept verbatim.
    // reasoning_budget has no wire, so it says "thinking is set in the model options" instead.
    expect(document.querySelector('[data-parameter="reasoning_budget"]')?.textContent).toContain('advancedReasoningSetByThinking');
    expect(supportRow('reasoning_mode').line)
      .toBe('generationParameterClassNotAdjustable · generationParameterSource: catalog or runtime evidence');
  });

  it('still shows the full state and Source for unknown relay rows', () => {
    renderPanel(<GenerationParameterPanel provider={provider} model={model} />);

    const lines = screen.queryAllByTestId('generation-support-line').map((node) => node.textContent ?? '');
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) expect(line).toMatch(/ · generationParameterSource: /);
    // A relay declaration means connection-scoped "it will be sent as-is but has not been
    // verified", not "we do not know"; the latter is the row the profile itself marks unknown.
    // When the page-level tone holds, the header states "unverified" once; a row keeps only the annotations in the data layer's inlineIds.
    expect(screen.getAllByText('generationParameterUnverifiedGroupNote')).toHaveLength(1);
    expect(supportRow('temperature').line).toMatch(/^generationParameterClassNoData · /);
  });

  // ── Eight engine-level states map to three user-visible classes, read from the shared
  // presentationClasses contract ──
  //
  // A supportLabel switch that only knows supported / accepted_unverified / fixed /
  // mode_dependent and defaults everything else to "unknown" is wrong twice: its
  // `effectiveSupport` comes from three-valued evidence.support, which makes the
  // `accepted_unverified` case unreachable dead code, while a real `unsupported` verdict backed
  // by official evidence gets rendered as "unknown", turning "no" into "do not know".
  /**
   * Assertions must be taken per row rather than by `toContain` over the whole `lines` table:
   * other rows such as mode_dependent hit the same class label and the same Source, so that
   * style stays green even when the bug is present.
   */
  function supportRow(parameterID: string) {
    const row = document.querySelector(`[data-parameter="${parameterID}"]`);
    if (!row) throw new Error(`row ${parameterID} was not rendered`);
    return {
      line: row.querySelector('[data-testid="generation-support-line"]')?.textContent ?? '',
      detail: row.querySelector('[data-testid="generation-support-detail"]')?.textContent ?? '',
    };
  }

  function withExtraParameter<T>(parameter: Record<string, unknown>, run: () => T): T {
    const originalParameters = profile.parameters;
    (profile as { parameters: unknown[] }).parameters = [...originalParameters, parameter];
    (profile.wire as Record<string, string>)[parameter.id as string] = parameter.id as string;
    try {
      return run();
    } finally {
      (profile as { parameters: unknown[] }).parameters = originalParameters;
      delete (profile.wire as Record<string, string>)[parameter.id as string];
    }
  }

  it('renders future_supported as not adjustable with its own detail copy rather than as missing data', () => {
    withExtraParameter(
      { id: 'top_k', support: 'future_supported', source: 'authoritative_metadata', valueSchema: 'integer' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(<GenerationParameterPanel provider={officialProvider} model={officialModel} />);
        const row = supportRow('top_k');
        expect(row.line).toBe('generationParameterClassNotAdjustable · generationParameterSource: catalog or runtime evidence');
        // It is officially not open yet, so it must not land in no-data-available alongside unknown.
        expect(row.detail).toBe('generationParameterDetailFutureSupported');
        expect(supportRow('temperature').detail).toBe('generationParameterDetailUnknown');
      },
    );
  });

  it('gives accepted_unverified its own label instead of falling through to no data available', () => {
    withExtraParameter(
      { id: 'seed', support: 'accepted_unverified', source: 'provider_metadata', valueSchema: 'integer' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(<GenerationParameterPanel provider={officialProvider} model={officialModel} />);
        const row = supportRow('seed');
        expect(row.line).toBe('generationParameterClassUnverified · generationParameterSource: catalog or runtime evidence');
        expect(row.detail).toBe('generationParameterDetailAcceptedUnverified');
      },
    );
  });

  /**
   * `unsupported` belongs to the not-adjustable class.
   *
   * A `connectionConfigurable` that starts with `if (evidence.support === 'unsupported') return
   * false;` makes the row structurally unreachable in the panel: instead of "this model does not
   * accept the parameter", the user sees the row disappear. `fixed` / `mode_dependent` survive
   * only because the evidence layer normalizes them to `unknown`, so assertions that look at
   * those two rows stay green while the bug is present.
   */
  it('renders unsupported rows greyed out with their own detail copy instead of dropping the row', () => {
    withExtraParameter(
      { id: 'top_p', support: 'unsupported', source: 'authoritative_metadata', valueSchema: 'number' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(<GenerationParameterPanel provider={officialProvider} model={officialModel} />);
        const row = supportRow('top_p');
        expect(row.line).toBe('generationParameterClassNotAdjustable · generationParameterSource: catalog or runtime evidence');
        expect(row.detail).toBe('generationParameterDetailUnsupported');
        // A non-editable row has no input.
        expect(screen.queryByLabelText('top p')).toBeNull();
      },
    );
  });

  /**
   * A not-adjustable row is greyed out but must still offer a primary action ("see models that
   * support this parameter"), otherwise it is a dead end. The copy key comes from the shared
   * `presentationClasses.not_adjustable.primaryAction` contract.
   */
  it('gives a not-adjustable row a primary action that hands the parameter ID up to open a model picker', () => {
    const onFindSupportedModels = vi.fn();
    withExtraParameter(
      { id: 'top_p', support: 'unsupported', source: 'authoritative_metadata', valueSchema: 'number' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(
          <GenerationParameterPanel
            provider={officialProvider}
            model={officialModel}
            onFindSupportedModels={onFindSupportedModels}
          />,
        );

        const row = document.querySelector('[data-parameter="top_p"]')!;
        const action = row.querySelector('[data-testid="generation-not-adjustable-action"]') as HTMLButtonElement | null;
        expect(action, 'a not-adjustable row must offer one actionable primary action').toBeTruthy();
        expect(action!.textContent).toBe('generationParameterFindSupportedModels');
        fireEvent.click(action!);
        expect(onFindSupportedModels).toHaveBeenCalledWith('top_p');

        // Reverse assertion so that "has a primary action" cannot be implemented as always true:
        // a normal (silent) row must not carry this button.
        expect(
          document.querySelector('[data-parameter="reasoning_effort"] [data-testid="generation-not-adjustable-action"]'),
        ).toBeNull();
        // reasoning_budget has no write path: its way out is the sentence pointing at the thinking control (offersSupportedModels: false), not a "switch model" button.
        expect(
          document.querySelector('[data-parameter="reasoning_budget"] [data-testid="generation-not-adjustable-action"]'),
        ).toBeNull();
      },
    );
  });

  /**
   * When the host has no model picker to open (neither provider-detail path has one), rendering
   * no primary action turns the not-adjustable state into a dead end on those pages: a greyed
   * control, no explanation, no next step. Fall back to expanding a read-only list in place, the
   * same way `DeveloperGroup` does.
   */
  it('expands a read-only candidate model list in place when no onFindSupportedModels is provided', () => {
    const richModel = {
      ...officialModel, id: 'model-rich', name: 'Rich Model', generationProfile: 'rich',
    } as unknown as AIModel;
    const connection = { ...officialProvider, models: [officialModel, richModel] } as unknown as Provider;
    withExtraParameter(
      { id: 'top_p', support: 'unsupported', source: 'authoritative_metadata', valueSchema: 'number' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', connection.id);
        // Note that onFindSupportedModels is deliberately not passed, which is the shape of both
        // provider-detail mount paths.
        renderPanel(<GenerationParameterPanel provider={connection} model={officialModel} />);

        const row = document.querySelector('[data-parameter="top_p"]')!;
        const action = row.querySelector('[data-testid="generation-not-adjustable-action"]') as HTMLButtonElement | null;
        expect(action, 'there must be a way out even with no picker to open, not an empty render').toBeTruthy();
        // It is an expander here, not a button that navigates away, so say so.
        expect(action!.getAttribute('aria-expanded')).toBe('false');
        expect(row.querySelector('[data-testid="generation-not-adjustable-candidates"]')).toBeNull();

        fireEvent.click(action!);

        expect(action!.getAttribute('aria-expanded')).toBe('true');
        const candidates = row.querySelector('[data-testid="generation-not-adjustable-candidates"]');
        expect(candidates, 'expanding must produce a list').toBeTruthy();
        // The list holds only models that really accept the parameter, and leaves out the one
        // already in use, which is not a way out.
        expect(candidates!.textContent).toBe('Rich Model');

        // Clicking again collapses it: this is a reversible expander, not a one-shot text dump.
        fireEvent.click(action!);
        expect(row.querySelector('[data-testid="generation-not-adjustable-candidates"]')).toBeNull();
      },
    );
  });

  it('says outright that switching models will not help when there is no candidate, instead of expanding an empty list', () => {
    withExtraParameter(
      { id: 'top_p', support: 'unsupported', source: 'authoritative_metadata', valueSchema: 'number' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(<GenerationParameterPanel provider={officialProvider} model={officialModel} />);

        const row = document.querySelector('[data-parameter="top_p"]')!;
        fireEvent.click(row.querySelector('[data-testid="generation-not-adjustable-action"]') as HTMLButtonElement);
        expect(row.querySelector('[data-testid="generation-not-adjustable-candidates"]')!.textContent)
          .toBe('capabilityControlNoSupportedModels');
      },
    );
  });

  it('still opens the picker when onFindSupportedModels is provided instead of degrading to an expander', () => {
    withExtraParameter(
      { id: 'top_p', support: 'unsupported', source: 'authoritative_metadata', valueSchema: 'number' },
      () => {
        beginCapabilityEvidenceIdentityIfAbsent('guest', officialProvider.id);
        renderPanel(
          <GenerationParameterPanel
            provider={officialProvider}
            model={officialModel}
            onFindSupportedModels={vi.fn()}
          />,
        );
        const action = document.querySelector('[data-parameter="top_p"] [data-testid="generation-not-adjustable-action"]')!;
        // It navigates to another screen and expands nothing, so aria-expanded would be a lie.
        expect(action.getAttribute('aria-expanded')).toBeNull();
      },
    );
  });

  // ── The global switch is gone; the panel should not carry a trace of it ────────────────────
  it('has no global developer switch anywhere in the panel and renders identically when the legacy key is set', () => {
    localStorage.setItem('oriveo.local-custom-fragment-developer-mode.v1', 'true');
    renderPanel(<GenerationParameterPanel provider={provider} model={model} conversationId="conversation-1" scope="session" />);

    expect(screen.queryAllByRole('switch')).toHaveLength(0);
    expect(screen.queryByText('customRequestFieldsEnableScope')).toBeNull();
    expect(screen.queryByLabelText('customRequestFieldsConfigurationMode')).toBeNull();
    // The entry point is still only that one row in the developer group.
    expect(screen.getByTestId('generation-developer-row')).toBeTruthy();
  });
});
