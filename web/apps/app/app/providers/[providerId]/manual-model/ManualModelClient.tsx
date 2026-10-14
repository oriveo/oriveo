'use client';

import { useState, useCallback, useMemo } from 'react';
import { useRouter, useParams, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { XCircle } from '@phosphor-icons/react';
import { BackButton, Button } from '@oriveo/ui';
import { getVanillaStore, useAppStore } from '../../../../providers/StoreProvider';
import { addManualProviderModels } from '../../../../lib/core/provider-model-ops';
import { getProviderInstanceDisplayName } from '../../../../lib/core/providers/provider-display';
import { relayFlagshipModelID } from '../../relay/new/manual-setup-board';
import styles from './page.module.css';

/**
 * Manually add model (ManualModel board): relay and official providers share one page and the same layout: header back button + centered title,
 * the content is just one input slot and the note under it. The relay placeholder is the delivered flagship model ID; official mode keeps this app's existing copy and save destination.
 */
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

  const [modelId, setModelId] = useState('');
  const isRelay = provider?.kind === 'relay';

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
          <p className={styles.notFoundText}>{t('providerNotFound')}</p>
          <Button tone="secondary" className={styles.primaryButton} onClick={() => router.push('/providers')}>
            {tc('back')}
          </Button>
        </div>
      </div>
    );
  }

  const label = t('modelIdLabel');
  return (
    <div className={styles.page}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <BackButton className={styles.backButton} label={tc('back')} onClick={() => router.back()} />
          <h1 className={styles.title}>{isRelay ? t('addModelTitle') : t('fallbackTitle')}</h1>
        </header>

        {/* The visible subheading is for sighted users only; screen readers already read the same sentence from the input's aria-label, avoiding double reading. */}
        <p className={styles.slotCaption} aria-hidden="true">{label}</p>
        <div className={styles.slot} data-manual-model-section="modelSlot">
          <input
            className={styles.slotInput}
            aria-label={label}
            placeholder={isRelay ? relayFlagshipModelID() : t('modelIdPlaceholder')}
            value={modelId}
            // The model ID runs left to right even in RTL languages; the localized placeholder of official mode follows the UI direction.
            dir={isRelay || modelId ? 'ltr' : undefined}
            onChange={(event) => setModelId(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                handleSave();
              }
            }}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            autoFocus
          />
          {modelId ? (
            <button
              type="button"
              className={styles.clearButton}
              onClick={() => setModelId('')}
              aria-label={t('clear')}
            >
              <XCircle size={18} weight="fill" aria-hidden="true" />
            </button>
          ) : null}
        </div>

        <div className={styles.notes} data-manual-model-section="notes">
          {isRelay ? (
            <>
              <p>{t('relayModelNote')}</p>
              <p>{t('relayCapabilityNote')}</p>
            </>
          ) : (
            <p>{t('description', { provider: getProviderInstanceDisplayName(provider) })}</p>
          )}
        </div>

        <div className={styles.actions}>
          <Button className={styles.primaryButton} onClick={handleSave} disabled={!modelId.trim()}>
            {isRelay ? tc('save') : t('saveAndChat')}
          </Button>
        </div>
      </div>
    </div>
  );
}
