import type { NextConfig } from 'next';
import {
  PHASE_DEVELOPMENT_SERVER,
  PHASE_PRODUCTION_BUILD,
  PHASE_PRODUCTION_SERVER,
} from 'next/constants';
import createNextIntlPlugin from 'next-intl/plugin';
import { resolve } from 'path';

const withNextIntl = createNextIntlPlugin('./i18n/request.ts');

const productionPhases = new Set([
  PHASE_PRODUCTION_BUILD,
  PHASE_PRODUCTION_SERVER,
]);

const securityHeaders = [
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()',
  },
  { key: 'Cross-Origin-Opener-Policy', value: 'same-origin-allow-popups' },
];

export function createOriveoNextConfig(phase: string): NextConfig {
  // Development builds go to their own directory so a running dev server and a production build
  // never fight over the same output.
  const distDir = productionPhases.has(phase)
    ? (process.env.NEXT_DIST_DIR || '.next')
    : '.next-dev';

  return {
    distDir,
    poweredByHeader: false,
    devIndicators: false,
    ...(phase === PHASE_DEVELOPMENT_SERVER
      ? { allowedDevOrigins: ['127.0.0.1'] }
      : {}),
    transpilePackages: ['@oriveo/config', '@oriveo/core', '@oriveo/ipc-contract', '@oriveo/shared', '@oriveo/ui'],
    outputFileTracingRoot: resolve(__dirname, '../../'),
    experimental: {
      // Next.js defaults dynamic segments to a zero-second client router cache, so switching back
      // to a tab the user just left re-fetches its RSC payload. Thirty seconds makes dock
      // navigation a cache hit with no network at all.
      staleTimes: {
        dynamic: 30,
        static: 180,
      },
    },
    webpack: (config, { isServer }) => {
      // Resolve hoisted dependencies in npm workspaces monorepo
      config.resolve.modules = [
        resolve(__dirname, '../../node_modules'),
        ...(config.resolve.modules || ['node_modules']),
      ];
      // pdfjs-dist is browser-only. Keeping it out of the server bundle avoids paying for it in
      // every serverless function.
      if (isServer) {
        config.externals = config.externals ?? [];
        if (Array.isArray(config.externals)) {
          config.externals.push('pdfjs-dist');
        }
      }
      return config;
    },
    async headers() {
      return [
        {
          source: '/sw.js',
          headers: [
            { key: 'Service-Worker-Allowed', value: '/' },
            { key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' },
          ],
        },
        {
          source: '/:path*',
          headers: securityHeaders,
        },
      ];
    },
  };
}

export default function nextConfig(phase: string): NextConfig {
  // Static export for the desktop shell, which loads the app from the filesystem and therefore
  // cannot use the image optimizer or response headers.
  if (process.env.ORIVEO_DESKTOP === '1') {
    return withNextIntl({
      ...createOriveoNextConfig(phase),
      output: 'export',
      distDir: 'out-desktop',
      trailingSlash: true,
      images: { unoptimized: true },
      headers: undefined,
    });
  }

  return withNextIntl(createOriveoNextConfig(phase));
}
