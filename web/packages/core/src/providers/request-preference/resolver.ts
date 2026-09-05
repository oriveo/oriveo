/**
 * Pure-logic consumer of request_preference_contract.v2 / request_shape_contract.v2.
 *
 * Relationship to the existing five-level scope resolver:
 * `apps/app/lib/core/chat/generation-parameter-settings.ts` implements the v1 contract (five
 * scope levels) that the live chat path uses. This module is a separate pure-logic
 * implementation of the v2 contract (seven scope levels, owner-scoped web/reasoning/generation,
 * typed continuation/retry/result facts). It sits in packages/core so the browser and desktop
 * builds can share it later, but for now it:
 * - touches no UI, reads no localStorage or window, and has no side effects;
 * - is not wired into any request path (chat requests still go through the v1 resolver only);
 * - proves its semantics against the shared contract fixtures, see
 *   __tests__/request-preference-contract.test.ts.
 * The two resolvers coexist without affecting each other, and neither is a patch for the other.
 *
 * This file is only a barrel; the implementation is split by contract section into siblings:
 * - preference-resolution.ts: resolution / selectionPolicy / conflict rules
 * - safe-overlay.ts: safeOverlay
 * - tool-contributions.ts: typedContributions
 * - result-facts.ts: resultFacts
 * - continuation.ts: continuation
 * - retry.ts: retryPolicy
 * - capability-runtime.ts: wireNaming / stateRequirements / reasoningIntents of the shape contract
 */

export * from './types';
export * from './preference-resolution';
export * from './safe-overlay';
export * from './tool-contributions';
export * from './result-facts';
export * from './continuation';
export * from './retry';
export * from './capability-runtime';
export * from './owned-patch-compiler';
