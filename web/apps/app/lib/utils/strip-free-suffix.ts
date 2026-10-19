/**
 * Strip a trailing "(free)" suffix from a model name (case-insensitive, along with surrounding whitespace); the UI already has a Free badge, so this avoids duplication.
 * If stripping leaves nothing, return the name unchanged so it is not erased. The rules differ from cleanModelName, so it is not reused.
 */
export function stripFreeSuffix(name: string): string {
  return name.replace(/\s*\(free\)\s*$/i, '').trim() || name;
}
