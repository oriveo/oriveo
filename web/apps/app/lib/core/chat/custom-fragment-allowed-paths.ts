import type { AIModel } from '@oriveo/shared';
import { resolveCustomControlDefinitions } from '@oriveo/core/providers/request-preference/capability-runtime';
import { getCapabilityRuntime } from '../metadata/metadata-client';
import type { CustomFragmentOwner } from './custom-fragment-rejection';

/**
 * Fields this section may write: the same official declaration as the edit page (`resolveCustomControlDefinitions`).
 * It does not live in the `custom-fragment-rejection` leaf module because that module must not pull in metadata-client.
 * The parameter section (generation) goes through the additional body and has no per-field declaration to list, so it returns an empty list and the error card says the conflict sentence.
 */
export function customFragmentAllowedPaths(model: AIModel, owner: CustomFragmentOwner): string[] {
  if (owner === 'generation') return [];
  const runtime = getCapabilityRuntime();
  if (!runtime) return [];
  return resolveCustomControlDefinitions(owner, model.capabilityControls?.[owner], runtime.controlDefinitions, runtime.sourceIndex)
    .map((definition) => definition.targetPointer);
}
