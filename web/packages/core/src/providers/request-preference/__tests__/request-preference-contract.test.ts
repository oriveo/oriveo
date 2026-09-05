/**
 * Consumes the shared contract request_preference_contract.v2.json (all 8 fixture groups)
 * plus the 4 client-relevant fixture groups of request_shape_contract.v2.json, asserting
 * case by case that `resolver.ts` and its sibling files match the contract expectations.
 *
 * Fixtures are located the same way as in
 * request-builders/__tests__/generation-parameter-contract.test.ts: findSharedContract()
 * walks up from cwd looking for the shared model-contracts directory rather than
 * hardcoding an absolute path.
 */

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { type CapabilityControl, customControlRiskTiers, resolveControls, resolveCustomControlDefinitions, validateEnvelope, validateIntents } from '../capability-runtime';
import { validateContinuation } from '../continuation';
import {
  resolveLayers, resolveSelection, validateAssignments,
  type ConflictRejectReason, type SelectionRejectReason,
} from '../preference-resolution';
import { classifyResult } from '../result-facts';
import { resolveRetry } from '../retry';
import { validateOverlay, type OverlayRejectReason } from '../safe-overlay';
import { composeContributions } from '../tool-contributions';
import type { CapabilityKey, ConnectionAccess, ControlAvailability, OwnerId, ProviderKind, ScopeId, ValueMode } from '../types';

interface PreferenceContract {
  fixtures: {
    resolutionCases: Array<{
      caseId: string;
      owner: OwnerId;
      layers: Array<{ scope: ScopeId; override: { state: 'inherit' | 'value' | 'omit'; value?: unknown } }>;
      expect: { state: 'value' | 'omit'; value?: unknown; source: string; reason?: string };
    }>;
    selectionCases: Array<{
      caseId: string;
      intent: { availability: ControlAvailability; selection: ValueMode; access: ConnectionAccess };
      expect: { allowed: boolean; reason: SelectionRejectReason | null };
    }>;
    conflictCases: Array<{
      caseId: string;
      assignments: Array<{ owner: OwnerId; pointer: string }>;
      declaredConflicts: Array<[string, string]>;
      expect: { accepted: boolean; reason: ConflictRejectReason | null };
    }>;
    safeOverlayCases: Array<{
      caseId: string;
      intent: {
        channel: string;
        metrics: { bytes: number; depth: number; nodes: number };
        declaredOwners: Record<string, OwnerId>;
        operations: Array<{ owner: OwnerId; op: 'set' | 'omit' | 'upsert_owned_element'; pointer: string; value?: unknown }>;
      };
      expect: { accepted: boolean; reason: OverlayRejectReason | null };
    }>;
    toolContributionCases: Array<{
      caseId: string;
      base: string[];
      contributions: Array<{ owner: OwnerId; target: string; operation: string; identity: string; value: unknown }>;
      expect: { accepted: boolean; identities?: string[]; reason: string | null };
    }>;
    resultCases: Array<{
      caseId: string;
      intent: { wireApplied: boolean; providerAccepted: boolean; evidenceKinds: string[]; recovered?: boolean };
      expect: { state: string; requested: boolean; observed: boolean };
    }>;
    continuationCases: Array<{
      caseId: string;
      intent: { kind: string; variant?: string; step: number; state: Record<string, unknown> };
      expect: { accepted: boolean; reason: string | null };
    }>;
    retryCases: Array<{
      caseId: string;
      intent: {
        source: string;
        status: number | null;
        errorClass: string;
        owner: OwnerId | null;
        locatedPointers: string[];
        preToken: boolean;
        streamStarted: boolean;
        sideEffects: boolean;
        automaticRetryCount: number;
      };
      expect: { retry: boolean; action: string };
    }>;
  };
}

interface ControlExpectResult {
  valid: boolean;
  state: string;
  action: string;
  reason: string | null;
}

interface ShapeContract {
  fixtures: {
    runtimeEnvelopeCases: Array<{
      caseId: string;
      payload: Record<string, unknown>;
      expect: { applied: boolean; action: string; reason: string | null; chatContinues: boolean };
    }>;
    controlResolutionCases: Array<{
      caseId: string;
      providerKind: ProviderKind;
      recipes: string[];
      capabilityControls: Record<string, CapabilityControl>;
      expect: { unknownCapabilities: string[]; results: Record<string, ControlExpectResult> };
    }>;
    reasoningIntentCases: Array<{
      caseId: string;
      capability: CapabilityKey;
      intents: string[];
      expect: { valid: boolean; reason: string | null; intents: string[] };
    }>;
    providerUniverseCases: Array<{
      caseId: string;
      providerKind: ProviderKind;
      recipes: string[];
      capabilityControls: Record<string, CapabilityControl>;
      expect: { unknownCapabilities: string[]; results: Record<string, ControlExpectResult> };
    }>;
    sharedSourceIndex: Record<string, unknown>;
    sharedControlDefinitions: Record<string, unknown>;
  };
}

describe('request_preference_contract.v2 consumption (resolver.ts)', () => {
  const contract = loadPreferenceContract();

  it('resolutionCases: 7 scope levels, inherit passes through, omit terminates, and a numeric 0 is an explicit value', () => {
    const cases = contract.fixtures.resolutionCases;
    expect(cases.length).toBe(5);
    for (const item of cases) {
      expect(resolveLayers(item.layers), item.caseId).toEqual(item.expect);
    }
  });

  it('selectionCases: preset and custom_only are never confused', () => {
    const cases = contract.fixtures.selectionCases;
    expect(cases.length).toBe(6);
    for (const item of cases) {
      expect(resolveSelection(item.intent), item.caseId).toEqual(item.expect);
    }
  });

  it('conflictCases: duplicate pointers within an owner, pointer collisions across owners, and semantic conflicts declared by a recipe are all rejected', () => {
    const cases = contract.fixtures.conflictCases;
    expect(cases.length).toBe(4);
    for (const item of cases) {
      expect(validateAssignments(item.assignments, item.declaredConflicts), item.caseId).toEqual(item.expect);
    }
  });

  it('safeOverlayCases: channel, size, depth, pointer validity, ownership and dangerous keys are all hardened', () => {
    const cases = contract.fixtures.safeOverlayCases;
    expect(cases.length).toBe(12);
    for (const item of cases) {
      expect(validateOverlay(item.intent), item.caseId).toEqual(item.expect);
    }
  });

  it('toolContributionCases: tools and plugins allow only append_owned, and entries the builder already had are preserved', () => {
    const cases = contract.fixtures.toolContributionCases;
    expect(cases.length).toBe(4);
    for (const item of cases) {
      expect(composeContributions(item.base, item.contributions), item.caseId).toEqual(item.expect);
    }
  });

  it('resultCases: requested and observed are separate facts, and HTTP 200 does not mean it took effect', () => {
    const cases = contract.fixtures.resultCases;
    expect(cases.length).toBe(7);
    for (const item of cases) {
      expect(classifyResult(item.intent), item.caseId).toEqual(item.expect);
    }
  });

  it('continuationCases: each kind has a step limit and required fields, and an unknown kind or variant is rejected fail-safe', () => {
    const cases = contract.fixtures.continuationCases;
    expect(cases.length).toBe(15);
    for (const item of cases) {
      expect(validateContinuation(item.intent), item.caseId).toEqual(item.expect);
    }
    // continuation.ts covers all 5 known kinds; fiber is a variant of tool_loop, not a 6th kind.
    const acceptedKinds = new Set(
      cases.filter((item) => item.expect.accepted).map((item) => item.intent.kind),
    );
    expect(acceptedKinds).toEqual(new Set(['none', 'previous_id', 'replay_blocks', 'replay_reasoning', 'tool_loop']));
  });

  it('retryCases: a located pre-token 400 offers only an explicit resend and never strips a parameter automatically', () => {
    const cases = contract.fixtures.retryCases;
    expect(cases.length).toBe(9);
    for (const item of cases) {
      expect(resolveRetry(item.intent), item.caseId).toEqual(item.expect);
    }
  });

  it('consumes all 57 fixtures of request_preference_contract.v2', () => {
    const { resolutionCases, selectionCases, conflictCases, safeOverlayCases, toolContributionCases, resultCases, continuationCases, retryCases } = contract.fixtures;
    const total = resolutionCases.length + selectionCases.length + conflictCases.length + safeOverlayCases.length
      + toolContributionCases.length + resultCases.length + continuationCases.length + retryCases.length;
    expect(total).toBe(62);
  });
});

describe('request_shape_contract.v2 consumption, client-relevant groups (capability-runtime.ts)', () => {
  const contract = loadShapeContract();
  const sharedSourceIndex = contract.fixtures.sharedSourceIndex;
  const sharedControlDefinitions = contract.fixtures.sharedControlDefinitions;

  it('runtimeEnvelopeCases: an unknown schemaVersion or a missing field ignores the envelope wholesale while the chat continues', () => {
    const cases = contract.fixtures.runtimeEnvelopeCases;
    expect(cases.length).toBe(5);
    for (const item of cases) {
      expect(validateEnvelope(item.payload), item.caseId).toEqual(item.expect);
    }
  });

  it('controlResolutionCases: capabilityControls degrade per key and are never half applied', () => {
    const cases = contract.fixtures.controlResolutionCases;
    expect(cases.length).toBe(19);
    for (const item of cases) {
      const actual = resolveControls(item.providerKind, item.capabilityControls, {
        recipes: item.recipes,
        sourceIndex: sharedSourceIndex,
        controlDefinitions: sharedControlDefinitions,
      });
      expect(actual, item.caseId).toEqual(item.expect);
    }
  });

  it('reasoningIntentCases: reasoning keeps a sparse ladder and web search only accepts an exact force', () => {
    const cases = contract.fixtures.reasoningIntentCases;
    expect(cases.length).toBe(10);
    for (const item of cases) {
      expect(validateIntents(item.capability, item.intents), item.caseId).toEqual(item.expect);
    }
  });

  it('providerUniverseCases: all 16 providers are covered and every baseline case is contract-valid', () => {
    const cases = contract.fixtures.providerUniverseCases;
    expect(cases.length).toBe(16);
    const covered = new Set<string>();
    for (const item of cases) {
      const actual = resolveControls(item.providerKind, item.capabilityControls, {
        recipes: item.recipes,
        sourceIndex: sharedSourceIndex,
        controlDefinitions: sharedControlDefinitions,
      });
      expect(actual, item.caseId).toEqual(item.expect);
      for (const result of Object.values(item.expect.results)) {
        expect(result.valid, `${item.caseId}: baseline case must be contract-valid`).toBe(true);
      }
      covered.add(item.providerKind);
    }
    expect(covered.size).toBe(16);
  });

  it('riskTier: cost and privacy hints follow the closed enum the server sends, and an unknown value fails safe by showing no hint without dropping the control', () => {
    // Definitions come from the controlDefinitions the server actually sends (the contract
    // fixtures share their source with capability_custom_controls.v2.json), rather than a
    // riskTier invented in the test.
    const definitionsFor = (owner: 'web' | 'reasoning' | 'generation', refs: string[], definitions = sharedControlDefinitions) =>
      resolveCustomControlDefinitions(
        owner,
        { state: 'custom_only', reasonCode: 'user_custom', sourceRefs: ['qwen.web_search'], customControlRefs: refs },
        definitions,
        sharedSourceIndex,
      );

    const privacy = definitionsFor('web', ['qwen.web.enable_search']);
    expect(privacy.map((definition) => definition.riskTier)).toEqual(['privacy_impacting']);
    expect(customControlRiskTiers(privacy)).toEqual(['privacy_impacting']);

    const cost = definitionsFor('reasoning', ['openai.reasoning.effort']);
    expect(customControlRiskTiers(cost)).toEqual(['cost_impacting']);
    expect(customControlRiskTiers(definitionsFor('generation', ['openai.generation.max_output_tokens'])))
      .toEqual(['cost_impacting']);

    // An unknown tier only silences this one annotation; the control itself has to stay usable,
    // otherwise a newly added enum value would switch off the capability along with it.
    const mutated = {
      ...sharedControlDefinitions,
      'openai.reasoning.effort': {
        ...(sharedControlDefinitions['openai.reasoning.effort'] as Record<string, unknown>),
        riskTier: 'quantum_impacting',
      },
    };
    const unknown = definitionsFor('reasoning', ['openai.reasoning.effort'], mutated);
    expect(unknown).toHaveLength(1);
    expect(unknown[0]?.riskTier).toBeUndefined();
    expect(customControlRiskTiers(unknown)).toEqual([]);
  });

  it('consumes all 50 client-relevant fixtures of request_shape_contract.v2', () => {
    const { runtimeEnvelopeCases, controlResolutionCases, reasoningIntentCases, providerUniverseCases } = contract.fixtures;
    const total = runtimeEnvelopeCases.length + controlResolutionCases.length + reasoningIntentCases.length
      + providerUniverseCases.length;
    expect(total).toBe(50);
  });
});

function loadPreferenceContract(): PreferenceContract {
  return JSON.parse(
    readFileSync(findSharedContract('request_preference_contract.v2.json'), 'utf8'),
  ) as PreferenceContract;
}

function loadShapeContract(): ShapeContract {
  return JSON.parse(
    readFileSync(findSharedContract('request_shape_contract.v2.json'), 'utf8'),
  ) as ShapeContract;
}

function findSharedContract(fileName: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
