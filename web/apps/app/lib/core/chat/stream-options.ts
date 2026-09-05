import type { Provider, AIModel, ReasoningMode } from '@oriveo/shared';
import type { StreamOptions } from '../providers/types';
import type { CapabilityEvidenceResolution } from '@oriveo/core/providers/capability-evidence-facade';
import type { CapabilityPreferenceInput, GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { getRelayRuntimeConfig, resolveGenerationProfileRef } from '../metadata/metadata-client';
import { transportSupportsWebSearch } from '../providers/relay-runtime-support';
import {
  pickChatDriverModelID,
  relayImageRoute,
  shouldForceRelayStream,
} from '@oriveo/core/providers/relay-runtime-support';
import { restrictWireToDeclaredParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import { resolveRelayRuntimeFields } from '../providers/relay-resolution';
import { getDeclaredReasoningDefaultLevel } from '../metadata/metadata-client';
import {
  capabilityLearningIdentity,
  relayCapabilityEvidenceIdentity,
  currentCapabilityEvidenceModel,
  resolveModelCapabilityEvidence,
  resolveGenerationParameterEvidence,
  type ModelCapabilityKey,
} from './capability-evidence';
import {
  effectiveGenerationSupport,
  generationSupportPresentation,
} from './generation-support-presentation';
import { capabilityRuntimeIdentity } from './capability-preference-settings';
import { capabilityRecipeOmissions, capabilityRejectionIsDormant } from './capability-recovery-runtime';

/**
 * Free and Managed are Server-owned products, not BYOK connections. Keeping
 * this predicate at the final request boundary prevents a hidden composer
 * value or old local record from becoming an outbound request field.
 */
export function providerControlsAreManaged(provider: Provider): boolean {
  return false || false;
}

/** The managed request contract accepts no client capability/generation body. */
export function managedSafeStreamOptions(
  provider: Provider,
  options: StreamOptions | undefined,
): StreamOptions | undefined {
  return providerControlsAreManaged(provider) ? undefined : options;
}

/**
 * Build the raw StreamOptions from reasoningMode / webSearchEnabled / model.capabilities.
 *
 * A control is only carried when both the capability and the profile allow it, so an
 * ineffective toggle is never leaked upstream. Returns undefined when nothing is set.
 */
export function buildStreamOptionsFromIntent(
  model: AIModel,
  reasoningMode: ReasoningMode | undefined,
  webSearchEnabled: boolean | undefined,
  generationParameters?: GenerationParameterOverrides,
  capabilityPreferences?: CapabilityPreferenceInput,
  customFragments?: Partial<Record<'web' | 'reasoning' | 'generation', { raw: string }>>,
): StreamOptions | undefined {
  const supportsImageGen =
    model.capabilities.includes('imageGeneration') && Boolean(model.imageGenProfile);
  // Capability facts are resolved at the final request boundary below. This
  // builder only carries already-authorized intent; reading legacy web/profile
  // fields here would create a second, stale eligibility gate.
  const supportsWebSearch = capabilityPreferences ? capabilityPreferences.web !== 'off' : Boolean(webSearchEnabled);
  // 'automatic' still has to carry a level: the profile may declare a defaultLevel that Auto
  // injects. Passing undefined makes normalizeReasoningMode return undefined unchanged, so
  // defaultLevel never applies and Auto falls back to the upstream default (DeepSeek defaults
  // to high, measured at around 93s).
  const hasOptions =
    reasoningMode !== undefined || capabilityPreferences !== undefined ||
    supportsImageGen ||
    supportsWebSearch ||
    Boolean(generationParameters) || Boolean(customFragments);
  if (!hasOptions) return undefined;
  return {
    ...(reasoningMode !== undefined ? { reasoning: reasoningMode } : {}),
    supportsImageGen,
    supportsWebSearch,
    ...(capabilityPreferences ? { capabilityPreferences } : {}),
    ...(generationParameters ? { generationParameters } : {}),
    ...(customFragments ? { customFragments } : {}),
    ...(model.generationProfile
      ? { generationProfile: resolveGenerationProfileRef(model.generationProfile) }
      : {}),
  };
}

/**
 * Final facade gate for non-generation request intent.
 *
 * The question here is whether the facade allows this send (requestPolicy), not whether the
 * capability has been proven supported: `allow_explicit_unverified` still reports a support
 * value of `unknown`, so gating on support alone would turn every unknown capability into a
 * permanent rejection. Typed and legacy intent are judged by the same key and the same
 * requestPolicy rather than by two different levels of strictness.
 */
export function filterRequestCapabilityIntent(input: {
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  webSearchEnabled: boolean | undefined;
  /**
   * Whether the stored web-search preference can actually reach the wire right now.
   *
   * `web !== 'off'` only means the user expressed a preference. When the metadata carries no
   * official web-search recipe and no custom fragment takes over, that preference compiles to
   * zero request fields; counting it as an explicit request makes the whole evidence
   * projection treat the send as 'web requested' while the request in fact carries nothing.
   *
   * Omit it when the caller does not use web search at all (`webSearchEnabled: false`, or
   * `singleSend` with web 'off'). Callers that can really emit web search must pass it.
   */
  webReachesTheWire?: boolean;
  streamOptions?: StreamOptions;
}): Pick<StreamOptions, 'reasoning' | 'supportsWebSearch' | 'capabilityPreferences'> {
  const { provider, model, streamOptions } = input;
  const typed = streamOptions?.capabilityPreferences;
  const rejectedIdentity = streamOptions?.capabilityRecoveryIdentity;
  const resendOwners = new Set(streamOptions?.capabilityRecipeResendOwners ?? []);
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  const relayIdentity = relayCapabilityEvidenceIdentity(provider, model, streamOptions);
  const permitsOutbound = (key: ModelCapabilityKey, hasExplicitValue: boolean): boolean => {
    const policy = resolveModelCapabilityEvidence({
      key, provider, model, streamOptions, relayIdentity, hasExplicitValue,
    }).requestPolicy;
    return policy === 'allow' || policy === 'allow_explicit_unverified';
  };

  // Turning web search on counts as an explicit expression of that intent.
  const webDormant = rejectedIdentity && !resendOwners.has('web')
    ? capabilityRejectionIsDormant(rejectedIdentity, 'web', 'provider_recipe')
    : false;
  const webRequested = !webDormant && (input.webReachesTheWire ?? true)
    && (typed ? typed.web !== 'off' : input.webSearchEnabled === true);
  const supportsWebSearch = webRequested && permitsOutbound('web_search', true);

  // Levels always use the ReasoningMode vocabulary (low maps to fast): evidence keys exist only
  // in that form, so building a key from the typed intent vocabulary never finds a candidate.
  const typedMode: ReasoningMode | undefined = typed?.reasoningIntent === 'off' ? undefined
    : typed?.reasoningIntent === 'low' ? 'fast'
      : typed?.reasoningIntent;
  // 'automatic' is not a user-picked level: the profile's defaultLevel decides which one is
  // injected, so it is queried as non-explicit; explicit pass-through needs a real choice.
  const requestedLevel = typed
    ? typedMode
    : input.reasoningMode === 'automatic'
      ? getDeclaredReasoningDefaultLevel(evidenceModel.reasoningProfile)
      : input.reasoningMode;
  const reasoningExplicit = typed ? typedMode !== undefined : input.reasoningMode !== 'automatic';
  const reasoningDormant = rejectedIdentity && !resendOwners.has('reasoning')
    ? capabilityRejectionIsDormant(rejectedIdentity, 'reasoning', 'provider_recipe')
    : false;
  const reasoningAllowed = !reasoningDormant && requestedLevel !== undefined
    && permitsOutbound(`reasoning_level/${requestedLevel}`, reasoningExplicit);
  const reasoning = reasoningAllowed ? (typed ? typedMode : input.reasoningMode) : undefined;

  if (!typed) return { ...(reasoning !== undefined ? { reasoning } : {}), supportsWebSearch };
  // A rejected intent must also be dropped from capabilityPreferences: the v2 dispatch compile
  // reads only that copy, so leaving it there is a back door around the outbound gate. Turning
  // reasoning off is an instruction rather than a capability request, so it always passes.
  const { reasoningIntent, ...withoutReasoning } = typed;
  const keepReasoningIntent = reasoningIntent === 'off'
    || (reasoningIntent !== undefined && reasoningAllowed);
  return {
    ...(reasoning !== undefined ? { reasoning } : {}),
    supportsWebSearch,
    capabilityPreferences: {
      ...withoutReasoning,
      web: supportsWebSearch ? typed.web : 'off',
      ...(keepReasoningIntent ? { reasoningIntent } : {}),
    },
  };
}

type ResolvedRelayRuntime = ReturnType<typeof resolveRelayRuntimeFields>;

/**
 * Merge a relay provider's relayResolved* / relayRequested fields into StreamOptions.
 * Values already resolved on the provider win, falling back to the runtime resolution.
 * Field mapping only (no IO, no capability computation); supportsWebSearch is intersected with
 * the transport envelope by the caller.
 */
export function mergeRelayRuntime(
  provider: Provider,
  runtime: ResolvedRelayRuntime,
  options: StreamOptions | undefined,
  supportsWebSearch: boolean,
): StreamOptions {
  // Resolve to a value first, then assign it explicitly. A form such as
  //   `...(options?.generationProfile ? { generationProfile: ... } : relayGenerationProfile(...))`
  // spreads the profile object itself in the false branch, flattening template/wire/parameters
  // into top-level StreamOptions keys while generationProfile is never assigned (TypeScript
  // accepts it because spreads skip the excess property check). Relays that do not match the
  // official catalog -- a local engine, or a model id absent from the catalog, whose only
  // profile source is the local template -- would then inject nothing on the way out.
  const resolvedGenerationProfile = options?.generationProfile
    ?? relayGenerationProfile(provider, runtime.relayResolvedTransport);
  return {
    ...options,
    relayResolvedBaseURLText: provider.relayResolvedBaseURLText ?? runtime.relayResolvedBaseURLText,
    relayResolvedAPIBaseURLIsExact: Boolean(provider.relayRequested?.resolvedAPIBaseURL),
    relayTransport: provider.relayResolvedTransport ?? runtime.relayResolvedTransport,
    relayEngineProfile: provider.relayRequested?.engineProfile,
    relayAuthMode: provider.relayResolvedAuthMode ?? runtime.relayResolvedAuthMode,
    relaySecurityMode: provider.relayRequested?.securityMode ?? 'remote_https',
    relayHeaderProfile: provider.relayResolvedHeaderProfile ?? runtime.relayResolvedHeaderProfile,
    relayFamilyHint: provider.relayResolvedFamilyHint ?? runtime.relayResolvedFamilyHint,
    relayServiceTier: provider.relayRequested?.serviceTier,
    relayReasoningEffort:
      provider.relayRequested?.reasoningEffort && provider.relayRequested.reasoningEffort !== 'automatic'
        ? provider.relayRequested.reasoningEffort
        : undefined,
    relayStream: provider.relayRequested?.stream,
    relayDisableResponseStorage: provider.relayRequested?.disableResponseStorage,
    relayCodexCompatIdentity: provider.relayRequested?.codexCompatIdentity,
    relayCustomUserAgent: provider.relayRequested?.customUserAgent,
    relayHeaders: provider.relayRequested?.headers,
    relayQueryParams: provider.relayRequested?.queryParams,
    relayWebSearchToolName: provider.relayRequested?.webSearchToolName,
    // `/images/generations` request parameters are passed through as-is; omitting one means the
    // field is not sent and the upstream default applies.
    relayImageSize: provider.relayRequested?.imageSize,
    relayImageQuality: provider.relayRequested?.imageQuality,
    relayImageStyle: provider.relayRequested?.imageStyle,
    relayImageCount: provider.relayRequested?.imageCount,
    relayImageResponseFormat: provider.relayRequested?.imageResponseFormat,
    // relayImageToolModelID / relayDriverModelID are derived from imageRoute.
    // - Gemini transport: the capability AND imageGenProfile gate above still decides injection.
    supportsImageGen: options?.supportsImageGen,
    supportsWebSearch,
    ...(resolvedGenerationProfile ? { generationProfile: resolvedGenerationProfile } : {}),
  };
}

/**
 * Pick the matching server metadata template only when the engine is declared; an unknown
 * engine or a missing template injects nothing.
 *
 * The synthesized wire keeps only the parameter ids listed in the constant table inside this
 * function. A relay catalog comes from the user's own machine, so a key surfacing from an
 * upstream response must never become a write path.
 */
export function engineGenerationProfile(engine: 'llamacpp' | 'ollama' | 'lmstudio' | 'vllm' | 'openwebui' | undefined) {
  const template = engine === 'llamacpp'
    ? 'llamacpp_native'
    : engine === 'vllm'
      ? 'vllm_extra_body'
      : engine === 'openwebui'
        ? 'openai_chat_completions'
      : undefined;
  const resolved = template ? resolveGenerationProfileRef({
    template,
    // An engine profile is a capability source the user chose explicitly but that has not been
    // verified per model, so it is reported honestly as accepted_unverified.
    parameters: engine === 'llamacpp'
      ? ['max_output_tokens', 'stop', 'temperature', 'top_p', 'top_k', 'min_p', 'typical_p', 'repeat_penalty',
        'repeat_last_n', 'mirostat', 'mirostat_tau', 'mirostat_eta', 'dry_multiplier', 'dry_base',
        'dry_allowed_length', 'dry_penalty_last_n', 'xtc_probability', 'xtc_threshold', 'samplers',
        'ignore_eos', 'top_n_sigma', 'dynatemp_range', 'dynatemp_exponent', 'min_keep', 'n_keep',
        'n_indent', 't_max_predict_ms', 'n_probs', 'post_sampling_probs', 'seed', 'json_schema', 'logprobs']
        .map((id) => ({ id, support: 'accepted_unverified', source: 'user_declared' }))
      : engine === 'openwebui'
        ? ['max_output_tokens', 'stop', 'temperature', 'top_p', 'frequency_penalty', 'presence_penalty',
          'seed', 'response_format', 'json_schema', 'verbosity', 'logprobs', 'top_logprobs']
          .map((id) => ({ id, support: 'accepted_unverified', source: 'user_declared' }))
        : ['max_output_tokens', 'stop', 'temperature', 'top_p', 'top_k', 'min_p', 'typical_p',
          'presence_penalty', 'frequency_penalty', 'repeat_penalty', 'seed', 'json_schema', 'logprobs', 'top_logprobs']
          .map((id) => ({ id, support: 'accepted_unverified', source: 'user_declared' })),
  }) : undefined;
  return resolved ? restrictWireToDeclaredParameters(resolved) : undefined;
}

/** A plain relay with no capability evidence still shows every parameter the protocol can express, all marked unknown; only values the user fills in are sent. */
export function relayGenerationProfile(provider: Provider, resolvedTransport?: Provider['relayResolvedTransport']) {
  const engine = engineGenerationProfile(provider.relayRequested?.engineProfile);
  if (engine) return engine;
  const template = provider.relayResolvedTransport ?? resolvedTransport ?? provider.relayRequested?.transport;
  const ids = template === 'openai_chat_completions'
    ? ['max_output_tokens', 'stop', 'reasoning_effort', 'reasoning_budget', 'reasoning_mode', 'temperature', 'top_p', 'top_k', 'min_p', 'frequency_penalty', 'presence_penalty', 'repeat_penalty', 'seed', 'logprobs']
    : template === 'openai_responses'
      ? ['max_output_tokens', 'reasoning_effort', 'temperature', 'top_p', 'seed', 'logprobs']
      : template === 'anthropic_messages'
        ? ['max_output_tokens', 'stop', 'temperature', 'top_p', 'top_k']
        : template === 'gemini_generate_content'
          ? ['max_output_tokens', 'stop', 'temperature', 'top_p', 'top_k', 'presence_penalty', 'frequency_penalty', 'seed', 'logprobs']
          : [];
  if (!template || template === 'auto' || !ids.length) return undefined;
  const resolved = resolveGenerationProfileRef({
    template,
    parameters: ids.map((id) => ({ id, support: 'unknown', source: 'user_declared' })),
  });
  // As in engineGenerationProfile, the wire accepts only the local id constant table above.
  return resolved ? restrictWireToDeclaredParameters(resolved) : undefined;
}

/** The provider page and the send path share one profile resolution, so the UI never shows a field that would not be sent. */
export function resolveGenerationProfileForModel(provider: Provider, model: AIModel) {
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  const metadataProfile = resolveGenerationProfileRef(evidenceModel.generationProfile);
  if (metadataProfile) return metadataProfile;
  return provider.kind === 'relay'
    ? relayGenerationProfile(provider)
    : undefined;
}

/**
 * Final request-side gate for every persisted/transient override. The core
 * builders receive only this filtered map; no provider-wide unknown boolean
 * may widen an individual facade decision.
 */
export function filterGenerationParameterOverrides(
  provider: Provider,
  model: AIModel,
  overrides: GenerationParameterOverrides | undefined,
  streamOptions?: StreamOptions,
): GenerationParameterOverrides | undefined {
  if (!overrides) return undefined;
  if (streamOptions?.capabilityRecoveryIdentity
    && !streamOptions.capabilityRecipeResendOwners?.includes('generation')
    && capabilityRejectionIsDormant(streamOptions.capabilityRecoveryIdentity, 'generation', 'provider_recipe')) return undefined;
  const profile = resolveGenerationProfileForModel(provider, model);
  if (!profile) return undefined;
  const resolvedOptions = streamOptions ?? buildProviderStreamOptions(provider, undefined, model);
  const relayIdentity = relayCapabilityEvidenceIdentity(provider, model, resolvedOptions);
  const filtered: GenerationParameterOverrides = {};
  for (const [parameterId, override] of Object.entries(overrides)) {
    if (!override || override.state === 'inherit') continue;
    const evidence = resolveGenerationParameterEvidence({
      provider,
      model,
      profile,
      parameterId,
      hasExplicitValue: true,
      streamOptions: resolvedOptions,
      relayIdentity,
      generationRevision: profile.revision ?? model.metadataRevision,
    });
    const parameter = profile.parameters.find((item) => item.id === parameterId);
    if (parameter
      && generationParameterAdjustable(profile.wire[parameterId], parameter.support, evidence)
      && (evidence.requestPolicy === 'allow' || evidence.requestPolicy === 'allow_explicit_unverified')) {
      filtered[parameterId] = override;
    }
  }
  return Object.keys(filtered).length > 0 ? filtered : undefined;
}

// -- Visibility predicates -------------------------------------------------
// Three named predicates, no inlined copies. Session scope and connection scope deliberately
// use two different sets of criteria (which scope the reasoning group belongs to is a settled
// product decision), so collapsing them into one function would decide product behavior. No UI
// file may inline a check such as `support !== 'unsupported'`.

export type GenerationParameterEntryScope = 'session' | 'connectionDefaults';

/** Entitlement input for the connection scope. Treated as closed when it cannot be determined (fail-safe); never assumed true. */
export interface GenerationAccessGrant {
  /** Server-granted entitlement to manage runtime parameters (engine_runtime group). */
  canManageRuntime: boolean;
}

type ProfileParameter = NonNullable<
  ReturnType<typeof resolveGenerationProfileForModel>
>['parameters'][number];

/**
 * Session-scope actionable set: non-empty wire, support within the outbound allow list, and an
 * exact profile identity, with the reasoning group excluded -- the only write path for
 * session-level reasoning effort is the composer's reasoning chip.
 *
 * The allow list reuses the same constant as the outbound gate: the editable set must be a
 * subset of the set that is actually sent.
 */
export function sessionActionable(provider: Provider, model: AIModel): ProfileParameter[] {
  const profile = resolveGenerationProfileForModel(provider, model);
  if (!profile) return [];
  const streamOptions = buildProviderStreamOptions(provider, undefined, model);
  const relayIdentity = relayCapabilityEvidenceIdentity(provider, model, streamOptions);
  return profile.parameters.filter((parameter) => {
    if (!parameter.id) return false;
    if (!profile.wire[parameter.id]) return false;
    if (isReasoningParameter(parameter)) return false;
    const evidence = resolveGenerationParameterEvidence({
      provider, model, profile, parameterId: parameter.id, hasExplicitValue: false,
      streamOptions, relayIdentity, generationRevision: profile.revision ?? model.metadataRevision,
    });
    return generationParameterAdjustable(profile.wire[parameter.id], parameter.support, evidence);
  });
}

/**
 * Connection-scope render set: entitlement filtering only. Rows are not dropped by support, and
 * the reasoning group is kept (connection-level reasoning defaults really are sent, they are not
 * a read-only projection).
 *
 * A check such as `if (evidence.support === 'unsupported') return false;` must not be added
 * here. It drops every row that has official evidence of non-support, which makes the shared
 * contract's 'not adjustable' presentation classes structurally unreachable in the connection
 * panel: `fixed` and `mode_dependent` survive only because the evidence layer normalizes them
 * to `unknown`, while `unsupported` would never render at all. The user then sees the row
 * vanish instead of 'this model does not accept this parameter' plus 'show models that support
 * it'.
 *
 * Visibility and editability are two separate questions. This function answers whether to
 * render; `generationParameterAdjustable` answers whether the row is greyed out;
 * `activeGenerationParameterIds` / `applyGenerationParameters` answer whether it is sent
 * (`unsupported` stays dormant, anchored by the contract's
 * `lifecycleCases#official.declared.unsupported`).
 */
export function connectionConfigurable(
  provider: Provider,
  model: AIModel,
  entitlement: GenerationAccessGrant,
): ProfileParameter[] {
  const profile = resolveGenerationProfileForModel(provider, model);
  if (!profile) return [];
  return profile.parameters.filter((parameter) => {
    if (!parameter.id) return false;
    return parameter.group !== 'engine_runtime' || entitlement.canManageRuntime;
  });
}

/**
 * The single predicate for 'is this parameter adjustable right now': non-empty wire plus a
 * declared/evidenced presentation class that is editable under the exact identity.
 *
 * Both the panel's `editable` state and the model picker's 'supports this parameter' filter ask
 * this function. Two separate predicates would let a user filter for a supporting model and
 * then still find the row greyed out.
 */
export function generationParameterAdjustable(
  wire: string | undefined,
  declaredSupport: string,
  evidence: Pick<CapabilityEvidenceResolution, 'support' | 'source' | 'grade'>,
): boolean {
  return Boolean(wire)
    && evidence.source !== 'none'
    && generationSupportPresentation(
      effectiveGenerationSupport(declaredSupport, evidence),
    ).control === 'editable';
}

/**
 * Filter dimension for the model picker: on this connection and model, is the generation
 * parameter adjustable.
 *
 * It borrows `generationParameterAdjustable` (and through it the facade) instead of adding a
 * second predicate, the same way the capability chip reuses `capabilityAvailableForDisplay`.
 */
export function modelSupportsGenerationParameter(
  provider: Provider,
  model: AIModel,
  parameterId: string,
): boolean {
  const profile = resolveGenerationProfileForModel(provider, model);
  if (!profile) return false;
  const parameter = profile.parameters.find((item) => item.id === parameterId);
  if (!parameter) return false;
  const streamOptions = buildProviderStreamOptions(provider, undefined, model);
  const evidence = resolveGenerationParameterEvidence({
    provider, model, profile, parameterId, hasExplicitValue: false,
    streamOptions,
    relayIdentity: relayCapabilityEvidenceIdentity(provider, model, streamOptions),
    generationRevision: profile.revision ?? model.metadataRevision,
  });
  return generationParameterAdjustable(profile.wire[parameterId], parameter.support, evidence);
}

/** An entry is visible when the set for its scope is non-empty. All three entry points (detail page, settings, composer) must ask only this function. */
export function entryVisible(
  provider: Provider,
  model: AIModel,
  scope: GenerationParameterEntryScope,
  entitlement: GenerationAccessGrant = { canManageRuntime: false },
): boolean {
  return scope === 'session'
    ? sessionActionable(provider, model).length > 0
    : connectionConfigurable(provider, model, entitlement).length > 0;
}

/** Reasoning group membership: `group` wins, the id prefix is the fallback for snapshots that carry no group. */
export function isReasoningParameter(parameter: { id?: string; group?: string }): boolean {
  return parameter.group === 'reasoning' || parameter.id?.startsWith('reasoning_') === true;
}

/** Result of the relay image routing decision: main model, tool model, and whether streaming is forced. */
interface RelayImageRouting {
  relayDriverModelID?: string;
  relayImageToolModelID?: string;
  relayStream?: boolean;
}

/**
 * Derive the main model and the tool model for inline Responses image generation from the
 * transport.
 *
 * Only the `inline_responses_tool` route needs that split: images_endpoint passes the model
 * straight to `/images/generations` and gemini_modality uses responseModalities, neither of
 * which needs a chat driver.
 */
function resolveRelayImageRouting(
  provider: Provider,
  model: AIModel | undefined,
  transport: StreamOptions['relayTransport'],
  supportsImageGen: boolean,
): RelayImageRouting {
  if (!model || !supportsImageGen || !transport) return {};
  const runtimeConfig = getRelayRuntimeConfig();
  const route = relayImageRoute(transport, runtimeConfig);

  if (route === 'unsupported') {
    throw new Error(
      'Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions.',
    );
  }

  const forceStream = shouldForceRelayStream(transport, model.capabilities, runtimeConfig);
  const streamOverride = forceStream ? { relayStream: true } : {};
  if (route !== 'inline_responses_tool') return streamOverride;

  const driver = pickChatDriverModelID({
    currentModelID: model.id,
    models: provider.models.map((candidate) => ({
      id: candidate.id,
      capabilities: candidate.capabilities,
      isAvailable: candidate.isAvailable,
      isDefault: candidate.isDefault,
    })),
  });
  if (!driver.ok) {
    throw new Error('Please add a chat model to this relay before using image generation.');
  }

  return {
    ...streamOverride,
    relayDriverModelID: driver.modelID,
    // When the main model is swapped for a chat driver, the original image model becomes
    // tool.model; if it was already a chat model the upstream default image model is used.
    relayImageToolModelID: driver.modelID === model.id ? undefined : model.id,
  };
}

export function buildProviderStreamOptions(
  provider: Provider,
  options?: StreamOptions,
  model?: AIModel,
): StreamOptions | undefined {
  if (provider.kind !== 'relay') {
    if (!options || !model) return options;
    // The chat selection keeps the persisted model object stable while a new
    // metadata snapshot can replace the generation profile underneath it.
    // Request policy is already resolved from currentCapabilityEvidenceModel;
    // carry the same current, normalized profile into the final builder so a
    // same-version metadata refresh cannot authorize with the new profile but
    // inject with a stale/absent wire map.
    const generationProfile = resolveGenerationProfileForModel(provider, model);
    // Parameter-rejection self-healing for official providers is partitioned per connection as
    // well: the direct browser path (Moonshot in mainland China) and the desktop main process
    // both need this injected identity to reuse observations across requests.
    const capabilityIdentity = capabilityLearningIdentity(provider, generationProfile?.revision);
    const recoveryIdentity = capabilityRuntimeIdentity(provider, model);
    const exactRecipeOmissions = recoveryIdentity ? capabilityRecipeOmissions({
      connectionId: recoveryIdentity.providerId,
      canonicalModelId: recoveryIdentity.canonicalModelId,
      finalTransport: recoveryIdentity.finalTransport,
      runtimeRevision: recoveryIdentity.runtimeRevision,
    }) : [];
    const mergedRecipeOmissions = mergeCapabilityRecipeOmissions(options.capabilityRecipeOmissions, exactRecipeOmissions);
    return {
      ...options,
      generationProfile,
      ...(capabilityIdentity ? { capabilityIdentity } : {}),
      ...(recoveryIdentity ? { capabilityRecoveryIdentity: {
        connectionId: recoveryIdentity.providerId,
        canonicalModelId: recoveryIdentity.canonicalModelId,
        finalTransport: recoveryIdentity.finalTransport,
        runtimeRevision: recoveryIdentity.runtimeRevision,
      } } : {}),
      ...(mergedRecipeOmissions.length ? { capabilityRecipeOmissions: mergedRecipeOmissions } : {}),
    };
  }

  // Whether web search can really fire: the caller already decided supportsWebSearch, and it is
  // intersected here with the transport envelope. When the transport cannot carry web search
  // (openai_chat_completions, anthropic_messages) the toggle is closed off before the request is
  // built, so no ineffective tool reaches the upstream.
  const runtime = resolveRelayRuntimeFields({
    baseURLText: provider.relayResolvedBaseURLText ?? provider.baseURLText,
    relayRequested: provider.relayRequested,
  });
  const runtimeProvider = {
    ...provider,
    relayResolvedTransport: provider.relayResolvedTransport ?? runtime.relayResolvedTransport,
  };
  const supportsWebSearch = Boolean(
    options?.supportsWebSearch && transportSupportsWebSearch(runtimeProvider, getRelayRuntimeConfig()),
  );

  const merged = mergeRelayRuntime(provider, runtime, options, supportsWebSearch);
  // Relay negative caching must be partitioned by connection plus endpoint, or observations for
  // the same model id on a different relay would bleed across. The endpoint fingerprint is
  // computed from the real request; this only adds the connection identity and the two revisions.
  const capabilityIdentity = capabilityLearningIdentity(provider, merged.generationProfile?.revision);
  const recoveryIdentity = model ? capabilityRuntimeIdentity(provider, model, merged.relayTransport) : null;
  const exactRecipeOmissions = recoveryIdentity ? capabilityRecipeOmissions({
    connectionId: recoveryIdentity.providerId,
    canonicalModelId: recoveryIdentity.canonicalModelId,
    finalTransport: recoveryIdentity.finalTransport,
    runtimeRevision: recoveryIdentity.runtimeRevision,
  }) : [];
  const mergedRecipeOmissions = mergeCapabilityRecipeOmissions(merged.capabilityRecipeOmissions, exactRecipeOmissions);
  return {
    ...merged,
    ...(capabilityIdentity ? { capabilityIdentity } : {}),
    ...(recoveryIdentity ? { capabilityRecoveryIdentity: {
      connectionId: recoveryIdentity.providerId,
      canonicalModelId: recoveryIdentity.canonicalModelId,
      finalTransport: recoveryIdentity.finalTransport,
      runtimeRevision: recoveryIdentity.runtimeRevision,
    } } : {}),
    ...(mergedRecipeOmissions.length ? { capabilityRecipeOmissions: mergedRecipeOmissions } : {}),
    ...resolveRelayImageRouting(
      provider,
      model,
      merged.relayTransport,
      Boolean(options?.supportsImageGen),
    ),
  };
}

function mergeCapabilityRecipeOmissions(
  left: StreamOptions['capabilityRecipeOmissions'],
  right: StreamOptions['capabilityRecipeOmissions'],
): NonNullable<StreamOptions['capabilityRecipeOmissions']> {
  const output = new Map<string, NonNullable<StreamOptions['capabilityRecipeOmissions']>[number]>();
  for (const omission of [...(left ?? []), ...(right ?? [])]) {
    const pointers = [...new Set(omission.locatedPointers)].sort();
    output.set(`${omission.recipeRef}\u0000${pointers.join('\u0000')}`, { recipeRef: omission.recipeRef, locatedPointers: pointers });
  }
  return [...output.values()];
}
