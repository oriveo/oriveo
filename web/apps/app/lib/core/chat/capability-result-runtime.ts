/**
 * Response facts.
 *
 * This module deliberately consumes only the server's selected recipe and its
 * same-envelope evidence definition. A HTTP 200, a parser name, or a generic
 * citation is never enough on its own to claim an observed capability.
 */
import type { StreamEvent } from '../providers/types';
import { classifyResult } from '@oriveo/core/providers/request-preference/result-facts';

export type CapabilityResultOwner = 'web' | 'reasoning' | 'generation';
export type CapabilityResultSource = 'provider_recipe' | 'custom';
export type CapabilityResultState = 'not_requested' | 'requested' | 'observed' | 'unconfirmed' | 'rejected' | 'recovered';

export interface CapabilityResultDefinition {
  capability: CapabilityResultOwner;
  protocol: string;
  responseParserKind: string;
  signals: Array<{
    kind: 'provider_tool_result' | 'citation' | 'grounding' | 'thinking_block' | 'reasoning_usage';
    producerEvent: 'citations' | 'tool_result' | 'reasoning' | 'usage';
    pointer: string;
    nonEmpty: true;
  }>;
}

/** Header-safe, local-only context emitted by the production proxy route. */
export interface CapabilityResultContext {
  version: 1;
  revision: string;
  entries: Array<{
    owner: CapabilityResultOwner;
    source: CapabilityResultSource;
    wireApplied: boolean;
    protocol: string;
    responseParserKind: string;
    definition: CapabilityResultDefinition | null;
  }>;
}

export interface CapabilityResultRecord {
  owner: CapabilityResultOwner;
  state: CapabilityResultState;
  source: CapabilityResultSource;
  revision: string;
}

/**
 * Local execution facts carried by the production proxy route. It deliberately excludes
 * provider/model/endpoint/request values and never treats a successful HTTP status as
 * evidence. A missing or malformed definition is serialized as null so the consumer stays
 * unconfirmed.
 *
 * The `generation` owner does not enter the response-fact and result-evidence state machine.
 * All 17 generation recipes bind an evidence definition whose `signals` is an empty array,
 * because official APIs never echo back that a temperature took effect, so a recipe-sourced
 * generation can structurally never move past unconfirmed. A state bit that can be neither
 * upgraded nor downgraded carries no information and reads as "never confirmed". The request
 * compilation layer is unaffected: generation parameters still go on the wire, and the owner
 * facts of a custom fragment, generation included, are still kept.
 */
export function buildCapabilityResultContext(
  execution: {
    recipeRefs: string[];
    wireAppliedOwners?: Partial<Record<CapabilityResultOwner, boolean>>;
    customOwners?: CapabilityResultOwner[];
    resultEnvelope?: unknown;
  } | undefined,
  envelopeValue: unknown,
): CapabilityResultContext | null {
  const envelope = envelopeValue as { revision?: unknown; recipes?: unknown; responseEvidenceDefinitions?: unknown } | undefined;
  if (!execution || !envelope || typeof envelope.revision !== 'string' || !isRecord(envelope.recipes)) return null;
  const entries: CapabilityResultContext['entries'] = [];
  for (const recipeRef of execution.recipeRefs) {
    const recipe = envelope.recipes[recipeRef];
    if (!isRecord(recipe) || !isOwner(recipe.capability) || !isRecord(recipe.transport)
      || typeof recipe.transport.protocol !== 'string' || typeof recipe.responseParserKind !== 'string') continue;
    if (recipe.capability === 'generation') continue;
    const definition = isRecord(envelope.responseEvidenceDefinitions)
      ? parseDefinition(envelope.responseEvidenceDefinitions[recipe.responseEvidenceRef as string])
      : null;
    // Exact triple binding is checked again on both sides of the proxy header.
    const bound = definition && definition.capability === recipe.capability
      && definition.protocol === recipe.transport.protocol
      && definition.responseParserKind === recipe.responseParserKind
      ? definition : null;
    entries.push({
      owner: recipe.capability,
      source: 'provider_recipe',
      wireApplied: execution.wireAppliedOwners?.[recipe.capability] === true,
      protocol: recipe.transport.protocol,
      responseParserKind: recipe.responseParserKind,
      definition: bound,
    });
  }
  for (const owner of execution.customOwners ?? []) {
    entries.push({
      owner,
      source: 'custom',
      wireApplied: execution.wireAppliedOwners?.[owner] === true,
      // These placeholders can never bind a definition, which deliberately
      // prevents a custom request from inheriting recipe evidence.
      protocol: 'custom',
      responseParserKind: 'custom',
      definition: null,
    });
  }
  return entries.length ? { version: 1, revision: envelope.revision, entries } : null;
}

export function decodeCapabilityResultContext(value: string | null): CapabilityResultContext | null {
  if (!value || value.length > 16_384) return null;
  try {
    const decoded = JSON.parse(decodeBase64Url(value)) as unknown;
    if (!isRecord(decoded) || decoded.version !== 1 || typeof decoded.revision !== 'string' || !Array.isArray(decoded.entries)) return null;
    const entries = decoded.entries.map(parseEntry);
    return entries.every((entry): entry is NonNullable<typeof entry> => entry != null)
      ? { version: 1, revision: decoded.revision, entries }
      : null;
  } catch { return null; }
}

export function encodeCapabilityResultContext(context: CapabilityResultContext): string {
  return encodeBase64Url(JSON.stringify(context));
}

/** Records normalized events produced by the selected production parser. */
export function collectCapabilityResults(
  context: CapabilityResultContext | null | undefined,
  events: readonly StreamEvent[],
): CapabilityResultRecord[] {
  if (!context) return [];
  return context.entries.map((entry) => {
    // A custom fragment can prove only that its final body was sent. Even if
    // the surrounding provider response contains a reviewed parser signal, it
    // is not evidence that the user's arbitrary custom field caused that
    // behavior. Keep custom at requested -> unconfirmed.
    const evidenceKinds = entry.source === 'provider_recipe' && entry.definition && sameBinding(entry, entry.definition)
      ? matchedEvidenceKinds(entry.definition, events)
      : [];
    const facts = classifyResult({
      wireApplied: entry.wireApplied,
      // `rejected` needs an exact, reviewed locator rule. This revision has
      // none, so transport success/failure and a parser error never classify a
      // recipe as rejected or recovered.
      providerAccepted: true,
      evidenceKinds,
      recovered: false,
    });
    return { owner: entry.owner, state: facts.state, source: entry.source, revision: context.revision };
  });
}

/** Final proxy dispatch facts, shown only while its corresponding request is in flight. */
export function requestedCapabilityResults(context: CapabilityResultContext | null | undefined): CapabilityResultRecord[] {
  if (!context) return [];
  return context.entries
    .filter((entry) => entry.wireApplied)
    .map((entry) => ({ owner: entry.owner, state: 'requested', source: entry.source, revision: context.revision }));
}

function parseEntry(value: unknown): CapabilityResultContext['entries'][number] | null {
  if (!isRecord(value) || !isOwner(value.owner) || !isSource(value.source)
    || typeof value.wireApplied !== 'boolean' || typeof value.protocol !== 'string'
    || typeof value.responseParserKind !== 'string') return null;
  const definition = value.definition == null ? null : parseDefinition(value.definition);
  if (value.definition != null && !definition) return null;
  return { owner: value.owner, source: value.source, wireApplied: value.wireApplied, protocol: value.protocol, responseParserKind: value.responseParserKind, definition };
}

function parseDefinition(value: unknown): CapabilityResultDefinition | null {
  if (!isRecord(value) || !isOwner(value.capability) || typeof value.protocol !== 'string'
    || typeof value.responseParserKind !== 'string' || !Array.isArray(value.signals)) return null;
  const signals = value.signals.map((signal) => {
    if (!isRecord(signal) || !isEvidenceKind(signal.kind) || !isProducerEvent(signal.producerEvent)
      || typeof signal.pointer !== 'string' || signal.nonEmpty !== true) return null;
    return { kind: signal.kind, producerEvent: signal.producerEvent, pointer: signal.pointer, nonEmpty: true } as CapabilityResultDefinition['signals'][number];
  });
  return signals.every((signal): signal is NonNullable<typeof signal> => signal != null)
    ? { capability: value.capability, protocol: value.protocol, responseParserKind: value.responseParserKind, signals }
    : null;
}

function sameBinding(entry: CapabilityResultContext['entries'][number], definition: CapabilityResultDefinition): boolean {
  return entry.owner === definition.capability
    && entry.protocol === definition.protocol
    && entry.responseParserKind === definition.responseParserKind;
}

function matchedEvidenceKinds(definition: CapabilityResultDefinition, events: readonly StreamEvent[]): string[] {
  const found = new Set<string>();
  for (const signal of definition.signals) {
    if (events.some((event) => hasSignal(event, signal.producerEvent))) found.add(signal.kind);
  }
  return [...found];
}

function hasSignal(event: StreamEvent, producerEvent: CapabilityResultDefinition['signals'][number]['producerEvent']): boolean {
  if (producerEvent === 'citations') return event.type === 'citations' && event.citations.length > 0;
  if (producerEvent === 'tool_result') return event.type === 'tool_result' && event.summary.trim().length > 0;
  if (producerEvent === 'reasoning') return event.type === 'reasoning' && event.content.trim().length > 0;
  return event.type === 'usage' && Object.keys(event.usage).length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
function isOwner(value: unknown): value is CapabilityResultOwner { return value === 'web' || value === 'reasoning' || value === 'generation'; }
function isSource(value: unknown): value is CapabilityResultSource { return value === 'provider_recipe' || value === 'custom'; }
function isEvidenceKind(value: unknown): value is CapabilityResultDefinition['signals'][number]['kind'] { return value === 'provider_tool_result' || value === 'citation' || value === 'grounding' || value === 'thinking_block' || value === 'reasoning_usage'; }
function isProducerEvent(value: unknown): value is CapabilityResultDefinition['signals'][number]['producerEvent'] { return value === 'citations' || value === 'tool_result' || value === 'reasoning' || value === 'usage'; }
function encodeBase64Url(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}
function decodeBase64Url(value: string): string {
  const standard = value.replaceAll('-', '+').replaceAll('_', '/');
  const binary = atob(standard + '='.repeat((4 - standard.length % 4) % 4));
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}
