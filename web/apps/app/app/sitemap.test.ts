import { describe, expect, it } from 'vitest';
import { brand } from '@oriveo/config';
import sitemap from './sitemap';

describe('app sitemap', () => {
  it('only exposes the public welcome landing page, at the configured origin', () => {
    expect(sitemap()).toEqual([
      {
        url: `${brand.appUrl}/welcome`,
        changeFrequency: 'weekly',
        priority: 1,
      },
    ]);
  });

  // A build-time constant would claim a modification date that has nothing to do with the content
  // a given deployment is serving.
  it('publishes no lastModified date', () => {
    expect(sitemap()[0].lastModified).toBeUndefined();
  });
});
