import { describe, expect, it } from 'vitest';
import { brand } from '@oriveo/config';
import robots from './robots';

describe('app robots', () => {
  it('publishes a sitemap for the app subdomain', () => {
    expect(robots()).toEqual({
      rules: { userAgent: '*', allow: '/' },
      sitemap: `${brand.appUrl}/sitemap.xml`,
    });
  });
});
