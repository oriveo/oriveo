import type { CapabilityEvidenceResolution } from '@oriveo/core/providers/capability-evidence-facade';

/**
 * Maps the 8 engineering states of a generation parameter onto 3 user-visible classes.
 *
 * This table is a byte-for-byte mirror of `presentationClasses` in the shared generation parameter
 * contract: the contract JSON ships with all of its fixtures and cannot go into the client bundle,
 * so it is mirrored as a TS constant and reconciled by a contract test.
 * `__tests__/generation-support-presentation.contract.test.ts` asserts that the two sides match
 * exactly and that every `support` value appearing in the contract has an entry here, so a ninth
 * state added on the server fails at test time instead of silently falling into a default branch
 * and rendering as "unknown".
 *
 * Two concrete defects this table fixes:
 *   1. Taking the three-valued `evidence.support` as input made the `accepted_unverified` case
 *      structurally unreachable.
 *   2. `unsupported` / `accepted` / `future_supported` all hit the default branch, so "does not
 *      work", "already supported" and "not opened up by the vendor yet" were all reported as
 *      "unknown".
 */

/** The 8 engineering states of `schema.support` in the contract. */
export type GenerationSupportState =
  | 'supported'
  | 'accepted'
  | 'accepted_unverified'
  | 'fixed'
  | 'unsupported'
  | 'mode_dependent'
  | 'unknown'
  | 'future_supported';

export type GenerationPresentationClassId = 'silent' | 'unverified' | 'not_adjustable' | 'no_data';

export interface GenerationPresentationClass {
  readonly classId: GenerationPresentationClassId;
  /** false = stays silent and renders nothing at all. */
  readonly renders: boolean;
  readonly control: 'editable' | 'disabled';
  /** No label key when `renders: false`. */
  readonly labelKey?: string;
}

export const GENERATION_PRESENTATION_CLASSES: Readonly<
  Record<GenerationPresentationClassId, GenerationPresentationClass>
> = {
  silent: { classId: 'silent', renders: false, control: 'editable' },
  unverified: {
    classId: 'unverified', renders: true, control: 'editable',
    labelKey: 'generationParameterClassUnverified',
  },
  not_adjustable: {
    classId: 'not_adjustable', renders: true, control: 'disabled',
    labelKey: 'generationParameterClassNotAdjustable',
  },
  no_data: {
    classId: 'no_data', renders: true, control: 'editable',
    labelKey: 'generationParameterClassNoData',
  },
};

export const GENERATION_SUPPORT_MAP: Readonly<
  Record<GenerationSupportState, { readonly classId: GenerationPresentationClassId; readonly detailKey?: string }>
> = {
  supported: { classId: 'silent' },
  accepted: { classId: 'silent' },
  accepted_unverified: {
    classId: 'unverified', detailKey: 'generationParameterDetailAcceptedUnverified',
  },
  fixed: { classId: 'not_adjustable', detailKey: 'generationParameterDetailFixed' },
  unsupported: { classId: 'not_adjustable', detailKey: 'generationParameterDetailUnsupported' },
  mode_dependent: { classId: 'not_adjustable', detailKey: 'generationParameterDetailModeDependent' },
  unknown: { classId: 'no_data', detailKey: 'generationParameterDetailUnknown' },
  future_supported: { classId: 'not_adjustable', detailKey: 'generationParameterDetailFutureSupported' },
};

export interface GenerationSupportPresentation extends GenerationPresentationClass {
  readonly support: GenerationSupportState;
  readonly detailKey?: string;
}

/** Table lookup. An unknown literal falls back to the most conservative "no information" class, and the contract test guarantees it cannot happen. */
export function generationSupportPresentation(support: string): GenerationSupportPresentation {
  const entry = GENERATION_SUPPORT_MAP[support as GenerationSupportState]
    ?? GENERATION_SUPPORT_MAP.unknown;
  const known = (support in GENERATION_SUPPORT_MAP ? support : 'unknown') as GenerationSupportState;
  return { ...GENERATION_PRESENTATION_CLASSES[entry.classId], support: known, ...(entry.detailKey ? { detailKey: entry.detailKey } : {}) };
}

/**
 * Declared engineering state x measured evidence -> the engineering state this row should actually
 * present.
 *
 * The evidence layer is three-valued (supported / unsupported / unknown), and feeding it straight
 * into presentation is what produced the dead branch. The relationship runs the other way here:
 * evidence only vetoes and downgrades, while the engineering state itself still comes from the
 * declared profile.
 */
export function effectiveGenerationSupport(
  declared: string,
  evidence: Pick<CapabilityEvidenceResolution, 'support'>,
): GenerationSupportState {
  // The four explicit negative profile states keep their own precise wording; none of them is editable or outbound.
  if (declared === 'fixed' || declared === 'mode_dependent'
    || declared === 'unsupported' || declared === 'future_supported') return declared;
  // Every other state tightens when the runtime or the vendor explicitly rejects it.
  if (evidence.support === 'unsupported') return 'unsupported';
  if (evidence.support === 'supported') return 'supported';
  // Evidence has no verdict, including a relay downgraded to connection-scoped unknown. A positive
  // declared state must not stand in for a verdict, since that claims knowledge this layer does not have.
  // Downgrade to "will be sent, effect unverified" - unverified is not the same as unsupported, and
  // the value is still sent. Every other engineering state is already honest and passes through.
  if (declared === 'supported') return 'accepted_unverified';
  return declared in GENERATION_SUPPORT_MAP ? declared as GenerationSupportState : 'unknown';
}
