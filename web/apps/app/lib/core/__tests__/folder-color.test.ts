import { describe, it, expect } from 'vitest';
import {
  FOLDER_COLORS,
  FOLDER_COLOR_ORDER,
  getFolderColorPair,
  getNextFolderColor,
} from '@oriveo/shared';
import type { Folder } from '@oriveo/shared';

function makeFolder(overrides: Partial<Folder> = {}): Folder {
  return {
    id: crypto.randomUUID(),
    name: 'Test',
    sortOrder: 1000,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

describe('folder-color', () => {
  describe('FOLDER_COLORS', () => {
    it('has 10 colors', () => {
      expect(Object.keys(FOLDER_COLORS)).toHaveLength(10);
    });

    it('each color has main and dark hex values', () => {
      for (const [, { main, dark }] of Object.entries(FOLDER_COLORS)) {
        expect(main).toMatch(/^#[0-9A-F]{6}$/i);
        expect(dark).toMatch(/^#[0-9A-F]{6}$/i);
      }
    });
  });

  describe('FOLDER_COLOR_ORDER', () => {
    it('has 10 entries matching FOLDER_COLORS keys', () => {
      expect(FOLDER_COLOR_ORDER).toHaveLength(10);
      for (const tag of FOLDER_COLOR_ORDER) {
        expect(FOLDER_COLORS[tag]).toBeDefined();
      }
    });

    it('starts with blue', () => {
      expect(FOLDER_COLOR_ORDER[0]).toBe('blue');
    });
  });

  describe('getFolderColorPair', () => {
    it('returns blue pair for undefined', () => {
      const [main, dark] = getFolderColorPair(undefined);
      expect(main).toBe(FOLDER_COLORS['blue'].main);
      expect(dark).toBe(FOLDER_COLORS['blue'].dark);
    });

    it('returns blue pair for unrecognized tag', () => {
      const [main] = getFolderColorPair('nonexistent');
      expect(main).toBe(FOLDER_COLORS['blue'].main);
    });

    it('returns correct pair for valid tag', () => {
      const [main, dark] = getFolderColorPair('pink');
      expect(main).toBe(FOLDER_COLORS['pink'].main);
      expect(dark).toBe(FOLDER_COLORS['pink'].dark);
    });
  });

  describe('getNextFolderColor', () => {
    it('returns blue for empty array', () => {
      expect(getNextFolderColor([])).toBe('blue');
    });

    it('returns purple after blue', () => {
      const folders = [makeFolder({ sortOrder: 1000, colorTag: 'blue' })];
      expect(getNextFolderColor(folders)).toBe('purple');
    });

    it('wraps around after gray', () => {
      const folders = [makeFolder({ sortOrder: 1000, colorTag: 'gray' })];
      expect(getNextFolderColor(folders)).toBe('blue');
    });

    it('uses the last folder by sortOrder', () => {
      const folders = [
        makeFolder({ sortOrder: 2000, colorTag: 'red' }),
        makeFolder({ sortOrder: 1000, colorTag: 'blue' }),
        makeFolder({ sortOrder: 3000, colorTag: 'green' }),
      ];
      expect(getNextFolderColor(folders)).toBe('teal'); // next after green
    });

    it('returns blue when last folder has no colorTag', () => {
      const folders = [makeFolder({ sortOrder: 1000 })];
      expect(getNextFolderColor(folders)).toBe('blue');
    });

    it('returns blue when last folder has unknown colorTag', () => {
      const folders = [makeFolder({ sortOrder: 1000, colorTag: 'neon' })];
      expect(getNextFolderColor(folders)).toBe('blue');
    });
  });
});
