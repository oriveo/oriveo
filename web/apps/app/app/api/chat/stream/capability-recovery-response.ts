import type { ProviderRequest } from '@oriveo/core/providers/request-builders/types';
import {
  CAPABILITY_RECOVERY_HEADER,
  encodeCapabilityRecoveryDescriptor,
  locateCapabilityRecovery,
} from '../../../../lib/core/chat/capability-recovery-runtime';

/** Produces the route header strictly from the final production builder object. */
export function capabilityRecoveryHeaders(
  request: ProviderRequest,
  status: number,
  errorText: string,
): Record<string, string> {
  let structuredError: unknown;
  try { structuredError = JSON.parse(errorText); } catch { return {}; }
  const resultEnvelope = request.capabilityExecution?.resultEnvelope as {
    errorRecoveryDefinitions?: unknown;
    recipes?: unknown;
  } | undefined;
  const customDescriptor = locateCapabilityRecovery({
    status,
    preToken: true,
    streamStarted: false,
    sideEffects: false,
    automaticRetryCount: 0,
    source: 'custom',
    structuredError,
    customAppliedPointers: request.capabilityExecution?.customAppliedPointers,
  }, undefined);
  const descriptor = customDescriptor ?? locateCapabilityRecovery({
    status,
    preToken: true,
    streamStarted: false,
    sideEffects: false,
    automaticRetryCount: 0,
    source: 'provider_recipe',
    recipeRefs: request.capabilityExecution?.recipeRefs ?? [],
    recipes: resultEnvelope?.recipes,
    structuredError,
  }, resultEnvelope?.errorRecoveryDefinitions);
  return descriptor ? { [CAPABILITY_RECOVERY_HEADER]: encodeCapabilityRecoveryDescriptor(descriptor) } : {};
}
