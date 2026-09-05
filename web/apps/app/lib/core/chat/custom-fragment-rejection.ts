import type { SafeCustomFragmentResult } from '@oriveo/core/providers/request-builders/safe-custom-fragment';

export type CustomFragmentRejection = Extract<SafeCustomFragmentResult, { accepted: false }>['reason'];

/**
 * errorKind for the fail-closed custom request fields path (`/api/chat/stream` and the client use the
 * same name).
 *
 * It lives in this leaf module rather than in `proxy-client`, which a dozen tests replace wholesale with
 * `vi.mock`. Keeping the constant there would make any unrelated failure path blow up in tests with
 * "No export is defined on the mock".
 */
export const CUSTOM_FRAGMENT_ERROR_KIND = 'customRequestFieldsRejected';

/**
 * Syntax rejections: the ones fixed by editing the JSON itself. A fragment whose root is not an object
 * (`invalid_fragment`) counts here too.
 */
const SYNTAX_REJECTIONS = new Set(['invalid_json', 'duplicate_json_key', 'invalid_fragment']);

/**
 * Limit rejections: the content is valid, just too large or too complex. `size_exceeded` and
 * `operation_limit_exceeded` come from the compiler's safety limits (the safe-overlay LIMITS) and
 * measure the same thing as the three local checks.
 */
const LIMIT_REJECTIONS = new Set([
  'too_large', 'depth_exceeded', 'node_limit_exceeded', 'size_exceeded', 'operation_limit_exceeded',
]);

/**
 * Rejection copy. A path rejection has to answer "what am I allowed to write": saying only "this field
 * is not allowed" leaves the user guessing, while the allowed set is already known locally from the
 * published schema. A stored owner whose schema is gone has no allowed set to list, so the conflict is
 * stated plainly rather than showing an empty list.
 *
 * This lives in lib rather than in the editor component because the send-failure error card has to give
 * the same reason under the same classification. Two copies would inevitably drift (the editor saying
 * "over the size limit" while the error card says "provider failure" for the same rejection of the same
 * JSON).
 *
 * `invalid_fragment` must name exactly one thing, "the root is not an object". Collapsing every failure
 * from `compileOwnedPatches` into it as well would report the five path rejections `invalid_pointer`,
 * `blocked_segment`, `builder_owned_root`, `typed_contribution_required` and `blocked_value_key`, plus
 * the limit rejection `operation_limit_exceeded`, as syntax errors, leaving users to re-check perfectly
 * valid JSON while the real reason is that this owner cannot write that path. The compiler always knows
 * which one it is, and `SafeCustomFragmentRejection` carries that through unchanged.
 */
export function customFragmentRejectionMessage(
  reason: CustomFragmentRejection,
  allowedPaths: readonly string[],
): { key: string; values?: Record<string, string> } {
  if (SYNTAX_REJECTIONS.has(reason)) return { key: 'customRequestFieldsReasonSyntax' };
  if (LIMIT_REJECTIONS.has(reason)) return { key: 'customRequestFieldsReasonLimit' };
  if (allowedPaths.length === 0) return { key: 'customRequestFieldsNotAllowedConflict' };
  return { key: 'customRequestFieldsNotAllowed', values: { fields: allowedPaths.join(' - ') } };
}

/**
 * Sub-key for the reason line in the send-failure card (`errors.customRequestFieldsRejected.*`).
 *
 * It shares the same three-way classification as the editor but never lists the allowed set: the error
 * comes from the server-side compile boundary, where no local schema snapshot is available, and guessing
 * the allowed set would show a possibly stale list. Unknown reasons (future additions) all land in the
 * "not allowed" bucket, the only fallback that cannot lie, since the request really did not go out.
 */
export function customFragmentRejectionCopyKey(reason: string): 'reasonSyntax' | 'reasonLimit' | 'reasonNotAllowed' {
  const bucket = customFragmentRejectionMessage(reason as CustomFragmentRejection, []).key;
  if (bucket === 'customRequestFieldsReasonSyntax') return 'reasonSyntax';
  if (bucket === 'customRequestFieldsReasonLimit') return 'reasonLimit';
  return 'reasonNotAllowed';
}
