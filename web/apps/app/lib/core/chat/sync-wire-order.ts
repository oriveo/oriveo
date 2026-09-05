/**
 * Ordering of array elements inside a cross-client envelope (wire order).
 *
 * It has to be a platform-independent deterministic order: JavaScript's `<`, Kotlin's `sortedBy`
 * and Swift's `<` must produce the same array for the same set of record ids, so it makes no
 * difference which client wrote the envelope.
 *
 * `localeCompare` cannot be used. It applies ICU collation, which treats punctuation such as `~` as
 * an ignorable weight and puts `~deepseek/...` before `z-ai/...`, while the code-unit order used on
 * Android and iOS puts `~` (U+007E) after `z` (U+007A). Each side then rewrites the same content in
 * its own order, and because the comparison is an ordered array comparison, the two keep
 * overwriting each other with envelopes whose only difference is the order of the array.
 */
export function compareWireId(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
