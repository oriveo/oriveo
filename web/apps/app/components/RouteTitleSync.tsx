'use client';

import { useEffect, useMemo } from 'react';
import { usePathname } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { Folder, Provider } from '@oriveo/shared';
import { brand, getProviderDisplayName } from '@oriveo/config';
import { useAppStore } from '../providers/StoreProvider';
import { resolveDocumentTitle, type RouteTitleKey } from '../lib/metadata/document-title';
import { sameNormalizedID } from '../lib/utils/id-utils';

function resolveProviderPageName(rawProviderId: string, providers: Provider[]): string | null {
  const provider = providers.find((item) => sameNormalizedID(item.id, rawProviderId));
  if (provider) {
    return provider.customName?.trim() || getProviderDisplayName(provider.kind);
  }

  if (sameNormalizedID(rawProviderId, '')) {
    return getProviderDisplayName(rawProviderId);
  }

  const knownDisplayName = getProviderDisplayName(rawProviderId);
  return knownDisplayName === rawProviderId ? null : knownDisplayName;
}

function resolveFolderPageName(rawFolderId: string, folders: Folder[]): string | null {
  const folder = folders.find((item) => sameNormalizedID(item.id, rawFolderId));
  return folder?.name?.trim() || null;
}

export function RouteTitleSync() {
  const pathname = usePathname() ?? '/';
  const providers = useAppStore((s) => s.providers);
  const folders = useAppStore((s) => s.folders);

  const tWelcome = useTranslations('pages.welcome');
  const tChat = useTranslations('pages.chat');
  const tProviderList = useTranslations('pages.providerList');
  const tProviderSetup = useTranslations('pages.providerSetup');
  const tRelaySetup = useTranslations('pages.relaySetup');
  const tManualModel = useTranslations('pages.manualModel');
  const tSettings = useTranslations('pages.settings');
  const tBackup = useTranslations('pages.backup');
  const tMemory = useTranslations('pages.memory');
  const tSkills = useTranslations('skills');
  const tSidebar = useTranslations('sidebar');

  const labels = useMemo<Record<RouteTitleKey, string>>(
    () => ({
      backup: tBackup('title'),
      chat: tChat('title'),
      folder: tSidebar('folders'),
      manualModel: tManualModel('title'),
      memory: tMemory('title'),
      providerList: tProviderList('title'),
      providerSetup: tProviderSetup('title'),
      relaySetup: tRelaySetup('title'),
      settings: tSettings('title'),
      skills: tSkills('title'),
      skillEdit: tSkills('editSkill'),
      welcome: tWelcome('title'),
    }),
    [
      tBackup,
      tChat,
      tManualModel,
      tMemory,
      tProviderList,
      tProviderSetup,
      tRelaySetup,
      tSettings,
      tSidebar,
      tSkills,
      tWelcome,
    ],
  );

  const titleContext = useMemo(() => {
    const segments = pathname.split('/').filter(Boolean);

    let providerName: string | null = null;
    let folderName: string | null = null;

    if (
      segments[0] === 'providers'
      && segments[1]
      && segments[1] !== 'new'
      && !(segments[1] === 'relay' && segments[2] === 'new')
      && segments[2] !== 'manual-model'
    ) {
      providerName = resolveProviderPageName(decodeURIComponent(segments[1]), providers);
    }

    if (segments[0] === 'chat' && segments[1] === 'folder' && segments[2]) {
      folderName = resolveFolderPageName(decodeURIComponent(segments[2]), folders);
    }

    return { providerName, folderName };
  }, [folders, pathname, providers]);

  useEffect(() => {
    document.title = resolveDocumentTitle(pathname, labels, brand.name, titleContext);
  }, [labels, pathname, titleContext]);

  return null;
}
