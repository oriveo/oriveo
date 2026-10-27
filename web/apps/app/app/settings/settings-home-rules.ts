// Pure rules for the settings home grid.
// Shared cases: shared/theme-contracts/settings-home.v1.json.

export interface SettingsGridShape {
  columns: number;
  rows: number;
}

/** Grid layout: 4 items 2x2; 3 items 1x3; 2 items 1x2; 1 item fills a row; 0 items render nothing. */
export function settingsGridShape(count: number): SettingsGridShape {
  if (count <= 0) return { columns: 0, rows: 0 };
  if (count === 4) return { columns: 2, rows: 2 };
  if (count <= 3) return { columns: count, rows: 1 };
  // The layout is only defined up to 4 items; beyond that wrap at 3 per row so no item is dropped.
  return { columns: 3, rows: Math.ceil(count / 3) };
}
