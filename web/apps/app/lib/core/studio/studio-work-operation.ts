/**
 * Decides which operation a studio send performs (studio_data_model.v1 operationTable).
 * Input: whether the composer sits in a work detail, the roles of the attached images and
 * the operations the chosen model supports.
 */
import type { StudioRoundRefRow } from '../../infra/storage/idb';

export type StudioModelOperation = 'generate' | 'edit';
export type StudioOperationBase = 'current_version' | 'first_subject_as_v1';
export type StudioOperationBlock = 'model_cannot_reference_images' | 'model_needs_image';

export interface StudioOperationContext {
  inWorkDetail: boolean;
  images: readonly StudioRoundRefRow['role'][];
}

export interface StudioOperationDecision {
  operation: StudioModelOperation | null;
  base: StudioOperationBase | null;
  /** True when the first subject image is imported as v1 before the edit round. */
  importFirst: boolean;
  blocked?: StudioOperationBlock;
}

export function resolveStudioOperation(
  context: StudioOperationContext,
  modelOps: readonly StudioModelOperation[],
): StudioOperationDecision {
  const canGenerate = modelOps.includes('generate');
  const canEdit = modelOps.includes('edit');
  const hasImages = context.inWorkDetail || context.images.length > 0;
  if (hasImages && !canEdit) {
    return { operation: null, base: null, importFirst: false, blocked: 'model_cannot_reference_images' };
  }
  if (!hasImages && !canGenerate) {
    return { operation: null, base: null, importFirst: false, blocked: 'model_needs_image' };
  }
  if (context.inWorkDetail) return { operation: 'edit', base: 'current_version', importFirst: false };
  if (context.images.length === 0) return { operation: 'generate', base: null, importFirst: false };
  if (context.images.includes('subject')) {
    return { operation: 'edit', base: 'first_subject_as_v1', importFirst: true };
  }
  return { operation: 'edit', base: null, importFirst: false };
}
