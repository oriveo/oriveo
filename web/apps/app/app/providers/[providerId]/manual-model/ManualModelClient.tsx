'use client';

import { useState, useCallback, useMemo } from 'react';
import { useRouter, useParams, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Button, Input } from '@oriveo/ui';
import { ProviderIcon } from '../../../../components/ProviderIcon';
import { getVanillaStore, useAppStore } from '../../../../providers/StoreProvider';
import { addManualProviderModels } from '../../../../lib/core/provider-model-ops';
import { getProviderInstanceDisplayName } from '../../../../lib/core/providers/provider-display';
import styles from './page.module.css';

export function ManualModelClient() {
  const router = useRouter();
  const params = useParams();
  const searchParams = useSearchParams();
  const providerId = params.providerId as string;
  const t = useTranslations('pages.manualModel');
  const tc = useTranslations('common');

  const providers = useAppStore((s) => s.providers);
  const setHasCompletedOnboarding = useAppStore((s) => s.setHasCompletedOnboarding);
  const provider = useMemo(() => providers.find((p) => p.id === providerId), [providers, providerId]);
  const providerLabel = useMemo(() => {
    if (!provider) return '';
    return getProviderInstanceDisplayName(provider);
  }, [provider]);

  const [modelId, setModelId] = useState('');

  const handleSave = useCallback(() => {
    const trimmed = modelId.trim();
    if (!trimmed || !provider) return;

    addManualProviderModels(getVanillaStore(), provider, [trimmed]);
    if (searchParams.get('context') === 'onboarding') {
      setHasCompletedOnboarding(true);
      router.push('/chat');
      return;
    }
    router.push(`/providers/${provider.id}`);
  }, [modelId, provider, router, searchParams, setHasCompletedOnboarding]);

  if (!provider) {
    return (
      <div className={styles.page}>
        <div className={styles.shell}>
          <div className={styles.card}>
            <p className={styles.notFoundText}>{t('providerNotFound')}</p>
            <Button tone="secondary" className={styles.singleButton} onClick={() => router.push('/providers')}>
              {tc('back')}
            </Button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.page}>
      <div className={styles.shell}>
        <div className={styles.hero}>
          <div className={styles.providerChip}>
            <ProviderIcon kind={provider.kind} size={18} bare />
            <span>{providerLabel}</span>
          </div>
          <h1 className={styles.title}>{t('title')}</h1>
          <p className={styles.description}>
            {t('description', { provider: providerLabel })}
          </p>
        </div>

        <div className={styles.card}>
          <Input
            className={styles.inputField}
            label={t('modelIdLabel')}
            placeholder={t('modelIdPlaceholder')}
            value={modelId}
            onChange={(e) => setModelId(e.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                handleSave();
              }
            }}
            autoFocus
          />

          <div className={styles.actions}>
            <Button
              className={styles.primaryButton}
              onClick={handleSave}
              disabled={!modelId.trim()}
            >
              {t('saveAndChat')}
            </Button>
            <Button
              tone="secondary"
              className={styles.secondaryButton}
              onClick={() => router.back()}
            >
              {tc('back')}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
