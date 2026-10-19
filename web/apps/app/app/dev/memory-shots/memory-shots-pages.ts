/** Page names of the memory page family samples (the same set as the shared manifest shared/test-fixtures/shots/memory.v1.json, iOS and Android; original casing). */
export const MEMORY_SHOT_PAGES = [
  'memoryStarter',
  'memoryList',
  'memoryInbox',
  'memoryEditorL2',
  'memoryEditorL3',
  'memoryRaw',
] as const;

export type MemoryShotPage = (typeof MEMORY_SHOT_PAGES)[number];

export function isMemoryShotPage(value: string): value is MemoryShotPage {
  return (MEMORY_SHOT_PAGES as readonly string[]).includes(value);
}
