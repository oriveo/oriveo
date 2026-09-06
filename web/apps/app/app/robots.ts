import type { MetadataRoute } from 'next';
import { brand } from '@oriveo/config';

/**
 * Crawling is allowed at the top level and the per-route decision is made by the `X-Robots-Tag`
 * header the proxy sets, because a crawler has to be able to fetch a page to read that header.
 * Only the route handlers are refused outright: they answer nothing a crawler can use.
 *
 * The sitemap URL comes from NEXT_PUBLIC_APP_URL, so a self-hosted deployment publishes its own
 * origin rather than someone else's.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: '*', allow: '/', disallow: '/api/' },
    sitemap: `${brand.appUrl}/sitemap.xml`,
  };
}
