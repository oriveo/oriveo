import type { LibraryProvider } from "./types";

const SOURCE_MENTION_PATTERN = /(^|\s)@(notion|google(?:\s+(?:docs|drive))?)(?=$|[\s,.;:!? )\]])/giu;

/**
 * Resolves explicit Library source mentions from user-authored text.
 * The visible mention stays in the message so retry/regenerate/continue can
 * reconstruct the same source boundary without separate ephemeral state.
 */
export function extractLibrarySourceMentions(text: string): LibraryProvider[] {
  const sources: LibraryProvider[] = [];
  for (const match of text.matchAll(SOURCE_MENTION_PATTERN)) {
    const source: LibraryProvider = match[2].toLocaleLowerCase().startsWith("google")
      ? "google"
      : "notion";
    if (!sources.includes(source)) sources.push(source);
  }
  return sources;
}
