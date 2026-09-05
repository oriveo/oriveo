/**
 * Compiles production requests from the capability runtime.
 *
 * The server is the only selector of an official recipe; nothing here guesses a
 * capability from a provider or model string. Once a valid v2 envelope ships a control
 * for a capability on the current model, that control overrides the legacy profile path:
 * an auto recipe is compiled from its requestOps, while a non-auto, dangling or
 * malformed recipe injects nothing at all. The legacy mapping is kept only when there is
 * no valid runtime, or the model carries no such control.
 */

import { resolveControl, resolveCustomControlDefinitions, validateEnvelope, type CapabilityControl } from '../request-preference/capability-runtime';
import { compileOwnedPatches } from '../request-preference/owned-patch-compiler';
import type { CapabilityKey, ExecutionKind, OwnerId, ProviderKind as RuntimeProviderKind } from '../request-preference/types';
import type { CapabilityRecipeOmission, ProviderRequest, RequestParams } from './types';

type JsonRecord = Record<string, unknown>;

const EXECUTABLE_KINDS = new Set<ExecutionKind>([
  'request_overlay',
  'server_tool',
  'client_tool_loop',
  'endpoint_route',
  'model_route',
  'external_connector',
  'unavailable',
]);
const CAPABILITY_KEYS = new Set<CapabilityKey>(['web', 'reasoning', 'generation']);
const BUILDER_OWNED_ROOTS = new Set([
  'model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system',
  'stream', 'stream_options', 'tools', 'plugins',
]);
const ALLOWED_TOOL_CHOICE = new Set(['auto', 'none', 'required']);

export interface RuntimeRecipe {
  id: string;
  providerKind: string;
  transport?: { protocol?: string; endpointClass?: string };
  capability: string;
  executionKind: string;
  requestOps: readonly unknown[];
  responseParserKind?: string;
  /** References are authored upstream and resolve only within the same runtime envelope. */
  responseEvidenceRef?: string;
  errorRecoveryRef?: string;
  continuationKind?: string;
  continuationVariant?: string;
  maxToolLoops?: number;
  formula?: FormulaRecipe;
  route?: EndpointRouteRecipe;
}

/** Server-authored route for Moonshot Formula/Fiber; the client never fills in a URI or a tool schema. */
export interface FormulaRecipe {
  uri: string;
  toolsPath: string;
  fibersPath: string;
  argumentsMode: 'verbatim';
  resultPaths: readonly ['context.output', 'context.encrypted_output'] | readonly string[];
}

/** endpoint_route accepts only explicit, already implemented protocol mappings, and never guesses an endpoint from a model id. */
export interface EndpointRouteRecipe {
  sourceProtocol?: string;
  protocol: string;
  endpointClass: string;
  path: string;
  method?: string;
  authMode?: string;
  authHeader?: string;
  headers?: Readonly<Record<string, string>>;
  requestMapper: string;
}

export interface MiniMaxAnthropicMessagesRoute extends EndpointRouteRecipe {
  sourceProtocol: 'openai_chat';
  protocol: 'anthropic_messages';
  endpointClass: 'messages';
  path: '/anthropic/v1/messages';
  method: 'POST';
  authMode: 'x_api_key';
  authHeader: 'x-api-key';
  headers: Readonly<{
    'Content-Type': 'application/json';
    'anthropic-version': '2023-06-01';
  }>;
  requestMapper: 'minimax_anthropic_messages_v1';
}

export interface CapabilityRuntimeEnvelope {
  schemaVersion: number;
  revision: string;
  generatedAt: string;
  recipes: Record<string, unknown>;
  controlDefinitions: Record<string, unknown>;
  sourceIndex: Record<string, unknown>;
  /** Additive maps. A missing map is deliberately tolerated, so an older envelope still works. */
  responseEvidenceDefinitions?: Record<string, unknown>;
  errorRecoveryDefinitions?: Record<string, unknown>;
}

export interface RuntimeCapabilityModel {
  capabilityControls?: Record<string, CapabilityControl>;
  transport?: string;
}

export interface CapabilityExecutionPlan {
  /** Capabilities that must bypass the legacy profile. */
  overridesLegacy: ReadonlySet<CapabilityKey>;
  recipes: readonly RuntimeRecipe[];
  /** external_connector / unavailable must stop on the client and must not fall back to a plain provider fetch. */
  noExecute: boolean;
  intents?: Partial<Record<CapabilityKey, string | undefined>>;
  /** Server-authoritative owner paths used only as the writable schema for Custom mode. */
  customDeclaredOwners?: Readonly<Record<string, OwnerId>>;
}

export type RecipeResolutionReason =
  | 'recipe_not_found'
  | 'provider_mismatch'
  | 'transport_mismatch'
  | 'capability_mismatch'
  | 'unknown_execution_kind'
  | 'invalid_execution_recipe';

export type RecipeResolution =
  | { accepted: true; recipe: RuntimeRecipe }
  | { accepted: false; reason: RecipeResolutionReason };

interface RecipeOperation {
  op: 'set' | 'append';
  pointer: string;
  value: unknown;
  intent?: string;
}

/**
 * Resolves the send intent into the recipes this request needs. There is no separate v2
 * UI store yet, so generation parameters still go through the existing typed builder,
 * but enabling its template is likewise decided only by the runtime recipe.
 */
export function resolveCapabilityExecutionPlan(
  params: RequestParams,
  runtime: unknown,
  model: RuntimeCapabilityModel | null | undefined,
  normalizedReasoningMode: string | undefined,
): CapabilityExecutionPlan {
  if (!isRecord(runtime) || !validateEnvelope({ capabilityRuntime: runtime }).applied) {
    return emptyPlan();
  }

  const envelope = runtime as unknown as CapabilityRuntimeEnvelope;
  if (!isRecord(envelope.recipes) || !isRecord(envelope.sourceIndex) || !isRecord(model?.capabilityControls)) {
    return emptyPlan();
  }

  const overridesLegacy = new Set<CapabilityKey>();
  const selected: RuntimeRecipe[] = [];
  const customDeclaredOwners: Record<string, OwnerId> = {};
  for (const capability of ['web', 'reasoning', 'generation'] as const) {
    // Every capability is recipe-owned at the final request boundary.
    // Missing/unknown/dangling controls mean no automatic configuration, never
    // permission to revive a legacy profile. Actual custom fragments remain an
    // explicit, separately validated source below.
    overridesLegacy.add(capability);
    const control = model.capabilityControls[capability];
    if (!isControl(control)) continue;

    const resolution = resolveControl(params.providerKind as RuntimeProviderKind, capability, control, {
      recipes: Object.keys(envelope.recipes),
      sourceIndex: envelope.sourceIndex,
      controlDefinitions: envelope.controlDefinitions,
    });
    if (!isCapabilityRequested(capability, params, normalizedReasoningMode)) continue;

    if (customFragmentForOwner(params, capability)) {
      for (const definition of resolveCustomControlDefinitions(capability, control, envelope.controlDefinitions, envelope.sourceIndex)) {
        customDeclaredOwners[definition.targetPointer] = capability;
      }
      continue;
    }
    if (resolution.action !== 'apply_recipe' || !control.recipeRef) continue;

    const resolvedRecipe = resolveRuntimeRecipe(
      envelope.recipes,
      control.recipeRef,
      params.providerKind,
      canonicalRecipeTransport(model.transport),
      capability,
    );
    if (!resolvedRecipe.accepted) continue;
    const recipe = resolvedRecipe.recipe;
    const intent = capabilityIntent(capability, params, normalizedReasoningMode);
    if (intent !== undefined && !control.availableIntents?.includes(intent)) continue;
    if (!recipeMatchesIntent(recipe, capability, intent)) continue;
    if (!isRecipeUsableForIntent(recipe, intent)) {
      continue;
    }
    selected.push(recipe);
  }

  return {
    overridesLegacy,
    recipes: selected,
    noExecute: selected.some((recipe) => recipe.executionKind === 'external_connector' || recipe.executionKind === 'unavailable'),
    intents: Object.fromEntries((['web', 'reasoning', 'generation'] as const).map((capability) => [capability, capabilityIntent(capability, params, normalizedReasoningMode)])),
    customDeclaredOwners,
  };
}

/** Merges the automatic patches of the selected recipes into the real builder body and returns an auditable redacted diff preview. */
export function applyCapabilityRecipes(
  body: Readonly<JsonRecord>,
  recipes: readonly RuntimeRecipe[],
  intents: Partial<Record<CapabilityKey, string | undefined>>,
  omissions: readonly CapabilityRecipeOmission[] = [],
): { body: JsonRecord; delta: JsonRecord; preview: JsonRecord } {
  const omitted = exactOmissions(omissions);
  const operations = recipes.flatMap((recipe) => parseExecutableOperations(recipe, intents[recipe.capability as CapabilityKey])
    .filter((operation) => !omitted.get(recipe.id)?.has(operation.pointer)));
  if (operations.length === 0) return { body: { ...body }, delta: {}, preview: {} };

  const toolChoice = operations.filter((operation) => operation.pointer === '/tool_choice');
  const compilable = operations.filter((operation) => operation.pointer !== '/tool_choice');
  if (toolChoice.length > 1 || toolChoice.some((operation) => operation.op !== 'set' || !isToolChoice(operation.value))) {
    return { body: { ...body }, delta: {}, preview: {} };
  }

  const overlayOperations = compilable
    .filter((operation) => operation.op === 'set')
    .map((operation) => ({
      owner: ownerForPointer(recipes, operation.pointer),
      op: 'set',
      pointer: operation.pointer,
      value: operation.value,
    }));
  // Append dedup keys on stableJson(value) and must also compare against the array
  // elements the builder already owns. Dedup means "skip", not "reject the whole patch":
  // owned-patch-compiler is fail-closed on a duplicate identity, so feeding duplicates
  // through makes the entire recipe inject nothing (the force level hits both /tools/-
  // and /tool_choice at once).
  const seenAppendIdentities = new Map<'tools' | 'plugins', Set<string>>();
  const contributions = compilable
    .filter((operation) => operation.op === 'append')
    .flatMap((operation) => {
      const target = operation.pointer === '/plugins/-' ? 'plugins' as const : 'tools' as const;
      let seen = seenAppendIdentities.get(target);
      if (!seen) {
        seen = new Set((Array.isArray(body[target]) ? body[target] as unknown[] : []).map(stableJson));
        seenAppendIdentities.set(target, seen);
      }
      const identity = stableJson(operation.value);
      if (seen.has(identity)) return [];
      seen.add(identity);
      return [{
        owner: 'web' as const,
        target,
        operation: 'append_owned',
        identity,
        value: operation.value,
      }];
    });
  const declaredOwners = Object.fromEntries(overlayOperations.map((operation) => [operation.pointer, operation.owner]));
  const compiled = compileOwnedPatches(
    {
      channel: 'body_fragment',
      metrics: { bytes: JSON.stringify(operations).length, depth: 1, nodes: operations.length },
      declaredOwners,
      operations: overlayOperations,
    },
    [],
    body,
    contributions,
  );
  if (!compiled.accepted) return { body: { ...body }, delta: {}, preview: {} };

  const delta: JsonRecord = { ...compiled.delta };
  if (toolChoice.length === 1) delta.tool_choice = toolChoice[0].value;
  const nextBody = mergeDelta(body, delta);
  return { body: nextBody, delta, preview: redact(delta) };
}

function exactOmissions(values: readonly CapabilityRecipeOmission[]): Map<string, Set<string>> {
  const output = new Map<string, Set<string>>();
  for (const value of values) {
    if (!value || typeof value.recipeRef !== 'string' || value.recipeRef.length === 0 || value.recipeRef.length > 256
      || !Array.isArray(value.locatedPointers) || value.locatedPointers.length === 0 || value.locatedPointers.length > 16) continue;
    const pointers = value.locatedPointers.filter((pointer) => typeof pointer === 'string'
      && pointer.startsWith('/') && pointer.length <= 256);
    if (pointers.length !== value.locatedPointers.length) continue;
    output.set(value.recipeRef, new Set(pointers));
  }
  return output;
}

/**
 * Attaches pure recipe metadata for execution kinds the shell must coordinate. No network
 * request is ever made here; a Formula GET or POST may only be issued by a response
 * adapter holding the restricted transport.
 */
export function attachCapabilityExecution(
  request: ProviderRequest,
  plan: CapabilityExecutionPlan,
): ProviderRequest {
  if (plan.noExecute) {
    throw new Error('Selected capability recipe forbids client-side execution');
  }
  const toolLoopRecipe = plan.recipes.find((recipe) => recipe.executionKind === 'client_tool_loop');
  if (!toolLoopRecipe) return request;
  const formulaRecipe = toolLoopRecipe.formula;
  if (!formulaRecipe) {
    return { ...request, moonshotMaxToolLoops: toolLoopRecipe.maxToolLoops };
  }
  return {
    ...request,
    responseAdapter: 'moonshot_formula_fiber_loop',
    moonshotMaxToolLoops: toolLoopRecipe.maxToolLoops,
    moonshotFormula: formulaRecipe,
  };
}

function emptyPlan(): CapabilityExecutionPlan {
  return { overridesLegacy: new Set<CapabilityKey>(['web', 'reasoning', 'generation']), recipes: [], noExecute: false, intents: {}, customDeclaredOwners: {} };
}

function isCapabilityRequested(
  capability: CapabilityKey,
  params: RequestParams,
  normalizedReasoningMode: string | undefined,
): boolean {
  if (customFragmentForOwner(params, capability)) return true;
  if (capability === 'web') return params.options?.capabilityPreferences
    ? params.options.capabilityPreferences.web !== 'off'
    : params.options?.supportsWebSearch === true;
  if (capability === 'reasoning') return params.options?.capabilityPreferences
    ? params.options.capabilityPreferences.reasoningIntent !== undefined
    : normalizedReasoningMode != null && normalizedReasoningMode !== 'automatic';
  return Object.values(params.options?.generationParameters ?? {}).some((override) => override?.state === 'value')
    || typeof params.options?.customFragment?.raw === 'string';
}

function customFragmentForOwner(params: RequestParams, owner: CapabilityKey): { raw: string } | undefined {
  return params.options?.customFragments?.[owner]
    ?? (owner === 'generation' ? params.options?.customFragment : undefined);
}

function capabilityIntent(capability: CapabilityKey, params: RequestParams, normalizedReasoningMode: string | undefined): string | undefined {
  if (capability === 'web') return params.options?.capabilityPreferences?.web === 'force' ? 'force' : undefined;
  if (capability === 'reasoning') return params.options?.capabilityPreferences?.reasoningIntent
    ?? reasoningIntent(normalizedReasoningMode) ?? undefined;
  return undefined;
}

function parseRecipe(value: unknown): RuntimeRecipe | null {
  if (!isRecord(value)
    || typeof value.id !== 'string'
    || typeof value.providerKind !== 'string'
    || typeof value.capability !== 'string'
    || typeof value.executionKind !== 'string'
    || !Array.isArray(value.requestOps)) return null;
  return isRecipeExecutionShapeValid(value) ? value as unknown as RuntimeRecipe : null;
}

/** The same typed boundary the shared fixture negativeCases use; errors never fall back to guessing from a model id. */
export function resolveRuntimeRecipe(
  recipes: Readonly<Record<string, unknown>>,
  recipeRef: string,
  providerKind: string,
  transport: string | undefined,
  capability: CapabilityKey,
): RecipeResolution {
  const recipe = parseRecipe(recipes[recipeRef]);
  if (!recipe) return { accepted: false, reason: 'recipe_not_found' };
  if (recipe.providerKind !== providerKind) return { accepted: false, reason: 'provider_mismatch' };
  if (recipe.transport?.protocol !== canonicalRecipeTransport(transport)) return { accepted: false, reason: 'transport_mismatch' };
  if (recipe.capability !== capability || !CAPABILITY_KEYS.has(capability)) {
    return { accepted: false, reason: 'capability_mismatch' };
  }
  if (!EXECUTABLE_KINDS.has(recipe.executionKind as ExecutionKind)) {
    return { accepted: false, reason: 'unknown_execution_kind' };
  }
  return { accepted: true, recipe };
}

/** Server model selector names are an internal catalog vocabulary; recipes carry the shared
 * wire protocol vocabulary. Keep the alias table explicit and tiny—never infer from model ID. */
export function canonicalRecipeTransport(transport: string | undefined): string | undefined {
  return transport === 'gemini_generate' ? 'gemini_generate_content' : transport;
}

function isRecipeExecutionShapeValid(value: JsonRecord): boolean {
  const kind = value.executionKind;
  const requestOps = value.requestOps;
  if (!Array.isArray(requestOps)) return false;
  if (kind === 'client_tool_loop') {
    return Number.isInteger(value.maxToolLoops)
      && (value.maxToolLoops as number) >= 1
      && (value.maxToolLoops as number) <= 5
      && value.continuationKind === 'tool_loop'
      && ((value.continuationVariant === 'fiber' && requestOps.length === 0 && isFormulaRecipe(value.formula))
        || (value.continuationVariant === 'default' && isMoonshotBuiltinOperations(requestOps)));
  }
  if (kind === 'endpoint_route') return isEndpointRouteRecipe(value.route);
  if (kind === 'model_route' || kind === 'external_connector' || kind === 'unavailable') {
    return requestOps.length === 0;
  }
  return kind === 'request_overlay' || kind === 'server_tool';
}

function isMoonshotBuiltinOperations(requestOps: readonly unknown[]): boolean {
  return requestOps.length === 1
    && isRecord(requestOps[0])
    && requestOps[0].op === 'append'
    && requestOps[0].pointer === '/tools/-';
}

function isFormulaRecipe(value: unknown): value is FormulaRecipe {
  if (!isRecord(value)) return false;
  return typeof value.uri === 'string' && value.uri.length > 0
    && isSafeFormulaPath(value.toolsPath)
    && isSafeFormulaPath(value.fibersPath)
    && value.argumentsMode === 'verbatim'
    && Array.isArray(value.resultPaths)
    && value.resultPaths.length === 2
    && value.resultPaths[0] === 'context.output'
    && value.resultPaths[1] === 'context.encrypted_output';
}

function isSafeFormulaPath(value: unknown): boolean {
  return typeof value === 'string'
    && value.startsWith('/v1/formulas/')
    && !value.includes('?')
    && !value.includes('#')
    && !value.includes('..')
    && !/^[a-z][a-z0-9+.-]*:/i.test(value);
}

function isEndpointRouteRecipe(value: unknown): value is EndpointRouteRecipe {
  if (!isRecord(value)) return false;
  const gemini = value.protocol === 'gemini_interactions'
    && value.endpointClass === 'interactions'
    && value.path === '/v1/interactions'
    && typeof value.requestMapper === 'string'
    && value.requestMapper.length > 0;
  return gemini || isMiniMaxAnthropicMessagesRoute(value);
}

export function isMiniMaxAnthropicMessagesRoute(value: unknown): value is MiniMaxAnthropicMessagesRoute {
  if (!isRecord(value)
    || !Object.keys(value).every((key) => [
      'sourceProtocol', 'protocol', 'endpointClass', 'path', 'method', 'authMode',
      'authHeader', 'headers', 'requestMapper',
    ].includes(key))
    || value.sourceProtocol !== 'openai_chat'
    || value.protocol !== 'anthropic_messages'
    || value.endpointClass !== 'messages'
    || value.path !== '/anthropic/v1/messages'
    || value.method !== 'POST'
    || value.authMode !== 'x_api_key'
    || value.authHeader !== 'x-api-key'
    || value.requestMapper !== 'minimax_anthropic_messages_v1'
    || !isRecord(value.headers)
    || !Object.keys(value.headers).every((key) => key === 'Content-Type' || key === 'anthropic-version')) return false;
  return value.headers['Content-Type'] === 'application/json'
    && value.headers['anthropic-version'] === '2023-06-01';
}

function isRecipeUsableForIntent(recipe: RuntimeRecipe, mode: string | undefined): boolean {
  if (recipe.executionKind === 'external_connector' || recipe.executionKind === 'unavailable') return true;
  if (recipe.executionKind === 'model_route' || recipe.executionKind === 'client_tool_loop' || recipe.executionKind === 'endpoint_route') {
    return recipe.capability !== 'reasoning' || mode != null;
  }
  return recipe.capability === 'generation'
    ? legacyGenerationTemplateForRecipe(recipe) != null
    : parseExecutableOperations(recipe, mode).length > 0;
}

function recipeMatchesIntent(recipe: RuntimeRecipe, capability: CapabilityKey, mode: string | undefined): boolean {
  if (capability === 'generation' || capability === 'web') return true;
  return mode != null && parseExecutableOperations(recipe, mode).length > 0;
}

function parseExecutableOperations(recipe: RuntimeRecipe, mode: string | undefined): RecipeOperation[] {
  // Typed paths already provide canonical intent (including an explicit off).
  // Legacy reasoning modes still enter as fast/balanced/deep/max and are normalized here.
  const intent = recipe.capability === 'reasoning' && mode !== 'off' && mode !== 'low'
    ? reasoningIntent(mode) : mode;
  if (recipe.capability === 'reasoning' && !intent) return [];
  const parsed: RecipeOperation[] = [];
  for (const raw of recipe.requestOps) {
    // Generation recipes authorize the server-selected legacy typed template. The template has
    // no body patch of its own; the normal generation builder emits the actual typed fields.
    if (isLegacyGenerationTemplateOperation(recipe, raw)) continue;
    if (!isRecord(raw) || (raw.op !== 'set' && raw.op !== 'append') || typeof raw.pointer !== 'string' || !('value' in raw)) return [];
    if (typeof raw.intent === 'string' && raw.intent !== intent) continue;
    if (!isAllowedPointer(raw.op, raw.pointer)) return [];
    parsed.push({ op: raw.op, pointer: raw.pointer, value: raw.value, ...(typeof raw.intent === 'string' ? { intent: raw.intent } : {}) });
  }
  return mergeByIntentPriority(parsed);
}

/**
 * Request op merge rule: **last-specific-wins**.
 *
 * The loop above has already dropped foreign ops (those whose intent exists and differs
 * from the current intent), so every remaining op carrying an intent is a specialized op.
 * As soon as a pointer has any specialized op, every base op without an intent on that
 * pointer is discarded, **regardless of writing order** (a base op written after a
 * specialized one is discarded too, which is exactly where this differs from
 * last-write-wins). The surviving ops keep their original relative order in requestOps.
 *
 * The contract pins this rule down because it had never been defined: the four
 * requestOps of the production `openai.responses.web.v1` compiled to a different and
 * equally wrong wire shape on each client (here, two conflicting /tool_choice ops made
 * the whole injection be abandoned, so the force level did nothing).
 */
function mergeByIntentPriority(operations: readonly RecipeOperation[]): RecipeOperation[] {
  const specificPointers = new Set(
    operations.filter((operation) => operation.intent !== undefined).map((operation) => operation.pointer),
  );
  if (specificPointers.size === 0) return [...operations];
  return operations.filter((operation) => operation.intent !== undefined || !specificPointers.has(operation.pointer));
}

/** Exact v1 bridge, intentionally not a model-id or provider-name inference. */
export function legacyGenerationTemplateForRecipe(recipe: RuntimeRecipe): string | null {
  if (recipe.capability !== 'generation' || recipe.requestOps.length !== 1) return null;
  const raw = recipe.requestOps[0];
  if (!isRecord(raw) || raw.op !== 'legacy_generation_template' || typeof raw.template !== 'string' || raw.template.length === 0) return null;
  return Object.keys(raw).every((key) => key === 'op' || key === 'template') ? raw.template : null;
}

function isLegacyGenerationTemplateOperation(recipe: RuntimeRecipe, raw: unknown): boolean {
  return recipe.capability === 'generation'
    && isRecord(raw)
    && raw.op === 'legacy_generation_template'
    && legacyGenerationTemplateForRecipe(recipe) != null;
}

function isAllowedPointer(op: 'set' | 'append', pointer: string): boolean {
  if (op === 'append') return pointer === '/tools/-' || pointer === '/plugins/-';
  if (pointer === '/tool_choice') return true;
  if (!/^\/(?:[A-Za-z_][A-Za-z0-9_]*)(?:\/[A-Za-z_][A-Za-z0-9_]*)*$/.test(pointer)) return false;
  return !BUILDER_OWNED_ROOTS.has(pointer.split('/')[1]);
}

function ownerForPointer(recipes: readonly RuntimeRecipe[], pointer: string): OwnerId {
  const recipe = recipes.find((entry) => entry.requestOps.some((raw) => isRecord(raw) && raw.pointer === pointer));
  return (recipe?.capability === 'reasoning' ? 'reasoning' : recipe?.capability === 'generation' ? 'generation' : 'web');
}

function reasoningIntent(mode: string | undefined): string | null {
  switch (mode) {
    case 'fast': return 'low';
    case 'balanced': return 'balanced';
    case 'deep': return 'deep';
    case 'max': return 'max';
    default: return null;
  }
}

function mergeDelta(base: Readonly<JsonRecord>, delta: JsonRecord): JsonRecord {
  const output: JsonRecord = { ...base };
  for (const [key, value] of Object.entries(delta)) {
    if (isRecord(value) && isRecord(output[key])) output[key] = mergeDelta(output[key] as JsonRecord, value);
    else output[key] = value;
  }
  return output;
}

function redact(value: JsonRecord): JsonRecord {
  const hidden = new Set(['api_key', 'authorization', 'prompt', 'messages', 'attachments', 'full_endpoint', 'response', 'raw_custom_fragment']);
  const visit = (item: unknown): unknown => {
    if (Array.isArray(item)) return item.map(visit);
    if (!isRecord(item)) return item;
    return Object.fromEntries(Object.entries(item).map(([key, nested]) => [key, hidden.has(key.toLowerCase()) ? '[REDACTED]' : visit(nested)]));
  };
  return visit(value) as JsonRecord;
}

function isControl(value: unknown): value is CapabilityControl {
  return isRecord(value) && typeof value.state === 'string';
}

function isRecord(value: unknown): value is JsonRecord {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function isToolChoice(value: unknown): value is string {
  return typeof value === 'string' && ALLOWED_TOOL_CHOICE.has(value);
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (isRecord(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
