import type { Metadata } from 'next';
import { brand } from '@oriveo/config';

export const APP_PUBLIC_DESCRIPTION =
  'BYOK multi-model AI client for OpenAI, Claude, Gemini, and OpenRouter. One app for web chat, sync, and real-time cost tracking.';

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
    },
    twitter: {
      card: 'summary_large_image',
      title: fullTitle,
      description,
    },
    robots: index ? { index: true, follow: true } : { index: false, follow: false },
  };
}
