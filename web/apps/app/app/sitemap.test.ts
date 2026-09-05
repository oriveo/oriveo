import { describe, expect, it } from 'vitest';
import { brand } from '@oriveo/config';
import sitemap from './sitemap';

describe('app sitemap', () => {
  it('only exposes the public welcome landing page', () => {
    expect(sitemap()).toEqual([
      {
        url: `${brand.appUrl}/welcome`,
        lastModified: new Date('2026-04-19T00:00:00.000Z'),
        changeFrequency: 'weekly',
        priority: 0.9,
      },
    ]);
  });
});
