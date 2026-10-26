// Dispatches by providerKind to the per-provider builder and returns a uniform ProviderRequest.
import {
  normalizeReasoningMode,
  resolveImageGenProfile,
  resolveGenerationProfile,
  resolveReasoningParams,
  resolveReasoningProfile,
  resolveRuntimeModel,
  resolveWebSearchProfile,
  type RuntimeMetadataResponse,
} from "./runtime";
import { deriveBuilderBaseURL, sanitizeMetadataBaseURL } from "../transport/endpoint-resolver";
import { buildAnthropicRequest } from "./anthropic";
import { buildDeepSeekRequest } from "./deepseek";
import { buildGeminiRequest } from "./gemini";
import { buildGeminiInteractionsRequest } from './gemini-interactions';
import { buildGrokRequest } from "./grok";
import { buildOpenAIImagesRequest } from "./images-api";
import { buildMiniMaxRequest } from "./minimax";
import { buildMiniMaxAnthropicMessagesRequest } from './minimax-anthropic-messages';
import { buildMoonshotRequest } from "./moonshot";
import { buildOpenAICompatibleRequest } from "./openai-compatible";
import { buildOpenAIRequest, buildOpenRouterRequest } from "./openai";
import { buildQwenRequest } from "./qwen";
import { buildSiliconFlowRequest } from "./siliconflow";
import { buildZhipuRequest } from "./zhipu";
import { buildRelayReasoningParams } from "./utils";
import { applyCapabilityRecipes, attachCapabilityExecution, recipeContinuationInstructionsMode, isMiniMaxAnthropicMessagesRoute, legacyGenerationGateAllowsInjection, resolveAutomaticReasoningRecipe, resolveCapabilityExecutionPlan, type CapabilityExecutionPlan, type RuntimeRecipe } from './capability-execution';
import { compileSafeCustomFragment, rejectSafeCustomFragment, type SafeCustomFragmentResult } from './safe-custom-fragment';
import { mapContinuationForRecipe } from './continuation-replay';
import { applyAdditionalBodyToRequest } from './additional-body';
import { mergeDroppedGenerationParameters, safeCustomDeclaredOwners, safeCustomOwners, wireRejectionReason } from './generation-parameters';
import { guardAnthropicThinking } from './anthropic-thinking';
import type { GenerationParameterOverrides, GenerationParameterProfile, ProviderRequest, RequestParams } from "./types";
import type { MetadataBaseURLRejectionReporter } from "../transport/endpoint-resolver";
import { applyToolCallWireAdapter, moveHostMemoryToolsLast, protocolForRequest } from './tool-call-wire-adapter';
import { chatMaxOutputTokens } from './anthropic-thinking';
import { buildOfficialAlternateProtocolRequest, officialAlternateProtocol } from './official-protocol';

/**
 * Metadata provider port: this package does not embed the /api/metadata fetch or its cache.
 * The web route injects `getRuntimeMetadata` (which has a TTL cache); the desktop main process
 * injects a snapshot-backed implementation.
 */
export type MetadataProvider = () => Promise<RuntimeMetadataResponse | null>;

export async function buildProviderRequest(
  params: RequestParams,
  metadataProvider: MetadataProvider,
  reportRejectedMetadataBaseURL?: MetadataBaseURLRejectionReporter,
): Promise<ProviderRequest> {
  const metadata = await metadataProvider();
  const runtimeModel = resolveRuntimeModel(
    metadata,
    params.providerKind,
    params.modelID,
  );
  const reasoningProfileName = runtimeModel?.model.profiles?.reasoning;
  const webSearchProfileName = runtimeModel?.model.profiles?.webSearch;
  const imageGenProfileName = runtimeModel?.model.profiles?.imageGen;
  const reasoningProfile = resolveReasoningProfile(
    metadata,
    reasoningProfileName,
  );
  const typedReasoning = params.options?.capabilityPreferences?.reasoningIntent;
  const normalizedReasoningMode = typedReasoning === 'off' ? undefined : typedReasoning
    ? ({ low: 'fast', balanced: 'balanced', deep: 'deep', max: 'max' } as const)[typedReasoning]
    : normalizeReasoningMode(
    metadata,
    reasoningProfileName,
    params.options?.reasoning,
  );
  const normalizedParams: RequestParams = normalizedReasoningMode === params.options?.reasoning
    ? params
    : {
        ...params,
        options: {
          ...params.options,
          reasoning: normalizedReasoningMode,
        },
      };
  const capabilityPlan = resolveCapabilityExecutionPlan(
    normalizedParams,
    metadata?.capabilityRuntime,
    runtimeModel?.model,
    normalizedReasoningMode,
  );
  const customSelections = normalizedParams.options?.customFragments;
  const customReasoningSelected = customSelections?.reasoning != null;
  const customWebSelected = customSelections?.web != null;
  const customGenerationSelected = customSelections?.generation != null
    || normalizedParams.options?.customFragment != null;
  const providerConfig = metadata?.providerConfigs?.find((config) => config.kind === normalizedParams.providerKind);
  const sanitizedMetadataBaseURL = sanitizeMetadataBaseURL(
    normalizedParams.providerKind,
    runtimeModel?.provider.transport?.baseUrl,
    reportRejectedMetadataBaseURL,
    providerConfig?.trustedHosts,
  );
  // metadata transport arrives in two shapes (already normalized, or a bare origin in baseUrl
  // plus full endpoint paths). Both are bridged to the base the builder expects; an unrecognized
  // shape returns undefined and falls back to providerDefaults, so a bare origin is never passed
  // straight through for the builder to concatenate a short path onto and hit the wrong endpoint.
  const metadataBaseURL = sanitizedMetadataBaseURL
    ? deriveBuilderBaseURL(
        normalizedParams.providerKind,
        sanitizedMetadataBaseURL,
        runtimeModel?.provider.transport?.endpoints,
      )
    : undefined;
  const effectiveParams: RequestParams = normalizedParams.baseURL || !metadataBaseURL
    ? normalizedParams
    : { ...normalizedParams, baseURL: metadataBaseURL };
  const reasoningParams = customReasoningSelected || capabilityPlan.overridesLegacy.has('reasoning')
    ? null
    : resolveReasoningParams(
      metadata,
      reasoningProfileName,
      normalizedReasoningMode,
    );
  const transportReasoningProfile = capabilityPlan.overridesLegacy.has('reasoning')
    ? null
    : reasoningProfile;
  const webSearchProfile = !customWebSelected && !capabilityPlan.overridesLegacy.has('web') && (effectiveParams.options?.capabilityPreferences ? effectiveParams.options.capabilityPreferences.web !== 'off' : effectiveParams.options?.supportsWebSearch)
    ? resolveWebSearchProfile(metadata, webSearchProfileName)
    : null;
  const imageGenProfile = resolveImageGenProfile(metadata, imageGenProfileName);
  const resolvedGenerationProfile = resolveGenerationProfile(
    metadata,
    runtimeModel?.model.profiles?.generation,
  );
  const generationRecipe = capabilityPlan.recipes.find((recipe) => recipe.capability === 'generation');
  // A valid runtime generation control owns the template decision. The typed builder remains
  // backwards-compatible only where that control is absent; a mismatch is zero injection.
  // The additional body coexists with panel parameters (additional body contract): the old implementation cleared the whole panel parameter group once a generation custom field was written, which is gone.
  const generationProfile = capabilityPlan.overridesLegacy.has('generation')
    ? legacyGenerationGateAllowsInjection(generationRecipe, resolvedGenerationProfile?.template)
      ? resolvedGenerationProfile
      : null
    : resolvedGenerationProfile;
  const withGenerationProfile: RequestParams = generationProfile
    ? {
        ...effectiveParams,
        options: {
          ...effectiveParams.options,
          generationProfile,
        },
      }
    : effectiveParams;

  const bypassOfficialImageDispatch =
    withGenerationProfile.providerKind === "relay"; // capability-lint-allow R2: image generation route bypass, does not decide attachment shape
  if (!bypassOfficialImageDispatch) {
    const metadataDeclaresImageGeneration =
      runtimeModel?.model.capabilities?.includes("imageGeneration") === true;
    const requestDeclaresImageGeneration = withGenerationProfile.options?.supportsImageGen === true;
    const profileDeclaresImageGeneration = Boolean(imageGenProfileName);
    const needsImageRoute =
      metadataDeclaresImageGeneration ||
      requestDeclaresImageGeneration ||
      profileDeclaresImageGeneration;

    if (needsImageRoute) {
      const route = imageGenProfile?.route;
      if (!imageGenProfileName || !imageGenProfile || !route) {
        throw new Error("Image generation route is missing or unknown for this model");
      }

      switch (route) {
        case "images_api":
          // images_api returns before the `applyRecipes` below, but fail-closed is this layer's
          // promise: the editor states that messages using the control will fail to send, so a
          // path that silently drops the custom fields and sends the request anyway would break
          // that promise. Custom field compilation therefore runs on every outbound path, not
          // only the chat branch. Capability recipes are not applied here; those shape the chat
          // protocol request.
          return applyCustomFragmentsOnly(
            buildOpenAIImagesRequest(withGenerationProfile, imageGenProfile),
            params.options?.customFragments ?? (params.options?.customFragment
              ? { generation: params.options.customFragment }
              : {}),
            capabilityPlan.customDeclaredOwners ?? {},
          );
        case "dashscope_multimodal":
          if (withGenerationProfile.providerKind !== "qwen") { // capability-lint-allow R2: route ownership check, does not decide attachment shape
            throw new Error(`Image generation route ${route} is invalid for ${withGenerationProfile.providerKind}`);
          }
          break;
        case "minimax_image_generation":
          if (withGenerationProfile.providerKind !== "miniMax") { // capability-lint-allow R2: route ownership check, does not decide attachment shape
            throw new Error(`Image generation route ${route} is invalid for ${withGenerationProfile.providerKind}`);
          }
          break;
        case "chat_api":
          if (
            withGenerationProfile.providerKind !== "openRouter" && // capability-lint-allow R2: route ownership check, does not decide attachment shape
            withGenerationProfile.providerKind !== "gemini" // capability-lint-allow R2: route ownership check, does not decide attachment shape
          ) {
            throw new Error(`Image generation route ${route} is invalid for ${withGenerationProfile.providerKind}`);
          }
          break;
        default:
          throw new Error("Image generation route is missing or unknown for this model");
      }
    }
  }

  // The additional body is the last step of every chat request body: merged after the builder, the capability recipe and custom fragments.
  // images_api is not a chat body and returns early, never passing through here.
  // plan defaults to all the recipes selected this turn; when Gemini goes through generateContent it is given the subset
  // with the gemini_interactions protocol removed, and those recipes are neither compiled into the body nor recorded as execution facts.
  const applyRecipes = (request: ProviderRequest, plan: CapabilityExecutionPlan = capabilityPlan): ProviderRequest => applyAdditionalBodyToRequest(
    applyRecipesBeforeAdditionalBody(request, plan),
    effectiveParams.options?.additionalBody,
  );
  const applyRecipesBeforeAdditionalBody = (request: ProviderRequest, plan: CapabilityExecutionPlan): ProviderRequest => {
    // The library tools for /api/chat/stream have to become the builder-owned base first and
    // then have the web server tool merged in. Assigning them wholesale after the builder would
    // wipe the tools set by the v2 recipe.
    const withBuilderTools = params.tools?.length
      ? applyToolCallWireAdapter(request, params)
      : request;
    const compiled = applyCapabilityRecipes(
      withBuilderTools.body,
      plan.recipes,
      plan.intents ?? {},
      effectiveParams.options?.capabilityRecipeOmissions,
    );
    // Attach the host memory tools after the recipe has compiled its server tools into /tools/-.
    moveHostMemoryToolsLast(protocolForRequest(withBuilderTools), compiled.body, params.tools);
    // A recipe may write the thinking field only after the builder (official Anthropic), so the linked protection is evaluated once more after thinking and generation
    // parameters are both written (shared contract outboundRules.anthropicThinking.evaluatedAfter); this happens before custom fragments and the additional body,
    // so a same-named field written explicitly in the additional body still wins. The builder's own call is kept; the two are idempotent.
    // It uses the same profile as the builder call (when metadata has no generation profile, the one supplied by the caller).
    const builderGenerationProfile = withGenerationProfile.options?.generationProfile;
    const thinkingDropped = builderGenerationProfile?.template === 'anthropic_messages' && withBuilderTools.generationWrite
      ? guardAnthropicThinking(compiled.body, {
        profile: builderGenerationProfile,
        written: withBuilderTools.generationWrite.written,
        builderDefaultMaxTokens: withBuilderTools.generationWrite.builderDefaultMaxTokens,
      })
      : [];
    const droppedGenerationParameters = thinkingDropped.length > 0
      ? mergeDroppedGenerationParameters(withBuilderTools.droppedGenerationParameters ?? [], thinkingDropped)
      : withBuilderTools.droppedGenerationParameters;
    const typedGenerationDelta = generationRecipe
      ? emittedGenerationDelta(thinkingDropped.length > 0 ? compiled.body : withBuilderTools.body, effectiveParams.options?.generationParameters, generationProfile)
      : {};
    // Official-provider writable paths come only from plan.customDeclaredOwners
    // (customControlRefs resolved against the same runtime envelope). Relay's generation
    // exception is derived solely from its exact local transport profile.
    const declaredOwners = {
      ...(effectiveParams.providerKind === 'relay' && customGenerationSelected // capability-lint-allow R2: relay custom field ownership, does not decide attachment shape
        ? safeCustomOwners(resolvedGenerationProfile)
        : {}),
      ...(plan.customDeclaredOwners ?? {}),
    };
    const fragments = params.options?.customFragments ?? (params.options?.customFragment
      ? { generation: params.options.customFragment }
      : {});
    const {
      delta: customDelta, preview: customPreview, appliedPointers: customAppliedPointers,
    } = compileCustomFragments(compiled.body, fragments, declaredOwners);
    const continuationRecipe = plan.recipes.find((recipe) => recipe.continuationKind === params.continuation?.kind
      && (recipe.continuationVariant ?? undefined) === (params.continuation?.variant ?? undefined));
    // The app layer decided stateful: upstream must really be able to continue, otherwise the outbound history would be only the continuation sentence and must not be sent silently.
    if (params.continuationDecision?.kind === 'stateful' && !continuationRecipe) {
      throw new Error('Stateful continuation decision has no matching continuation recipe');
    }
    const continuation = continuationRecipe
      ? mapContinuationForRecipe(continuationRecipe, params.continuation, params.continuationFingerprint, params.continuationDecision)
      : null;
    const continuationDelta: Record<string, unknown> = continuation?.accepted && continuation.target === 'body'
      ? continuation.delta
      : continuation?.accepted && continuation.target === 'message_append'
        ? { messages: insertReplayBeforeFinalUser(Array.isArray(compiled.body.messages) ? compiled.body.messages : [], continuation.messages) }
        : continuation?.accepted && continuation.target === 'contents_append'
          ? { contents: insertReplayBeforeFinalUser(Array.isArray(compiled.body.contents) ? compiled.body.contents : [], continuation.contents) }
          : {};
    const omittedRoots = continuation?.accepted && continuation.target === 'body' ? continuation.omitRoots ?? [] : [];
    if (plan.recipes.length === 0 && Object.keys(customDelta).length === 0 && !plan.noExecute) return withBuilderTools;
    const withFacts: ProviderRequest = {
      ...withBuilderTools,
      ...(droppedGenerationParameters ? { droppedGenerationParameters } : {}),
      body: withoutRoots(mergeBodyDeltas(compiled.body, customDelta, continuationDelta), omittedRoots),
      ...continuationCapture(plan.recipes),
      capabilityExecution: {
        recipeRefs: plan.recipes.map((recipe) => recipe.id),
        delta: mergeBodyDeltas(compiled.delta, typedGenerationDelta, customDelta, continuationDelta),
        // continuation contains opaque provider state (reasoning blocks, signatures and Fiber
        // encrypted output). It is sent on the wire but is never eligible for a delta preview.
        redactedPreview: mergeBodyDeltas(compiled.preview, typedGenerationDelta, customPreview, redactContinuationPreview(continuationDelta)),
        resultEnvelope: metadata?.capabilityRuntime,
        // The generation owner stays out of the execution-evidence state machine. Every
        // generation recipe binds responseEvidenceDefinitions whose signals are empty arrays (no
        // official API echoes back "your temperature was applied"), so it could structurally
        // only ever sit at unconfirmed -- a status bit that can neither be promoted nor demoted
        // carries no information and simply reads as "it never worked".
        // Only the after-the-fact badge is switched off here: typedGenerationDelta still flows
        // into delta/redactedPreview, and the generation parameters the user set are still
        // written to the wire by the builder. Custom fragment owner facts, generation included,
        // are kept.
        wireAppliedOwners: Object.fromEntries([
          ...plan.recipes
            .filter((recipe) => recipe.capability !== 'generation')
            .map((recipe) => [recipe.capability, recipeDeltaWasEmitted(recipe, compiled.delta)] as const),
          ...Object.keys(fragments).map((owner) => [owner, Object.keys(customDelta).length > 0] as const),
        ]) as Partial<Record<'web' | 'reasoning' | 'generation', boolean>>,
        ...(Object.keys(fragments).filter((owner): owner is 'web' | 'reasoning' | 'generation' => owner === 'web' || owner === 'reasoning' || owner === 'generation').length > 0
          ? { customOwners: Object.keys(fragments).filter((owner): owner is 'web' | 'reasoning' | 'generation' => owner === 'web' || owner === 'reasoning' || owner === 'generation') }
          : {}),
        ...(Object.keys(customAppliedPointers).length > 0 ? { customAppliedPointers } : {}),
      },
    };
    return attachCapabilityExecution(withFacts, plan);
  };

  // An official family whose delivered apiProtocol is not its native protocol family goes through the Relay builder by protocol,
  // and providerKind decides only the authentication and the extra headers; if it equals the native family, is missing or is unrecognized, the per-family builder below
  // is used (byte for byte unchanged). The per-family recipe is the native protocol's request shape and is not applied to another protocol; the additional body is still the last step.
  const alternateProtocol = officialAlternateProtocol(withGenerationProfile.providerKind, providerConfig?.apiProtocol);
  if (alternateProtocol) {
    return applyAdditionalBodyToRequest(
      buildOfficialAlternateProtocolRequest(
        withGenerationProfile,
        alternateProtocol,
        sanitizedMetadataBaseURL,
        metadata?.relayRuntimeConfig ?? null,
      ),
      effectiveParams.options?.additionalBody,
    );
  }

  // The main-chat output limit (oWire) only replaces the base value of builders that already send an output limit; OpenRouter sends one only when the model carries maxOutputTokens.
  const chatOutputLimit = chatMaxOutputTokens(withGenerationProfile.options?.maxOutputTokens);
  const modelOutputLimit = runtimeModel?.model.maxOutputTokens;
  const openRouterOutputLimit = chatMaxOutputTokens(modelOutputLimit) !== undefined
    ? chatOutputLimit ?? modelOutputLimit
    : modelOutputLimit;
  switch (withGenerationProfile.providerKind) {
    case "openRouter":
      // The tools in the or_web profile use the chat completions schema, matching the OpenRouter builder endpoint, so they can be injected.
      return applyRecipes(buildOpenRouterRequest(
        withGenerationProfile,
        reasoningParams,
        webSearchProfile,
        imageGenProfile,
        openRouterOutputLimit,
      ));
    case "deepseek":
      return applyRecipes(buildDeepSeekRequest(
        withGenerationProfile,
        reasoningParams,
        runtimeModel?.provider.transport?.requestProfile?.streamOptionsIncludeUsage === true,
      ));
    case "grok":
      // Grok web search ships grok_responses_web (Responses schema); once tools[0].type matches,
      // the builder switches wholesale to the /responses endpoint and Responses input, while
      // non-search requests stay on Chat Completions.
      // A model-level transport=openai_responses (sent by the backend as defaultTransport, as for
      // grok-4.20-multi-agent, which xAI does not allow on chat completions) also forces
      // /responses: the endpoint decision has a single source of truth in the backend signal.
      // reasoning_effort injection is driven by the reasoning profile the server sends
      // (AssignProfiles gates it against a measured allowlist), so the builder keeps no local
      // model allowlist, which would drift from the backend.
      return applyRecipes(buildGrokRequest(
        withGenerationProfile,
        reasoningParams,
        webSearchProfile,
        runtimeModel?.model.transport,
      ));
    case "openAI":
      // OpenAI web search ships oai_responses_web (Responses schema) or oai_web_tool (Chat
      // schema, gpt-5-search-api only); the builder picks Responses or Chat Completions from
      // tools[0].type.
      return applyRecipes(buildOpenAIRequest(
        withGenerationProfile,
        metadata,
        transportReasoningProfile,
        reasoningParams,
        imageGenProfile,
        webSearchProfile,
        capabilityPlan.recipes.find((recipe) => recipe.providerKind === 'openAI')?.transport?.endpointClass, // capability-lint-allow R2: the recipe carries its own providerKind, does not decide attachment shape
        runtimeModel?.model.transport,
      ));
    case "miniMax":
      {
        const alternateRoute = capabilityPlan.recipes
          .find((recipe) => recipe.executionKind === 'endpoint_route'
            && isMiniMaxAnthropicMessagesRoute(recipe.route))?.route;
        if (isMiniMaxAnthropicMessagesRoute(alternateRoute)) {
          return applyRecipes(buildMiniMaxAnthropicMessagesRequest(
            withGenerationProfile,
            alternateRoute,
            chatOutputLimit ?? runtimeModel?.model.maxOutputTokens,
          ));
        }
      }
      return applyRecipes(buildMiniMaxRequest(withGenerationProfile, reasoningParams, imageGenProfile));
    case "zhipu":
      // The tools in the zhipu_web profile use the chat completions schema, matching the Zhipu builder endpoint, so they can be injected.
      return applyRecipes(buildZhipuRequest(withGenerationProfile, reasoningParams, webSearchProfile));
    case "qwen":
      return applyRecipes(buildQwenRequest(withGenerationProfile, reasoningParams, webSearchProfile, imageGenProfile));
    case "moonshot":
      return applyRecipes(buildMoonshotRequest(withGenerationProfile, reasoningParams, webSearchProfile));
    case "siliconFlow":
      return applyRecipes(buildSiliconFlowRequest(withGenerationProfile, reasoningParams));
    case "togetherAI":
    case "groq":
    case "fireworksAI":
    // Mistral is plain OpenAI Chat Completions; the Magistral thinking switch (prompt_mode) is
    // sent by the backend reasoning profile mistral_prompt and injected through the shared
    // mergeParams, so no dedicated builder is needed.
    case "mistral":
      return applyRecipes(buildOpenAICompatibleRequest(withGenerationProfile, reasoningParams));
    case "relay":
      return applyRecipes(buildOpenAICompatibleRequest(
        withGenerationProfile,
        buildRelayReasoningParams(normalizedReasoningMode),
      ));
    case "anthropic":
      // The tools in the ant_web_tool profile use the Messages API schema, matching the Anthropic builder endpoint, so they can be injected.
      return applyRecipes(buildAnthropicRequest(
        withGenerationProfile,
        reasoningParams,
        webSearchProfile,
        chatOutputLimit ?? runtimeModel?.model.maxOutputTokens,
        runtimeModel?.model.promptCache?.policyRef,
      ));
    case "gemini":
      // The tools in the gem_web / gem_web_retrieval profiles use the generateContent schema,
      // matching the Gemini builder endpoint, so they can be injected.
      // endpoint_route additionally requires the server to classify the model transport as
      // gemini_interactions; the default generateContent transport does not match, so
      // resolveRuntimeRecipe fails safe and behavior is unchanged.
      // Interactions is chosen only when web search is on (the web recipe is in the plan), the web control points at endpoint_route, and the whole
      // request history has no video; video is still delivered as generateContent inlineData, without an error.
      {
        const interactionRoute = capabilityPlan.recipes.find((recipe) => recipe.executionKind === 'endpoint_route')?.route;
        // A video whose bytes are not loaded does not become a video_url part; the client judges it from the outbound history and brings it along in options.
        const outboundHasVideo = withGenerationProfile.options?.outboundHistoryHasVideo === true
          || messagesCarryVideo(withGenerationProfile.messages);
        if (interactionRoute && !outboundHasVideo) {
          // The reasoning recipe is compiled by the builder (including the automatic tier, selectedIntent=null); the one for a selected tier is still in
          // the plan, and applyRecipes writes the same value again to record the execution fact. The web /tools append is done only by applyRecipes;
          // if the builder wrote it first it would dedupe to an empty delta and lose the web execution fact.
          const reasoningRecipe = capabilityPlan.recipes.find((recipe) => recipe.capability === 'reasoning' && recipe.executionKind === 'request_overlay')
            ?? resolveAutomaticReasoningRecipe(effectiveParams, metadata?.capabilityRuntime, runtimeModel?.model, normalizedReasoningMode);
          return applyRecipes(buildGeminiInteractionsRequest(withGenerationProfile, interactionRoute, {
            reasoningRecipe,
            reasoningIntent: capabilityPlan.intents?.reasoning ?? null,
          }));
        }
      }
      return applyRecipes(
        buildGeminiRequest(withGenerationProfile, reasoningParams, webSearchProfile, imageGenProfile),
        withoutGeminiInteractionsRecipes(capabilityPlan),
      );
    default:
      throw new Error(`Unsupported provider: ${params.providerKind}`);
  }
}

/**
 * The single compilation entry point for custom request fields. Every outbound path goes through
 * it, which is what makes fail-closed real.
 *
 * Reaching this layer means the owner was explicitly set to custom by the user, so an empty draft
 * is not "nothing to add": skipping it silently would send a downgraded request, while the editor
 * states in red that the message will fail to send. The draft is handed to the compiler as-is,
 * which rejects it (neither empty nor invalid JSON is accepted), and this throws.
 */
function compileCustomFragments(
  baseBody: Readonly<Record<string, unknown>>,
  fragments: Partial<Record<'web' | 'reasoning' | 'generation', { raw: string }>>,
  declaredOwners: Readonly<Record<string, 'web' | 'reasoning' | 'generation'>>,
): {
  delta: Record<string, unknown>;
  preview: Record<string, unknown>;
  appliedPointers: Partial<Record<'web' | 'reasoning' | 'generation', string[]>>;
} {
  let body = baseBody;
  let delta: Record<string, unknown> = {};
  let preview: Record<string, unknown> = {};
  const appliedPointers: Partial<Record<'web' | 'reasoning' | 'generation', string[]>> = {};
  for (const owner of ['web', 'reasoning', 'generation'] as const) {
    const declared = fragments[owner];
    if (declared === undefined) continue;
    const custom = compileSafeCustomFragment(declared.raw.trim(), owner, declaredOwners, body);
    if (!custom.accepted) throw rejectSafeCustomFragment(owner, declared.raw, custom);
    body = mergeBodyDeltas(body, custom.delta);
    delta = mergeBodyDeltas(delta, custom.delta);
    preview = mergeBodyDeltas(preview, custom.preview);
    appliedPointers[owner] = custom.pointers;
  }
  return { delta, preview, appliedPointers };
}

/**
 * Applies custom fields on outbound paths that do not go through a capability recipe (currently
 * only images_api). With no delta the input is returned unchanged, rather than attaching an empty
 * `capabilityExecution` to such requests.
 */
function applyCustomFragmentsOnly(
  request: ProviderRequest,
  fragments: Partial<Record<'web' | 'reasoning' | 'generation', { raw: string }>>,
  declaredOwners: Readonly<Record<string, 'web' | 'reasoning' | 'generation'>>,
): ProviderRequest {
  const owners = (Object.keys(fragments) as Array<'web' | 'reasoning' | 'generation'>)
    .filter((owner) => fragments[owner] !== undefined);
  if (owners.length === 0) return request;
  const compiled = compileCustomFragments(request.body, fragments, declaredOwners);
  if (Object.keys(compiled.delta).length === 0) return request;
  return {
    ...request,
    body: mergeBodyDeltas(request.body, compiled.delta),
    capabilityExecution: {
      recipeRefs: [],
      delta: compiled.delta,
      redactedPreview: compiled.preview,
      wireAppliedOwners: Object.fromEntries(owners.map((owner) => [owner, true])) as Partial<Record<'web' | 'reasoning' | 'generation', boolean>>,
      customOwners: owners,
      ...(Object.keys(compiled.appliedPointers).length > 0 ? { customAppliedPointers: compiled.appliedPointers } : {}),
    },
  };
}

function recipeDeltaWasEmitted(recipe: RuntimeRecipe, delta: Record<string, unknown>): boolean {
  return recipe.requestOps.some((operation) => {
    if (!operation || typeof operation !== 'object') return false;
    const pointer = (operation as { pointer?: unknown }).pointer;
    if (typeof pointer !== 'string' || !pointer.startsWith('/')) return false;
    let cursor: unknown = delta;
    const segments = pointer.slice(1).split('/');
    for (const segment of segments) {
      if (segment === '-') return Array.isArray(cursor) && cursor.length > 0;
      if (!cursor || typeof cursor !== 'object' || !(segment in cursor)) return false;
      cursor = (cursor as Record<string, unknown>)[segment];
    }
    return true;
  });
}

/**
 * Both helpers live in `generation-parameters`, a leaf module, because the relay orchestration
 * layer needs them too and importing this module from there would pull the whole builder
 * dependency graph into the relay browser bundle. They are re-exported here so existing call
 * sites keep their import paths.
 */
export { safeCustomDeclaredOwners, safeCustomOwners };

/**
 * UI lint/preview companion for the production compiler. It deliberately
 * consumes the already-resolved runtime recipe list and applies those recipe
 * operations before compiling the fragment, so a recipe-owned conflict is
 * rejected before a send. The final builder remains authoritative because it
 * contributes its concrete provider body as well.
 */
export function previewSafeCustomFragment(input: {
  raw: string;
  owner?: 'web' | 'reasoning' | 'generation';
  generationProfile: GenerationParameterProfile | null | undefined;
  recipes: readonly RuntimeRecipe[];
  intents: Parameters<typeof applyCapabilityRecipes>[2];
  declaredOwners?: Readonly<Record<string, 'web' | 'reasoning' | 'generation'>>;
}): SafeCustomFragmentResult {
  const applied = applyCapabilityRecipes({}, input.recipes, input.intents);
  return compileSafeCustomFragment(
    input.raw,
    input.owner ?? 'generation',
    input.declaredOwners ?? safeCustomDeclaredOwners(input.generationProfile),
    applied.body,
  );
}

/** Read the builder's already-validated emitted typed values rather than reimplementing its
 * support/range/conflict rules. This makes the recipe preview an observation of production wire. */
function emittedGenerationDelta(
  body: Readonly<Record<string, unknown>>,
  overrides: GenerationParameterOverrides | undefined,
  profile: GenerationParameterProfile | null | undefined,
): Record<string, unknown> {
  if (!profile || !overrides) return {};
  const delta: Record<string, unknown> = {};
  for (const [id, override] of Object.entries(overrides)) {
    if (override?.state !== 'value') continue;
    const wire = profile.wire[id];
    if (!wire || wireRejectionReason(wire) != null) continue;
    const value = readBodyPath(body, wire.split('.'));
    if (value === undefined) continue;
    writeBodyPath(delta, wire.split('.'), value);
  }
  return delta;
}

function readBodyPath(body: Readonly<Record<string, unknown>>, segments: readonly string[]): unknown {
  let current: unknown = body;
  for (const segment of segments) {
    if (!isRecord(current) || !Object.prototype.hasOwnProperty.call(current, segment)) return undefined;
    current = current[segment];
  }
  return current;
}

function writeBodyPath(body: Record<string, unknown>, segments: readonly string[], value: unknown): void {
  let current = body;
  for (const segment of segments.slice(0, -1)) {
    const nested = current[segment];
    current[segment] = isRecord(nested) ? { ...nested } : {};
    current = current[segment] as Record<string, unknown>;
  }
  current[segments.at(-1)!] = value;
}

function withoutRoots(body: Record<string, unknown>, roots: readonly string[]): Record<string, unknown> {
  for (const root of roots) delete body[root];
  return body;
}

function mergeBodyDeltas(base: Readonly<Record<string, unknown>>, ...deltas: Array<Readonly<Record<string, unknown>>>): Record<string, unknown> {
  const output: Record<string, unknown> = { ...base };
  for (const delta of deltas) {
    for (const [key, value] of Object.entries(delta)) {
      output[key] = isRecord(value) && isRecord(output[key])
        ? mergeBodyDeltas(output[key], value)
        : value;
    }
  }
  return output;
}

function pointersOverlap(left: string, right: string): boolean {
  return left === right || left.startsWith(`${right}/`) || right.startsWith(`${left}/`);
}

function isRecord(value: unknown): value is Record<string, unknown> { return value != null && typeof value === 'object' && !Array.isArray(value); }

/** On the generateContent route, recipes of the gemini_interactions protocol never enter the body and do not count as requested. */
function withoutGeminiInteractionsRecipes(plan: CapabilityExecutionPlan): CapabilityExecutionPlan {
  const recipes = plan.recipes.filter((recipe) => recipe.transport?.protocol !== 'gemini_interactions');
  return recipes.length === plan.recipes.length ? plan : { ...plan, recipes, noExecute: recipes.some((recipe) => recipe.executionKind === 'external_connector' || recipe.executionKind === 'unavailable') };
}

/** Any message in the request history (including the current turn) carries a video attachment; this route does not accept video, so it stays on generateContent. */
function messagesCarryVideo(messages: RequestParams['messages']): boolean {
  return messages.some((message) => typeof message.content !== 'string'
    && message.content.some((part) => part.type === 'video_url'));
}

function continuationCapture(recipes: readonly import('./capability-execution').RuntimeRecipe[]): Pick<ProviderRequest, 'continuationCapture'> {
  const candidates = recipes.filter((recipe) => recipe.continuationKind && recipe.continuationKind !== 'none'
    && typeof recipe.transport?.protocol === 'string' && typeof recipe.responseParserKind === 'string');
  const selected = candidates.find((recipe) => recipe.executionKind === 'client_tool_loop') ?? candidates[0];
  if (!selected?.continuationKind || !selected.transport?.protocol || !selected.responseParserKind) return {};
  return { continuationCapture: {
    kind: selected.continuationKind,
    protocol: selected.route?.sourceProtocol === selected.transport.protocol
      ? selected.route.protocol
      : selected.transport.protocol,
    responseParserKind: selected.responseParserKind,
    ...(recipeContinuationInstructionsMode(selected) ? { instructionsMode: recipeContinuationInstructionsMode(selected) } : {}),
  } };
}

function insertReplayBeforeFinalUser(base: unknown[], replay: unknown[]): unknown[] {
  const last = base.at(-1);
  return isUserMessage(last) ? [...base.slice(0, -1), ...replay, last] : [...base, ...replay];
}

function isUserMessage(value: unknown): boolean {
  return typeof value === 'object' && value != null && !Array.isArray(value)
    && (value as Record<string, unknown>).role === 'user';
}

/** Preview structural continuation fields without retaining prompt/response/opaque replay data. */
function redactContinuationPreview(delta: Readonly<Record<string, unknown>>): Record<string, unknown> {
  if (Object.keys(delta).length === 0) return {};
  return Object.fromEntries(Object.keys(delta).map((key) => [key, '<redacted continuation>']));
}
