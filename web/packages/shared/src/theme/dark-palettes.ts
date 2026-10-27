/**
 * Dark palette ids.
 * Order and default follow `order` / `defaultId` in shared/theme-contracts/dark-palettes.v1.json.
 * Color values live only in packages/ui/src/tokens/variables.css; this file only handles ids and resolution.
 */
export const DARK_PALETTE_IDS = [
  'dark',
  'dark-purple',
  'dark-graphite',
  'dark-black',
  'dark-ocean',
  'dark-forest',
  'dark-sunset',
] as const;

export type DarkPaletteId = (typeof DARK_PALETTE_IDS)[number];

export const DEFAULT_DARK_PALETTE_ID: DarkPaletteId = 'dark';

export function isDarkPaletteId(value: unknown): value is DarkPaletteId {
  return typeof value === 'string' && (DARK_PALETTE_IDS as readonly string[]).includes(value);
}

/** Stored value to the palette actually rendered: unknown ids, non-strings and missing values all fall back to the default (the stored value is not written back). */
export function resolveDarkPaletteId(stored: unknown): DarkPaletteId {
  return isDarkPaletteId(stored) ? stored : DEFAULT_DARK_PALETTE_ID;
}
