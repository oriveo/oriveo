/**
 * Studio prompt composition (shared fixture studio_prompt_compose.v1.json).
 * Pure function: expands inline `@N` references, appends one sentence per
 * attached reference image, then the style and effect sections; when the result
 * exceeds maxPromptChars (Unicode code points) effects are dropped from the last
 * one, then the style; the user text is never cut.
 */

export type StudioReferenceRole = 'base' | 'subject' | 'style' | 'composition' | 'person' | 'element';

export interface StudioPromptComposeSpec {
  sectionSeparator: string;
  inlineReference: string;
  referenceTemplate: string;
  baseTemplate: string;
  styleTemplate: string;
  effectsTemplate: string;
  effectsJoiner: string;
  roleWords: Record<Exclude<StudioReferenceRole, 'base'>, string>;
}

/** The spec block of studio_prompt_compose.v1.json, shipped with the app (the contract test asserts equality). */
export const STUDIO_PROMPT_COMPOSE_SPEC: StudioPromptComposeSpec & {
  order: readonly string[];
  userPromptMaxChars: number;
  truncation: string;
} = {
  sectionSeparator: '\n\n',
  inlineReference: 'image {n}',
  referenceTemplate: 'Image {n} is the {role} reference.',
  baseTemplate: 'Image {n} is the image to edit.',
  styleTemplate: 'Style: {fragment}.',
  effectsTemplate: 'Effects: {fragments}.',
  effectsJoiner: '; ',
  roleWords: { subject: 'subject', style: 'style', composition: 'composition', person: 'character', element: 'element' },
  order: ['user', 'references', 'style', 'effects'],
  userPromptMaxChars: 1000,
  truncation:
    'drop effects from the last one, then the style; the user text is never cut; still too long \u2192 prompt_too_long (composer blocks send)',
};

export interface StudioPromptReference {
  n: number;
  role: StudioReferenceRole;
}

export interface StudioPromptComposeInput {
  userPrompt: string;
  references: StudioPromptReference[];
  styleFragment?: string | null;
  effectFragments?: string[];
  maxPromptChars: number;
}

export interface StudioPromptAdjustment {
  field: 'effect' | 'style';
  dropped: string;
}

export interface StudioPromptComposeResult {
  composed: string | null;
  error: 'prompt_too_long' | null;
  adjustments: StudioPromptAdjustment[];
}

const codePoints = (s: string): number => [...s].length;

// Template values go in verbatim: a function replacer keeps `$&` / `$1` in fragments literal, no second pass.
const fill = (template: string, key: string, value: string): string => template.replace(key, () => value);

export function composeStudioPrompt(
  spec: StudioPromptComposeSpec,
  input: StudioPromptComposeInput,
): StudioPromptComposeResult {
  const adjustments: StudioPromptAdjustment[] = [];
  const user = input.userPrompt.replace(/@([0-9]+)/g, (_match, n: string) => fill(spec.inlineReference, '{n}', n));
  const refLines = input.references.map((ref) =>
    ref.role === 'base'
      ? fill(spec.baseTemplate, '{n}', String(ref.n))
      : fill(fill(spec.referenceTemplate, '{n}', String(ref.n)), '{role}', spec.roleWords[ref.role]),
  );
  let style = input.styleFragment ?? null;
  const effects = [...(input.effectFragments ?? [])];
  const build = (): string => {
    // An empty user text (exactly "", no trimming) adds no section.
    const sections = user === '' ? [] : [user];
    if (refLines.length) sections.push(refLines.join(' '));
    if (style) sections.push(fill(spec.styleTemplate, '{fragment}', style));
    if (effects.length) sections.push(fill(spec.effectsTemplate, '{fragments}', effects.join(spec.effectsJoiner)));
    return sections.join(spec.sectionSeparator);
  };
  let composed = build();
  while (codePoints(composed) > input.maxPromptChars && effects.length) {
    adjustments.push({ field: 'effect', dropped: effects.pop() as string });
    composed = build();
  }
  if (codePoints(composed) > input.maxPromptChars && style) {
    adjustments.push({ field: 'style', dropped: style });
    style = null;
    composed = build();
  }
  if (codePoints(composed) > input.maxPromptChars) return { composed: null, error: 'prompt_too_long', adjustments };
  return { composed, error: null, adjustments };
}
