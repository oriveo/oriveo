import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Inter, JetBrains_Mono } from 'next/font/google';
import { NextIntlClientProvider } from 'next-intl';
import { getLocale, getMessages } from 'next-intl/server';
import { brand } from '@oriveo/config';
import { StoreProvider } from '../providers/StoreProvider';
import { SRLiveRegion } from '../components/SRLiveRegion';
import { RouteTitleSync } from '../components/RouteTitleSync';
import { ThemeInitScript } from '../components/ThemeInitScript';
import { PersistentShellLayout } from '../components/PersistentShellLayout';
import { ClientIntlProvider } from '../components/i18n/ClientIntlProvider';
import { LocalePreferenceSync } from '../components/i18n/LocalePreferenceSync';
import { isRTL } from '../lib/i18n/locale-utils';
import { APP_OG_IMAGE, APP_PUBLIC_DESCRIPTION } from '../lib/seo/public-metadata';
import 'katex/dist/katex.min.css';
import './globals.css';

const inter = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-inter',
});

const jetbrainsMono = JetBrains_Mono({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-jetbrains-mono',
});

// await cookies() / headers() in i18n/request.ts already makes Next.js treat the route as
// dynamic; an explicit force-dynamic only disables RSC rendering optimizations, so scheduling is
// left to the framework.
export const metadata: Metadata = {
  // Relative URLs in the metadata below resolve against this, so a self-hosted deployment must set
  // NEXT_PUBLIC_APP_URL or every canonical and preview link points at the dev port.
  metadataBase: new URL(brand.appUrl),
  title: {
    default: `${brand.name} - ${brand.tagline}`,
    template: `%s | ${brand.name}`,
  },
  description: APP_PUBLIC_DESCRIPTION,
  applicationName: brand.name,
  manifest: '/manifest.json',
  // The locale is chosen from a cookie and Accept-Language rather than from the path, so there is
  // no per-language URL to advertise and no hreflang set to publish.
  openGraph: {
    type: 'website',
    siteName: brand.name,
    title: `${brand.name} - ${brand.tagline}`,
    description: APP_PUBLIC_DESCRIPTION,
    images: [APP_OG_IMAGE],
  },
  twitter: {
    card: 'summary_large_image',
    title: `${brand.name} - ${brand.tagline}`,
    description: APP_PUBLIC_DESCRIPTION,
    images: [APP_OG_IMAGE.url],
  },
  icons: {
    icon: [
      { url: '/icon.svg', type: 'image/svg+xml' },
    ],
    apple: [
      { url: '/apple-touch-icon.png', sizes: '180x180', type: 'image/png' },
    ],
    shortcut: ['/icon.svg'],
  },
};

type RootLayoutProps = {
  children: ReactNode;
};

/**
 * Desktop static export branch: the server-side getLocale/getMessages are not called, because
 * cookies() and headers() are unavailable under export, so ClientIntlProvider resolves the locale
 * on the client instead. No service worker is registered either, since it serves no purpose on
 * desktop and is a source of cache poisoning. lang and dir are set at runtime by
 * ClientIntlProvider. The default web branch is unaffected.
 */
function DesktopRootLayout({ children }: RootLayoutProps) {
  return (
    <html lang="en" suppressHydrationWarning className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <head>
        <ThemeInitScript />
        <meta name="theme-color" content="#8B5CF6" />
      </head>
      <body suppressHydrationWarning>
        <a href="#main-content" className="sr-skip" style={{
          position: 'absolute', left: '-9999px', top: 'auto', width: '1px', height: '1px', overflow: 'hidden', zIndex: 9999,
        }}>Skip to content</a>
        <ClientIntlProvider>
          <SRLiveRegion>
            <StoreProvider>
              <RouteTitleSync />
              <LocalePreferenceSync />
              <PersistentShellLayout>{children}</PersistentShellLayout>
            </StoreProvider>
          </SRLiveRegion>
        </ClientIntlProvider>
      </body>
    </html>
  );
}

export default async function RootLayout({ children }: RootLayoutProps) {
  if (process.env.ORIVEO_DESKTOP === '1') {
    return <DesktopRootLayout>{children}</DesktopRootLayout>;
  }

  const locale = await getLocale();
  const messages = await getMessages();
  const dir = isRTL(locale) ? 'rtl' : 'ltr';

  return (
    <html lang={locale} dir={dir} suppressHydrationWarning className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <head>
        <ThemeInitScript />
        <meta name="theme-color" content="#8B5CF6" />
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
      </head>
      <body suppressHydrationWarning>
        <a href="#main-content" className="sr-skip" style={{
          position: 'absolute',
          left: '-9999px',
          top: 'auto',
          width: '1px',
          height: '1px',
          overflow: 'hidden',
          zIndex: 9999,
        }}>Skip to content</a>
        <NextIntlClientProvider messages={messages}>
          <SRLiveRegion>
            <StoreProvider>
              <RouteTitleSync />
              <LocalePreferenceSync />
              <PersistentShellLayout>{children}</PersistentShellLayout>
            </StoreProvider>
          </SRLiveRegion>
        </NextIntlClientProvider>
        <script dangerouslySetInnerHTML={{ __html: `
          if ('serviceWorker' in navigator) {
            var h = location.hostname;
            var isDevHost =
              h === 'localhost' ||
              h === '127.0.0.1' ||
              h === '::1' ||
              /^192\\.168\\./.test(h) ||
              /^10\\./.test(h) ||
              /^172\\.(1[6-9]|2\\d|3[0-1])\\./.test(h);
            if (isDevHost) {
              var cleanup = [
                navigator.serviceWorker.getRegistrations().then(function(rs) {
                  return Promise.all(rs.map(function(r) { return r.unregister(); }));
                })
              ];
              if ('caches' in window) {
                cleanup.push(
                  caches.keys().then(function(keys) {
                    return Promise.all(keys.map(function(key) { return caches.delete(key); }));
                  })
                );
              }
              Promise.all(cleanup).then(function() {
                if (navigator.serviceWorker.controller && sessionStorage.getItem('oriveo:sw-reset') !== '1') {
                  sessionStorage.setItem('oriveo:sw-reset', '1');
                  window.location.reload();
                }
              });
            } else {
              window.addEventListener('load', function() {
                navigator.serviceWorker.register('/sw.js').catch(function() {});
              });
            }
          }
        `}} />
      </body>
    </html>
  );
}
