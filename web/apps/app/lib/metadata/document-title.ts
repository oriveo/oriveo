export type RouteTitleKey =
  | 'backup'
  | 'chat'
  | 'folder'
  | 'manualModel'
  | 'memory'
  | 'providerList'
  | 'providerSetup'
  | 'relaySetup'
  | 'settings'
  | 'skills'
  | 'skillEdit'
  | 'welcome';

type RouteTitleLabels = Record<RouteTitleKey, string>;

interface RouteTitleContext {
  providerName?: string | null;
  folderName?: string | null;
}

function normalizePathname(pathname: string): string {
  const withoutHash = pathname.split('#', 1)[0] ?? pathname;
  const withoutQuery = withoutHash.split('?', 1)[0] ?? withoutHash;

  if (!withoutQuery || withoutQuery === '/') {
    return '/';
  }

  return withoutQuery.endsWith('/') ? withoutQuery.slice(0, -1) : withoutQuery;
}

function formatDocumentTitle(pageTitle: string, brandName: string): string {
  const normalizedTitle = pageTitle.trim();
  if (!normalizedTitle) {
    return brandName;
  }

  const alreadyBranded = normalizedTitle === brandName
    || normalizedTitle.endsWith(`| ${brandName}`)
    || normalizedTitle.endsWith(`- ${brandName}`)
    || normalizedTitle.endsWith(`— ${brandName}`);

  return alreadyBranded
    ? normalizedTitle
    : `${normalizedTitle} | ${brandName}`;
}

function isProvidersDetailRoute(segments: string[]): boolean {
  return segments[0] === 'providers'
    && segments.length === 2
    && segments[1] !== 'new';
}

export function resolveDocumentTitle(
  pathname: string,
  labels: RouteTitleLabels,
  brandName: string,
  context: RouteTitleContext = {},
): string {
  const normalizedPath = normalizePathname(pathname);
  if (normalizedPath === '/') {
    return brandName;
  }

  const segments = normalizedPath.split('/').filter(Boolean);
  if (segments.length === 0) {
    return brandName;
  }

  if (segments[0] === 'welcome') {
    return labels.welcome.trim() || brandName;
  }

  if (segments[0] === 'chat' && segments[1] === 'folder') {
    return formatDocumentTitle(context.folderName?.trim() || labels.folder, brandName);
  }

  if (segments[0] === 'chat') {
    return formatDocumentTitle(labels.chat, brandName);
  }

  if (segments[0] === 'providers' && segments[1] === 'new') {
    return formatDocumentTitle(labels.providerSetup, brandName);
  }

  if (segments[0] === 'providers' && segments[1] === 'relay' && segments[2] === 'new') {
    return formatDocumentTitle(labels.relaySetup, brandName);
  }

  if (segments[0] === 'providers' && segments[2] === 'manual-model') {
    return formatDocumentTitle(labels.manualModel, brandName);
  }

  if (isProvidersDetailRoute(segments)) {
    return formatDocumentTitle(context.providerName?.trim() || labels.providerList, brandName);
  }

  if (segments[0] === 'providers') {
    return formatDocumentTitle(labels.providerList, brandName);
  }

  if (segments[0] === 'settings' && segments[1] === 'backup') {
    return formatDocumentTitle(labels.backup, brandName);
  }

  if (segments[0] === 'settings' && segments[1] === 'memory') {
    return formatDocumentTitle(labels.memory, brandName);
  }

  if (segments[0] === 'settings') {
    return formatDocumentTitle(labels.settings, brandName);
  }

  if (segments[0] === 'skills' && segments[1] === 'edit') {
    return formatDocumentTitle(labels.skillEdit, brandName);
  }

  if (segments[0] === 'skills') {
    return formatDocumentTitle(labels.skills, brandName);
  }

  return brandName;
}
