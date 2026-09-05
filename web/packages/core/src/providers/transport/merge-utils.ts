/**
 * Deep merge helper shared by the transport strategies.
 *
 * Purpose: deep merge the `profile.mergeParams` sent in metadata onto the request body.
 * Behaviour:
 *   - Only plain objects are merged recursively; arrays and non-object values overwrite, so a
 *     tools array in mergeParams does not blend into a strategy's own tools array
 *   - The target is written in place, and returning it just allows chaining
 */

export function deepMerge(
  target: Record<string, unknown>,
  source: Record<string, unknown>,
): Record<string, unknown> {
  for (const [key, srcVal] of Object.entries(source)) {
    const tgtVal = target[key];
    if (
      srcVal &&
      typeof srcVal === 'object' &&
      !Array.isArray(srcVal) &&
      tgtVal &&
      typeof tgtVal === 'object' &&
      !Array.isArray(tgtVal)
    ) {
      target[key] = deepMerge(
        { ...(tgtVal as Record<string, unknown>) },
        srcVal as Record<string, unknown>,
      );
    } else {
      target[key] = srcVal;
    }
  }
  return target;
}
