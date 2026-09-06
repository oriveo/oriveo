import type { MetadataRoute } from 'next';
import { brand } from '@oriveo/config';

/**
 * The landing page is the only indexable route; everything else holds the user's own data and is
 * served `noindex`. No `lastModified` is published: it would have to be a date baked into the
 * build, which says nothing true about a deployment someone else runs.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: `${brand.appUrl}/welcome`,
      changeFrequency: 'weekly',
      priority: 1,
    },
  ];
}
