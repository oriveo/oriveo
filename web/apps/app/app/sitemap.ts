import type { MetadataRoute } from 'next';
import { brand } from '@oriveo/config';

const LAST_MODIFIED = new Date('2026-04-19T00:00:00.000Z');

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: `${brand.appUrl}/welcome`,
      lastModified: LAST_MODIFIED,
      changeFrequency: 'weekly',
      priority: 0.9,
    },
  ];
}
