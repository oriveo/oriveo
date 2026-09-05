import type { Folder } from './types/models';

/**
 * The ten folder colours, with the same names and hex pairs as the iOS and Android FolderColor
 * tables. A folder carries only its colour tag across sync, so the tables have to agree or the
 * same folder shows up in a different colour on another device.
 */

export const FOLDER_COLORS: Record<string, { main: string; dark: string }> = {
  blue:   { main: '#3B82F6', dark: '#2563EB' },
  purple: { main: '#8B5CF6', dark: '#7C3AED' },
  pink:   { main: '#EC4899', dark: '#DB2777' },
  red:    { main: '#EF4444', dark: '#DC2626' },
  orange: { main: '#F97316', dark: '#EA580C' },
  yellow: { main: '#EAB308', dark: '#CA8A04' },
  green:  { main: '#22C55E', dark: '#16A34A' },
  teal:   { main: '#14B8A6', dark: '#0D9488' },
  indigo: { main: '#6366F1', dark: '#4F46E5' },
  gray:   { main: '#6B7280', dark: '#4B5563' },
};

/** Rotation order */
export const FOLDER_COLOR_ORDER: string[] = [
  'blue', 'purple', 'pink', 'red', 'orange',
  'yellow', 'green', 'teal', 'indigo', 'gray',
];

/** An unknown or missing tag resolves to blue rather than leaving the folder unstyled. */
export function getFolderColorPair(tag?: string): [string, string] {
  const entry = tag ? FOLDER_COLORS[tag] : undefined;
  const fallback = FOLDER_COLORS['blue'];
  return [(entry ?? fallback).main, (entry ?? fallback).dark];
}

/** Picks the next color from the folders that already exist. */
export function getNextFolderColor(folders: Folder[]): string {
  const sorted = [...folders].sort((a, b) => a.sortOrder - b.sortOrder);
  const lastFolder = sorted[sorted.length - 1];
  if (!lastFolder?.colorTag) return 'blue';

  const lastIndex = FOLDER_COLOR_ORDER.indexOf(lastFolder.colorTag);
  if (lastIndex === -1) return 'blue';
  return FOLDER_COLOR_ORDER[(lastIndex + 1) % FOLDER_COLOR_ORDER.length];
}
