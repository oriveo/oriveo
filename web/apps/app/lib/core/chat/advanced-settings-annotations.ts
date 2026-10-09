/**
 * Page-wide tone and inline labels for "unverified" in advanced settings: when more than half the rows are unverified the header says so once, and rows keep only labels that differ from the tone.
 * The criteria are not rewritten: whether something is unverified is decided only by `showsUnverifiedBadge`, the presentation class only by the presentation-class table, and the header must also pass `showsUnverifiedGroupNote`.
 */
import type { CapabilityEvidenceResolution } from '@oriveo/core/providers/capability-evidence-facade';
import { showsUnverifiedBadge, showsUnverifiedGroupNote } from './generation-panel-presentation';
import {
  effectiveGenerationSupport,
  generationSupportPresentation,
  type GenerationPresentationClassId,
} from './generation-support-presentation';

export interface AdvancedRowAnnotationInput { id: string; presentationClass: GenerationPresentationClassId; isUnverified: boolean }
type Evidence = Pick<CapabilityEvidenceResolution, 'source' | 'grade' | 'support'>;

/** Same lookup as the panel's per-row rendering: the engineering state declared by the profile x evidence -> presentation class; the badge looks only at the projection. */
export function advancedRowAnnotationInput(id: string, declaredSupport: string, evidence: Evidence): AdvancedRowAnnotationInput {
  return {
    id,
    presentationClass: generationSupportPresentation(effectiveGenerationSupport(declaredSupport, evidence)).classId,
    isUnverified: showsUnverifiedBadge(evidence),
  };
}

/**
 * When `evidence` is given the header must also satisfy `showsUnverifiedGroupNote`. A row "has its own label" = it is unverified or its presentation class would speak up;
 * when the tone holds, rows that are unverified and whose presentation class equals the tone class are no longer labelled inline.
 */
export function resolveRowAnnotations(
  rows: readonly AdvancedRowAnnotationInput[],
  evidence?: readonly Pick<CapabilityEvidenceResolution, 'source' | 'grade'>[],
): { showsPageNote: boolean; inlineIds: string[] } {
  const annotated = rows.filter((row) => row.isUnverified || row.presentationClass !== 'silent');
  const unverified = rows.filter((row) => row.isUnverified);
  const showsPageNote = unverified.length * 2 > rows.length && (evidence === undefined || showsUnverifiedGroupNote(evidence));
  if (!showsPageNote) return { showsPageNote, inlineIds: annotated.map((row) => row.id) };
  const counts = new Map<GenerationPresentationClassId, number>();
  for (const row of unverified) counts.set(row.presentationClass, (counts.get(row.presentationClass) ?? 0) + 1);
  const [toneClass] = [...counts.entries()].sort(([a, x], [b, y]) => y - x || (a < b ? 1 : a > b ? -1 : 0))[0];
  return {
    showsPageNote,
    inlineIds: annotated.filter((row) => !row.isUnverified || row.presentationClass !== toneClass).map((row) => row.id),
  };
}
