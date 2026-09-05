'use client';

import { useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Button } from '@oriveo/ui';
import { useAppStore } from '../../../providers/StoreProvider';
import { RelayDetail } from './RelayDetail';
import { OfficialProviderDetail } from './OfficialProviderDetail';
import { sameNormalizedID } from '../../../lib/utils/id-utils';
import styles from './ProviderDetail.module.css';

interface ProviderDetailRouterProps {
  providerId: string;
}

export function ProviderDetailRouter({ providerId }: ProviderDetailRouterProps) {
  const router = useRouter();
  const t = useTranslations('pages.providerDetail');
  const tc = useTranslations('common');
  const providers = useAppStore((s) => s.providers);

  const provider = useMemo(
    () => providers.find((p) => sameNormalizedID(p.id, providerId)),
    [providers, providerId],
  );

  if (!provider) {
    return (
      <div className={styles.page}>
        <p>{t('notFound')}</p>
        <Button onClick={() => router.push('/providers')}>{tc('back')}</Button>
      </div>
    );
  }

  if (provider.kind === 'relay') {
    return <RelayDetail provider={provider} />;
  }

  return <OfficialProviderDetail provider={provider} />;
}
