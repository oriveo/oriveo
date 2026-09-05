import type { MetadataRoute } from 'next';
import { brand } from '@oriveo/config';

export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: '*', allow: '/' },
    sitemap: `${brand.appUrl}/sitemap.xml`,
  };
}
