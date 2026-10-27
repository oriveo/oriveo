import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { settingsGridShape } from './settings-home-rules';

interface GridCase {
  name: string;
  count: number;
  columns: number;
  rows: number;
}

const contract = JSON.parse(
  readFileSync(join(process.cwd(), '../../..', 'shared/theme-contracts/settings-home.v1.json'), 'utf8'),
) as { gridCases: GridCase[] };

function gridCase(name: string) {
  const c = contract.gridCases.find((item) => item.name === name);
  expect(c, `gridCases.${name}`).toBeDefined();
  expect(settingsGridShape(c!.count)).toEqual({ columns: c!.columns, rows: c!.rows });
}

describe('settingsGridShape (shared gridCases)', () => {
  it('grid_four_items_two_by_two', () => gridCase('grid_four_items_two_by_two'));
  it('grid_three_items_one_by_three', () => gridCase('grid_three_items_one_by_three'));
  it('grid_two_items_one_by_two', () => gridCase('grid_two_items_one_by_two'));
  it('grid_one_item_full_row', () => gridCase('grid_one_item_full_row'));
  it('grid_zero_items_hidden', () => gridCase('grid_zero_items_hidden'));

  it('every shared case is covered by one of the tests above', () => {
    expect(contract.gridCases.map((c) => c.name).sort()).toEqual([
      'grid_four_items_two_by_two',
      'grid_one_item_full_row',
      'grid_three_items_one_by_three',
      'grid_two_items_one_by_two',
      'grid_zero_items_hidden',
    ]);
  });
});
