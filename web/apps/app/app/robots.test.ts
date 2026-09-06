import { describe, expect, it } from 'vitest';
import { brand } from '@oriveo/config';
import robots from './robots';

describe('app robots', () => {
  // The origin must follow the deployment rather than being baked in, or a self-hosted copy
  // publishes a sitemap URL pointing at somebody else's host.
  it('allows crawling, refuses the route handlers, and points at its own sitemap', () => {
    expect(robots()).toEqual({
      rules: { userAgent: '*', allow: '/', disallow: '/api/' },
      sitemap: `${brand.appUrl}/sitemap.xml`,
    });
  });
});
