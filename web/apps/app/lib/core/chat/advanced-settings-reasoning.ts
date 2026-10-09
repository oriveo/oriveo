/**
 * When a reasoning-group parameter has no write path in this profile's wire table, its row in advanced
 * settings cannot be edited and is not sent with the request: thinking is set by the thinking setting
 * in the model options. This is not "this model does not support it", so no "view supported models"
 * style link out is offered.
 */
import type { GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import { isReasoningParameterID } from './generation-parameter-settings';

export interface ReasoningRowWithoutWritePath { editable: false; statusNote: 'reasoningSetByThinking'; offersSupportedModels: false }

export function reasoningRowWithoutWritePath(parameter: { id: string }, profile: GenerationParameterProfile): ReasoningRowWithoutWritePath | undefined {
  if (!isReasoningParameterID(parameter.id) || profile.wire[parameter.id]) return undefined;
  return { editable: false, statusNote: 'reasoningSetByThinking', offersSupportedModels: false };
}
