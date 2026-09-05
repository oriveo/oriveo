const INDEXABLE_PATHS = new Set(['/welcome']);

function normalizePathname(pathname: string): string {
  if (!pathname || pathname === '/') {
    return '/';
  }

  return pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
}

function isAssetLikePath(pathname: string): boolean {
  return /\.[a-z0-9]+$/i.test(pathname);
}

export function resolveRobotsHeader(pathname: string): string | null {
  const normalizedPath = normalizePathname(pathname);

  if (
    normalizedPath.startsWith('/api')
    || normalizedPath.startsWith('/_next')
    || normalizedPath === '/robots.txt'
    || normalizedPath === '/sitemap.xml'
    || isAssetLikePath(normalizedPath)
  ) {
    return null;
  }

  if (INDEXABLE_PATHS.has(normalizedPath)) {
    return null;
  }

  return 'noindex, nofollow';
}
