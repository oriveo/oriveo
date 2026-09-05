import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const appDir = resolve(__dirname, '..', '..');
const publicDir = join(appDir, 'public');
const appRouterDir = join(appDir, 'app');

describe('app icon assets', () => {
  it('keeps manifest-declared PWA icons present on disk', () => {
    const manifestPath = join(publicDir, 'manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      icons?: Array<{ src: string }>;
    };

    expect(Array.isArray(manifest.icons)).toBe(true);

    for (const icon of manifest.icons ?? []) {
      const iconPath = join(publicDir, icon.src.replace(/^\//, ''));
      expect(existsSync(iconPath)).toBe(true);
    }
  });

  it('ships a route-level favicon entry for browser tabs', () => {
    expect(existsSync(join(appRouterDir, 'icon.svg'))).toBe(true);
  });
});
