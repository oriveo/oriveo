import type { ProviderKind } from '@oriveo/shared';
import type { CapabilityWebPreference } from './capability-preference-settings';
import type { CapabilityControlPresentation } from './capability-control-presentation';

/**
 * Panel layout decisions for the web-search and reasoning capabilities, as pure functions.
 *
 * The recurring problems here have never been pixels: which options should appear, what an
 * unavailable state says, and where tapping it leads. Expressed in JSX those rules can only be
 * checked by eye in a browser and regress on every edit; as pure functions each rule can be
 * asserted.
 *
 * One overarching rule: there is no such thing as a greyed-out option in this UI. Selectable
 * things render as selectable; anything else degrades to a single line of status text. A status
 * row still responds to taps and gives the reason plus a way forward, so nothing ever looks like
 * a button that does nothing when pressed.
 *
 * Server recipes are the only authority for automatic web/reasoning configuration. With no
 * recipe the panel says so honestly; capabilities are never guessed from model id or
 * providerKind.
 *
 * Copy is returned as message keys rather than finished strings: a pure function has no
 * `useTranslations`, and keys let tests assert which sentence was chosen rather than what a
 * language pack currently translates it to.
 */

/** Message path (including namespace) for panel copy; the render layer resolves it through one resolver. */
export type ModelControlMessageKey = `common.${string}` | `pages.chat.reasoning.${string}`;

/**
 * Where tapping an unavailable status row leads.
 *
 * `none` is only allowed when the reason is already stated elsewhere in the panel (a managed
 * banner, a read-only note at the top of the page, the custom-override note, or a status row
 * that is a complete sentence on its own). Otherwise there must be a route that actually changes
 * the situation: before adding a branch, answer whether the state really changes after the user
 * takes that action.
 */
export type ModelControlEscape = 'none' | 'supportedModels' | 'advancedSettings';

/**
 * Projection of the server control state into the panel.
 *
 * `presentCapabilityControl` only produces 5 wire states; they are expanded here by reasonCode
 * into 9 so every branch is explicit. `forceUnsupported` is never produced by the panel path (it
 * is a refinement used only by the `forceRequested` caller), but the branch is kept so the state
 * table stays complete.
 */
export type ModelControlStatus =
  | 'automaticAvailable'
  | 'forceUnsupported'
  | 'managedFree'
  | 'managedBalance'
  | 'customOnly'
  | 'pending'
  | 'externalConnectorOnly'
  | 'unsupported'
  | 'unknown';

/** Read-only substates of `unknown`: a reasonCode only refines the reason for the same state, it must never turn it into unavailable. */
const PENDING_REASON_CODES = new Set([
  'endpoint_route_pending', 'model_route_pending', 'official_source_insufficient',
  'source_review_expired', 'provider_kill_switch',
]);

export function resolveModelControlStatus(
  control: Pick<CapabilityControlPresentation, 'state'> & { reasonCode?: string },
): ModelControlStatus {
  switch (control.state) {
    case 'auto_available': return 'automaticAvailable';
    case 'managed_only':
      return control.reasonCode === 'managed_balance_server_authority' ? 'managedBalance' : 'managedFree';
    case 'custom_only': return 'customOnly';
    case 'unavailable':
      return control.reasonCode === 'external_connector_only' ? 'externalConnectorOnly' : 'unsupported';
    default:
      return PENDING_REASON_CODES.has(control.reasonCode ?? '') ? 'pending' : 'unknown';
  }
}

export function modelControlStatusIsManaged(status: ModelControlStatus): boolean {
  return status === 'managedFree' || status === 'managedBalance';
}

/**
 * Stale-preference guard: will the stored web-search preference actually reach the wire right now?
 *
 * The preference is stored per connection x model x transport, but whether it can go out depends
 * on the current metadata. When metadata changes, a recipe is withdrawn, or the transport
 * changes, the stored `automatic` stays byte-identical, so the panel toggle and the composer
 * globe stay lit while the request carries no web-search field at all.
 *
 * There is one predicate, and all three consumers (chip highlight, restored state, outbound
 * explicit-intent key) must ask it rather than re-implementing `web !== 'off'`:
 * - only `automaticAvailable` lights up; `forceUnsupported` stays dark, because it is not the
 *   same set as `isConfigurable` (only the force tier is unavailable, and the panel path never
 *   produces that state);
 * - a custom field override lights up: it really is rewriting the request, even when that means
 *   a fail-closed failure.
 *
 * Storage is never rewritten: the user's choice stays and comes back once a supported model is
 * selected again. This only stops lighting up a globe that will not reach the wire.
 */
export function modelControlWebReachesTheWire(input: {
  status: ModelControlStatus;
  customIsActive: boolean;
}): boolean {
  return input.status === 'automaticAvailable' || input.customIsActive;
}

/**
 * Whether the user can express an intent here at all. `forceUnsupported` counts as configurable:
 * only the force tier is unavailable, off/automatic are still real requests.
 */
export function modelControlStatusIsConfigurable(status: ModelControlStatus): boolean {
  return status === 'automaticAvailable' || status === 'forceUnsupported' || status === 'unknown';
}

/**
 * When "view supported models" is a real way forward.
 *
 * `customOnly` counts too: the custom field editor for that connection lives in advanced
 * settings, while switching to a model that works automatically is the route most users can
 * actually take, so both are offered.
 */
export function modelControlShowsSupportedModelsAction(status: ModelControlStatus): boolean {
  switch (status) {
    case 'unsupported': case 'unknown': case 'pending': case 'externalConnectorOnly': case 'customOnly':
      return true;
    default:
      return false;
  }
}

/** Status text for the footer when `!isConfigurable`; only the advanced settings context uses it. */
export function modelControlStatusTextKey(status: ModelControlStatus): ModelControlMessageKey {
  switch (status) {
    case 'managedFree': case 'managedBalance': return 'common.managedByOriveo';
    case 'customOnly': return 'common.capabilityControlCustomOnlyReason';
    case 'pending': return 'common.capabilityControlReasonPending';
    case 'externalConnectorOnly': return 'common.capabilityControlReasonExternalConnector';
    case 'unsupported': return 'common.capabilityControlUnavailableForConnection';
    default: return 'common.capabilityControlReasonUnknown';
  }
}

// MARK: -  

export type ModelControlBadgeClassification = 'none' | 'managed' | 'manual' | 'notReady' | 'unavailable';

/** Available is the normal case and carries no badge: three green "automatic" badges at once would drown the amber one that matters. */
export function modelControlBadgeClassification(status: ModelControlStatus): ModelControlBadgeClassification {
  switch (status) {
    case 'automaticAvailable': case 'forceUnsupported': return 'none';
    case 'managedFree': case 'managedBalance': return 'managed';
    case 'customOnly': return 'manual';
    case 'pending': case 'unknown': return 'notReady';
    default: return 'unavailable';
  }
}

/**
 * Badge projection for the web-search and reasoning cards: `unavailable` is flattened to no badge.
 *
 * The status row already spells out that the model does not support it, so an "unavailable"
 * badge on the title row says the same thing twice. Only that one tier is flattened; the others
 * carry information the status row does not (tense, ownership, who is overriding). Advanced
 * settings rows have no status row and keep consuming `modelControlBadgeClassification`.
 */
export function modelControlCardBadgeClassification(status: ModelControlStatus): ModelControlBadgeClassification {
  const classification = modelControlBadgeClassification(status);
  return classification === 'unavailable' ? 'none' : classification;
}

/**
 * Badge projection for the advanced settings row (request parameters): `notReady` is flattened
 * to no badge.
 *
 * Consuming `modelControlBadgeClassification` directly here was wrong: relay connections (whose
 * `capabilityControls` is always empty) and official models without
 * `capabilityControls.generation` all fell to `unknown` and permanently showed a "not ready"
 * badge. The request-parameter editor behind this row does not read recipes at all; the editable
 * set comes from the generation profile (`resolveGenerationProfileForModel`: relay uses the local
 * engine/transport profile, official providers use the catalog model's generationProfile), so the
 * parameters really are adjustable and really do reach the wire. The row would state a wrong
 * status right next to its own "N adjusted" summary.
 *
 * Only `notReady` is flattened. `unsupported` / `externalConnectorOnly` mean the server says it
 * cannot be done and there is no status row to say so, so that badge stays. `managed` / `manual`
 * describe ownership and who is overriding, which "N adjusted" cannot express.
 */
export function modelControlAdvancedSettingsBadgeClassification(
  status: ModelControlStatus,
): ModelControlBadgeClassification {
  const classification = modelControlBadgeClassification(status);
  return classification === 'notReady' ? 'none' : classification;
}

export type ModelControlBadge = {
  tone: 'manual' | 'unavailable';
  textKey: ModelControlMessageKey;
};

export function modelControlBadge(
  classification: ModelControlBadgeClassification,
  overridden: boolean,
): ModelControlBadge | null {
  if (overridden) return { tone: 'manual', textKey: 'common.capabilityControlBadgeCustom' };
  switch (classification) {
    case 'none': return null;
    case 'managed': return { tone: 'manual', textKey: 'common.managedByOriveo' };
    case 'manual': return { tone: 'manual', textKey: 'common.capabilityControlBadgeManual' };
    case 'notReady': return { tone: 'manual', textKey: 'pages.chat.reasoning.notReady' };
    case 'unavailable': return { tone: 'unavailable', textKey: 'pages.chat.reasoning.unavailable' };
  }
}

// MARK: -  

export type ModelControlIntentOption = { id: string; labelKey: ModelControlMessageKey };

/** Pseudo-intent for "automatic" in the tier list; selecting it injects no tier (storage holds undefined). */
export const MODEL_CONTROL_AUTOMATIC_INTENT = 'automatic';
/**
 * Render order of the server tiers: "off" first, then increasing effort. "automatic" is not in
 * this table; the layout always inserts it right after `off`, where it is the default selection.
 */
export const MODEL_CONTROL_REASONING_TIER_ORDER = ['off', 'low', 'balanced', 'deep', 'max'] as const;

const REASONING_TIER_LABEL_KEYS: Record<string, ModelControlMessageKey> = {
  off: 'pages.chat.reasoning.off',
  [MODEL_CONTROL_AUTOMATIC_INTENT]: 'pages.chat.reasoning.supplierDefault',
  low: 'pages.chat.reasoning.fast',
  balanced: 'pages.chat.reasoning.balanced',
  deep: 'pages.chat.reasoning.deep',
  max: 'pages.chat.reasoning.max',
};

/**
 * Tier annotations, phrased around what the user gets rather than the protocol effort value.
 * Only the selected tier's note is shown: a pill has room for one noun, so this sentence is what
 * distinguishes e.g. fast from balanced.
 */
const REASONING_TIER_NOTE_KEYS: Record<string, ModelControlMessageKey> = {
  off: 'common.capabilityControlReasoningNoteOff',
  [MODEL_CONTROL_AUTOMATIC_INTENT]: 'common.capabilityControlReasoningNoteAutomatic',
  low: 'common.capabilityControlReasoningNoteFast',
  balanced: 'common.capabilityControlReasoningNoteBalanced',
  deep: 'common.capabilityControlReasoningNoteDeep',
  max: 'common.capabilityControlReasoningNoteMax',
};

export function modelControlReasoningTierLabelKey(intent: string): ModelControlMessageKey | undefined {
  return REASONING_TIER_LABEL_KEYS[intent];
}

export type ModelControlReasoningLayout = {
  form: 'pillRow' | 'statusRow';
  /**
   * Only tiers the recipe actually declares are rendered, plus "automatic", which always exists.
   * Every pill is tappable; there are no greyed-out options here.
   */
  options: ModelControlIntentOption[];
  selection: string;
  /**
   * One plain sentence annotating the selected tier, following the selection rather than laying
   * out all six at once.
   */
  selectedAnnotationKey?: ModelControlMessageKey;
  /** Footnote below the pill row; currently only the "this model cannot turn reasoning off" line. */
  footnoteKey?: ModelControlMessageKey;
  /** Text of the row when `form === 'statusRow'`. */
  statusTextKey?: ModelControlMessageKey;
  /** Reason shown when the status row is tapped. Absent means the reason is already stated elsewhere in the panel. */
  explanationKey?: ModelControlMessageKey;
  escape: ModelControlEscape;
};

/**
 * Reasoning card: a wrapping row of pills plus one note for the selected tier.
 *
 * There is no separate reasoning toggle, because it expressed the same thing as the tier row
 * (`off` is already a tier). Two controls for one meaning meant that turning the toggle off
 * greyed out the whole row while the previously selected tier stayed highlighted. "Off" belongs
 * where it started: the first pill in the row.
 *
 * @param isEditable Panel is writable and this owner is not overridden by a custom field. When
 *   false the card degrades to a read-only status row; the reason is carried by the banner at the
 *   top of the page or by the note inside the card, and is not repeated here.
 * @param hasCustomSchema This connection really declares an editable custom field schema for the
 *   current transport. The escape route for `customOnly` depends on it: with no schema, sending
 *   the user to advanced settings only shows that the model does not support it, and a route that
 *   leads nowhere is worse than no route.
 */
export function modelControlReasoningLayout(input: {
  status: ModelControlStatus;
  intents: readonly string[];
  selectedIntent?: string;
  isEditable: boolean;
  hasCustomSchema?: boolean;
}): ModelControlReasoningLayout {
  const { status, intents, isEditable } = input;
  const hasCustomSchema = input.hasCustomSchema ?? true;
  const selection = input.selectedIntent ?? MODEL_CONTROL_AUTOMATIC_INTENT;
  switch (status) {
    case 'managedFree':
    case 'managedBalance':
      // A managed connection is configured upstream: state that, and offer no control the client
      // would not be able to apply.
      return reasoningStatusRow('common.managedByOriveo', undefined, 'none', selection);
    case 'unsupported':
    case 'externalConnectorOnly':
      return reasoningStatusRow(
        'common.capabilityControlNotSupportedByModel',
        'common.capabilityControlUnavailableForConnection',
        'supportedModels',
        selection,
      );
    case 'customOnly':
      return reasoningStatusRow(
        'common.capabilityControlCustomOnlyReason',
        'common.capabilityControlCustomOnlyReason',
        hasCustomSchema ? 'advancedSettings' : 'supportedModels',
        selection,
      );
    case 'pending':
    case 'unknown':
      // Unlike web search there is no escape hatch here. A web-search toggle has a meaningful
      // "just try it" semantic, but with no recipe no reasoning field can be compiled at all.
      return reasoningStatusRow(
        'common.capabilityControlCannotAdjustYet',
        'common.capabilityControlReasoningNoOfficialConfig',
        'supportedModels',
        selection,
      );
    case 'automaticAvailable':
    case 'forceUnsupported': {
      if (!isEditable) {
        return reasoningStatusRow(
          REASONING_TIER_LABEL_KEYS[selection] ?? REASONING_TIER_LABEL_KEYS[MODEL_CONTROL_AUTOMATIC_INTENT]!,
          undefined, 'none', selection,
        );
      }
      if (intents.length === 0) {
        // Automatic configuration exists but yields no selectable tier (observed with
        // `openAI/gpt-5-pro`, which only accepts high). The row is already a complete sentence.
        return reasoningStatusRow('common.capabilityControlReasoningFixedLevel', undefined, 'none', selection);
      }
      return reasoningPillRow(intents, selection);
    }
  }
}

function reasoningPillRow(intents: readonly string[], selection: string): ModelControlReasoningLayout {
  const available = new Set(intents);
  const options: ModelControlIntentOption[] = [];
  // "Off" comes first: it means "do not think", which is a different dimension from the tiers
  // that follow in increasing order of effort.
  if (available.has('off')) options.push(reasoningOption('off'));
  // "Automatic" always exists and is the default: injecting no tier is the real factory state.
  options.push(reasoningOption(MODEL_CONTROL_AUTOMATIC_INTENT));
  for (const id of MODEL_CONTROL_REASONING_TIER_ORDER) {
    if (id !== 'off' && available.has(id)) options.push(reasoningOption(id));
  }
  // A stored tier can be absent from the recipe (transport change, recipe revision). Keeping
  // the old value would leave no pill highlighted, so it falls back to automatic, matching the
  // outbound rule of injecting nothing that cannot be compiled.
  const effective = options.some((option) => option.id === selection)
    ? selection
    : MODEL_CONTROL_AUTOMATIC_INTENT;
  return {
    form: 'pillRow',
    options,
    selection: effective,
    selectedAnnotationKey: REASONING_TIER_NOTE_KEYS[effective],
    // Footnote is permanent when the recipe has no off tier; this is the only place that sentence lives.
    ...(available.has('off') ? {} : { footnoteKey: 'common.capabilityControlReasoningOffUnavailable' as const }),
    escape: 'none',
  };
}

function reasoningOption(intent: string): ModelControlIntentOption {
  return { id: intent, labelKey: REASONING_TIER_LABEL_KEYS[intent]! };
}

function reasoningStatusRow(
  statusTextKey: ModelControlMessageKey,
  explanationKey: ModelControlMessageKey | undefined,
  escape: ModelControlEscape,
  selection: string,
): ModelControlReasoningLayout {
  return {
    form: 'statusRow',
    options: [],
    selection,
    statusTextKey,
    ...(explanationKey ? { explanationKey } : {}),
    escape,
  };
}

// MARK: -  

const WEB_PREFERENCE_LABEL_KEYS: Record<CapabilityWebPreference, ModelControlMessageKey> = {
  off: 'pages.chat.reasoning.off',
  automatic: 'pages.chat.reasoning.auto',
  force: 'pages.chat.reasoning.force',
};

export type ModelControlWebLayout = {
  form: 'toggle' | 'statusRow';
  /** Toggle state. `automatic` / `force` count as on, `off` as off. */
  isOn: boolean;
  /** The sentence below the switch. */
  captionKey?: ModelControlMessageKey;
  /** The two "search timing" pills; an empty array means the row is not rendered. */
  timingOptions: ModelControlIntentOption[];
  timingSelection: CapabilityWebPreference;
  statusTextKey?: ModelControlMessageKey;
  explanationKey?: ModelControlMessageKey;
  escape: ModelControlEscape;
  /**
   * Clamped preference (see `clampModelControlWebPreference`). A stored `force` the current
   * recipe does not offer becomes `automatic`; callers should persist that back.
   */
  effectiveSelection: CapabilityWebPreference;
};

/**
 * Clamps a stored `force` back to `automatic` when the current recipe does not offer it.
 *
 * Observed in production: only OpenAI models support officially forced search. After picking
 * "search on every message" there and switching to another model, storage still holds `force`
 * while the outbound side cannot compile it and sends automatic. Without clamping, neither
 * "search timing" pill is highlighted (options are empty) and it looks like nothing was ever chosen.
 *
 * Only ask whether the recipe offers force when automatic configuration really exists:
 * `availableIntents` is always empty for `pending` / `unknown`, and clamping on that would
 * rewrite a stored choice just because the snapshot has not arrived yet.
 */
export function clampModelControlWebPreference(
  selection: CapabilityWebPreference,
  status: ModelControlStatus,
  availableIntents: readonly string[],
): CapabilityWebPreference {
  if (selection !== 'force') return selection;
  switch (status) {
    case 'automaticAvailable':
    case 'forceUnsupported':
      return availableIntents.includes('force') ? 'force' : 'automatic';
    default:
      return selection;
  }
}

/**
 * Web-search card: one toggle, plus a secondary "search timing" row when the official recipe
 * declares force.
 *
 * A toggle rather than three capsules: `off / automatic` is a binary question, and two mutually
 * exclusive capsules only split one switch into two buttons. `force` is not the same layer of
 * meaning at all - it is not "should this search" but "how eagerly once it does". Flattened into
 * one row it reads as three unfamiliar words side by side.
 *
 * `pending` / `unknown` get no escape-hatch toggle: with no recipe the client cannot compile any
 * web-search field, so the request is byte-identical whether the toggle is on or off. Letting the
 * user flip it, see it rest on "on", and then never search is the clearest form of a lying UI.
 */
export function modelControlWebLayout(input: {
  status: ModelControlStatus;
  availableIntents: readonly string[];
  selection: CapabilityWebPreference;
  isEditable: boolean;
  hasCustomSchema?: boolean;
}): ModelControlWebLayout {
  const { status, availableIntents, isEditable } = input;
  const hasCustomSchema = input.hasCustomSchema ?? true;
  const selection = clampModelControlWebPreference(input.selection, status, availableIntents);
  switch (status) {
    case 'managedFree':
    case 'managedBalance':
      return webStatusRow('common.managedByOriveo', undefined, 'none', selection);
    case 'unsupported':
    case 'externalConnectorOnly':
      return webStatusRow(
        'common.capabilityControlNotSupportedByModel',
        'common.capabilityControlWebNoOfficialConfig',
        'supportedModels',
        selection,
      );
    case 'customOnly':
      return webStatusRow(
        'common.capabilityControlCustomOnlyReason',
        'common.capabilityControlCustomOnlyReason',
        hasCustomSchema ? 'advancedSettings' : 'supportedModels',
        selection,
      );
    case 'pending':
    case 'unknown':
      //  
      //  
      return webStatusRow(
        'common.capabilityControlCannotAdjustYet',
        'common.capabilityControlWebNoOfficialConfig',
        'supportedModels',
        selection,
      );
    case 'automaticAvailable':
    case 'forceUnsupported': {
      if (!isEditable) {
        return webStatusRow(WEB_PREFERENCE_LABEL_KEYS[selection], undefined, 'none', selection);
      }
      const isOn = selection !== 'off';
      const supportsForce = availableIntents.includes('force');
      return {
        form: 'toggle',
        isOn,
        captionKey: 'common.capabilityControlWebSwitchNote',
        timingOptions: isOn && supportsForce ? webTimingOptions() : [],
        timingSelection: selection === 'force' ? 'force' : 'automatic',
        escape: 'none',
        effectiveSelection: selection,
      };
    }
  }
}

/** The two "search timing" pills. The wording is about behaviour (when it searches), not the protocol tier name. */
function webTimingOptions(): ModelControlIntentOption[] {
  return [
    { id: 'automatic', labelKey: WEB_PREFERENCE_LABEL_KEYS.automatic },
    { id: 'force', labelKey: WEB_PREFERENCE_LABEL_KEYS.force },
  ];
}

function webStatusRow(
  statusTextKey: ModelControlMessageKey,
  explanationKey: ModelControlMessageKey | undefined,
  escape: ModelControlEscape,
  selection: CapabilityWebPreference,
): ModelControlWebLayout {
  return {
    form: 'statusRow',
    isOn: selection !== 'off',
    timingOptions: [],
    timingSelection: selection === 'force' ? 'force' : 'automatic',
    statusTextKey,
    ...(explanationKey ? { explanationKey } : {}),
    escape,
    effectiveSelection: selection,
  };
}

// MARK: -  

/**
 * Which of the shared "status note + risk warning + secondary entry" items the three owners show.
 *
 * A pure function for the same reason as above: the recurring bug is the same thing being said
 * several times. The two contexts divide the work:
 * - `panelCard`: the reason for being unavailable is carried by the status row itself, tapping it
 *   gives a way forward, and the footer does not repeat it;
 * - `behaviorPageHeader`: the advanced settings page has no status row, so that reason must stay
 *   or the page is read-only with no explanation.
 *
 * `behaviorPageHeader` currently has no caller; it is kept deliberately. The advanced settings
 * pane states this through the banner at the top of the page (`.modelControlBanner` in
 * `ModelOptionsPopover`, rendered once in the main pane and once in the advanced settings pane)
 * rather than through footer entries. Because the banner is rendered in the advanced settings
 * pane too, `runtimeReadOnly` / `identityUnavailable` never leave a fully disabled page with no
 * explanation and no way out. Do not delete this branch as dead code without evidence that no
 * consumer of the shape table needs it.
 */
export type ModelControlFooterContext = 'panelCard' | 'behaviorPageHeader';
export type ModelControlFooterTone = 'tertiary' | 'warning';

export type ModelControlFooterEntry =
  /** `text` is an already resolved string supplied by the caller; `textKey` is a message key still to resolve. */
  | { kind: 'note'; textKey?: ModelControlMessageKey; text?: string; tone: ModelControlFooterTone }
  | { kind: 'supportedModelsLink' }
  /** The only way back when the preference is taken over by custom request fields. */
  | { kind: 'advancedSettingsLink' };

export type ModelControlFooterInput = {
  context?: ModelControlFooterContext;
  /** This owner's custom fields are currently rewriting the request. */
  overridden?: boolean;
  /** Why the panel as a whole is read-only; undefined when writable. */
  readOnlyReason?: string;
  isConfigurable?: boolean;
  /** Status text to show when `!isConfigurable`. */
  statusTextKey?: ModelControlMessageKey;
  upstreamRejected?: boolean;
  riskTiers?: readonly string[];
  showsSupportedModelsAction?: boolean;
  hasSupportedModelCandidates?: boolean;
  /** The way back when the preference is taken over elsewhere. */
  showsAdvancedSettingsAction?: boolean;
  /**
   * Which way out the status row currently rendered on this card offers when opened
   * (`none` when there is no status row).
   *
   * The same way out is not stated twice: when the status row already offers "see supported
   * models", the footer stops repeating an identical link - in the `unsupported` state both
   * would always fire together.
   */
  statusRowEscape?: ModelControlEscape;
};

export function modelControlFooterEntries(input: ModelControlFooterInput): ModelControlFooterEntry[] {
  const context = input.context ?? 'panelCard';
  const entries: ModelControlFooterEntry[] = [];

  const showsSupportedModels = !input.overridden && Boolean(input.showsSupportedModelsAction)
    && input.statusRowEscape !== 'supportedModels';
  // "No model on this connection supports this capability" already contains "this capability is
  // unavailable" and additionally answers "would another model help". Showing both is the same
  // thing said twice, so keep the one that carries more information.
  const saysNoCandidates = showsSupportedModels && !input.hasSupportedModelCandidates;

  if (input.overridden) {
    entries.push({ kind: 'note', textKey: 'common.customRequestFieldsActiveNote', tone: 'warning' });
  } else if (input.readOnlyReason) {
    if (context === 'behaviorPageHeader') {
      entries.push({ kind: 'note', text: input.readOnlyReason, tone: 'tertiary' });
    }
  } else if (input.isConfigurable === false && !saysNoCandidates && context === 'behaviorPageHeader') {
    // A non-configurable state still deserves its reason where there is room for it; the compact
    // card drops the line instead of truncating it.
    if (input.statusTextKey) entries.push({ kind: 'note', textKey: input.statusTextKey, tone: 'tertiary' });
  }

  // An upstream rejection outranks the rest: it is the only entry backed by a real response
  // rather than by metadata.
  if (input.upstreamRejected) {
    entries.push({ kind: 'note', textKey: 'common.capabilityControlUpstreamRejected', tone: 'warning' });
  }

  // The risk wording is a property of the custom JSON field ("this field may cost more, or may
  // send data to a third party"), not of the capability itself. Attached to the panel card while
  // custom fields are off it reads as a warning with no subject: the reasoning card would
  // permanently warn about a field that is not on that card. Only say it when custom fields are
  // really rewriting the request, or in the advanced settings page header.
  if (input.overridden || context === 'behaviorPageHeader') {
    for (const tier of input.riskTiers ?? []) {
      entries.push({
        kind: 'note',
        textKey: tier === 'privacy_impacting' ? 'common.capabilityRiskPrivacy' : 'common.capabilityRiskCost',
        tone: 'warning',
      });
    }
  }

  if (showsSupportedModels) {
    entries.push(saysNoCandidates
      ? { kind: 'note', textKey: 'common.capabilityControlNoSupportedModels', tone: 'tertiary' }
      : { kind: 'supportedModelsLink' });
  }

  if (input.showsAdvancedSettingsAction) entries.push({ kind: 'advancedSettingsLink' });

  return entries;
}

// MARK: - Writability and identity gaps

/** Whether the panel is writable. Entry-point visibility does not consume this; only in-page controls and persistence do. */
export type ModelControlsEditability =
  | 'writable' | 'managedFree' | 'managedBalance' | 'runtimeIdentityUnavailable' | 'runtimeReadOnly';

export function resolveModelControlsEditability(input: {
  providerKind?: ProviderKind;
  transportIdentity?: string;
  runtimeIsReadOnly: boolean;
}): ModelControlsEditability {
  if (!input.transportIdentity) return 'runtimeIdentityUnavailable';
  if (input.runtimeIsReadOnly) return 'runtimeReadOnly';
  return 'writable';
}

export function modelControlsCanPersist(editability: ModelControlsEditability): boolean {
  return editability === 'writable';
}

/**
 * The three real reasons `transportIdentity` can be missing.
 *
 * They map to three completely different user actions, and collapsing them into one sentence is
 * a dead end: a tappable button promises "this will fix it" and is worse than no button when it
 * cannot address the root cause. Before adding a branch, answer whether the state really changes
 * after the user takes that action.
 *
 * The order matches the failure order of `capabilityRuntimeIdentity`: the runtime revision is the
 * first guard, and the other two cannot be determined until it is ready, so it must come first.
 */
export type ModelControlsIdentityGap =
  | 'runtimeSnapshotMissing' | 'relayTransportUndecided' | 'modelNotInCatalog';

export function resolveModelControlsIdentityGap(input: {
  providerKind?: ProviderKind;
  relayTransportIsDecided: boolean;
  runtimeIsReady: boolean;
}): ModelControlsIdentityGap {
  if (!input.runtimeIsReady) return 'runtimeSnapshotMissing';
  if (input.providerKind === 'relay' && !input.relayTransportIsDecided) return 'relayTransportUndecided';
  return 'modelNotInCatalog';
}

export type ModelControlsIdentityRecovery = 'refetchRuntime' | 'openConnectionSettings' | 'chooseAnotherModel';

export function modelControlsIdentityRecovery(gap: ModelControlsIdentityGap): ModelControlsIdentityRecovery {
  switch (gap) {
    case 'runtimeSnapshotMissing': return 'refetchRuntime';
    case 'relayTransportUndecided': return 'openConnectionSettings';
    case 'modelNotInCatalog': return 'chooseAnotherModel';
  }
}

export function modelControlsIdentityGapReasonKey(gap: ModelControlsIdentityGap): ModelControlMessageKey {
  switch (gap) {
    case 'runtimeSnapshotMissing': return 'common.capabilityControlIdentityRuntimeMissing';
    case 'relayTransportUndecided': return 'common.capabilityControlIdentityRelayTransport';
    case 'modelNotInCatalog': return 'common.capabilityControlIdentityModelMissing';
  }
}

// MARK: - transport  

/**
 * Human-readable transport label: printing a wire name like `openai_responses` to the user means
 * nothing.
 *
 * Both vocabularies must be recognised: relay stores local `RelayTransport` values
 * (`openai_chat_completions` / `llamacpp_native` ...), while official providers use the catalog
 * transport (`openai_chat` / `gemini_generate` ...). They are not interchangeable - the same Chat
 * Completions protocol is a different string on each side. When adding values, check the actual
 * distribution of `.providers[].models[].transport` in `/api/metadata` rather than copying the
 * relay enum.
 *
 * Returns undefined when unrecognised, leaving the caller to fall back to a generic label or omit
 * the section.
 */
export function modelControlTransportLabel(transport: string | undefined): string | undefined {
  switch (transport) {
    case 'openai_responses': return 'Responses';
    // catalog's `openai_chat` and relay's `openai_chat_completions` are the same protocol
    case 'openai_chat': case 'openai_chat_completions': return 'Chat Completions';
    case 'anthropic_messages': return 'Messages';
    case 'gemini_generate_content': case 'gemini_generate': return 'generateContent';
    case 'dashscope_native': return 'DashScope';
    // The image line goes through this table too: the panel does not filter by modality, so a user
    // who picked an image model in the chat page can still open it.
    case 'openai_images': return 'Images';
    case 'gemini_image': return 'imageGen';
    case 'qwen_image': return 'DashScope Image';
    case 'grok_image': return 'xAI Image';
    case 'zhipu_image': return 'Zhipu Image';
    case 'llamacpp_native': return 'llama.cpp';
    default: return undefined;
  }
}
