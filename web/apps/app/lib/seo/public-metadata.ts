import type { Metadata } from 'next';
import { brand } from '@oriveo/config';

/**
 * Social preview card. A 1.91:1 image is what Open Graph and a Twitter summary_large_image expect;
 * declaring the card without one leaves an empty rectangle wherever the link is shared.
 */
export const APP_OG_IMAGE = {
  url: '/og.png',
  width: 1200,
  height: 630,
  alt: 'Oriveo - every model, one app',
} as const;

export const APP_PUBLIC_DESCRIPTION =
  'BYOK multi-model AI client for OpenAI, Claude, Gemini, OpenRouter and more. Chat, notes and real-time cost tracking, with your keys kept in your own browser.';

function normalizePath(path: string): string {
  if (!path || path === '/') return '/';
  return path.startsWith('/') ? path : `/${path}`;
}

function absoluteAppUrl(path = '/'): string {
  const normalizedPath = normalizePath(path);
  return normalizedPath === '/' ? brand.appUrl : `${brand.appUrl}${normalizedPath}`;
}

export function buildAppPageMetadata({
  title,
  description = APP_PUBLIC_DESCRIPTION,
  path,
  index = true,
  canonicalPath,
}: {
  title: string;
  description?: string;
  path: string;
  index?: boolean;
  canonicalPath?: string;
}): Metadata {
  const normalizedPath = normalizePath(path);
  const canonical = absoluteAppUrl(canonicalPath ?? normalizedPath);
  const fullTitle = title.includes(brand.name) ? title : `${title} | ${brand.name}`;

  return {
    title: fullTitle,
    description,
    alternates: {
      canonical,
    },
    openGraph: {
      type: 'website',
      locale: 'en_US',
      siteName: brand.name,
      title: fullTitle,
      description,
      url: canonical,
      images: [APP_OG_IMAGE],
    },
    twitter: {
      card: 'summary_large_image',
      title: fullTitle,
      description,
      images: [APP_OG_IMAGE.url],
    },
    robots: index ? { index: true, follow: true } : { index: false, follow: false },
  };
}
