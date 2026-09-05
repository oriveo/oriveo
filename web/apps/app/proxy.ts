import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';
import { SUPPORTED_LOCALES } from './lib/i18n/locale-utils';
import { resolveRobotsHeader } from './lib/seo/indexing';

const SUPPORTED_LOCALE_SET = new Set<string>(SUPPORTED_LOCALES);

export function proxy(request: NextRequest) {
  // A locale passed in as ?locale= is stored in a cookie, then redirected away to a clean URL.
  const localeParam = request.nextUrl.searchParams.get('locale');
  if (localeParam && SUPPORTED_LOCALE_SET.has(localeParam)) {
    const target = request.nextUrl.clone();
    target.searchParams.delete('locale');
    const redirect = NextResponse.redirect(target);
    redirect.cookies.set('NEXT_LOCALE', localeParam, {
      path: '/',
      maxAge: 365 * 24 * 60 * 60,
      sameSite: 'lax',
    });
    return redirect;
  }

  const response = NextResponse.next();
  const robotsHeader = resolveRobotsHeader(request.nextUrl.pathname);

  if (robotsHeader) {
    response.headers.set('X-Robots-Tag', robotsHeader);
  }

  return response;
}

export const config = {
  matcher: [
    '/((?!api|_next/static|_next/image).*)',
  ],
};
