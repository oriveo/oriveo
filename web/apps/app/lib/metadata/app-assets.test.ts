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

  // A maskable icon is what a launcher crops to its own shape; without one the installed app gets
  // the square artwork letterboxed inside a circle.
  it('declares a maskable icon and ships it', () => {
    const manifestPath = join(publicDir, 'manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      icons?: Array<{ src: string; purpose?: string }>;
    };

    const maskable = manifest.icons?.find((icon) => icon.purpose === 'maskable');
    expect(maskable, 'manifest declares no maskable icon').toBeDefined();
    expect(existsSync(join(publicDir, maskable!.src.replace(/^\//, '')))).toBe(true);
  });

  it('ships a route-level favicon entry for browser tabs', () => {
    expect(existsSync(join(appRouterDir, 'icon.png'))).toBe(true);
  });

  // Declaring a summary_large_image card with no image leaves an empty rectangle wherever the app
  // is linked, so the file has to exist alongside the declaration.
  it('ships the social preview image the page metadata declares', () => {
    expect(existsSync(join(publicDir, 'og.png'))).toBe(true);
  });
});
