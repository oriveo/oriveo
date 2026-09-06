'use client';

import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Button, OriveoLogo } from '@oriveo/ui';
import { useAppStore } from '../../providers/StoreProvider';
import { resolveEntryRoute } from '../../lib/utils/entry-route';
import { trackEvent } from '../../lib/core/telemetry';
import { LocaleMenu } from './LocaleMenu';
import { ThemeToggle } from '../../components/ThemeToggle';
import styles from './Welcome.module.css';

export function Welcome() {
  const router = useRouter();
  const t = useTranslations('pages.welcome');
  const providers = useAppStore((s) => s.providers);
  const setHasCompletedOnboarding = useAppStore((s) => s.setHasCompletedOnboarding);

  const onboardingStartRef = useRef<number>(Date.now());
  const onboardingCompletedRef = useRef(false);
  const stepViewedRef = useRef(false);
  const hasProviderSetup = providers.length > 0;

  useEffect(() => {
    if (stepViewedRef.current) return;
    stepViewedRef.current = true;
    trackEvent('onboarding_step_viewed', {
      step: 'welcome',
      step_index: 0,
    });
  }, []);

  function markOnboardingCompleted(source: string) {
    if (onboardingCompletedRef.current) return;
    onboardingCompletedRef.current = true;
    setHasCompletedOnboarding(true);
    trackEvent('onboarding_completed', {
      duration_ms: Date.now() - onboardingStartRef.current,
      skipped_provider_setup: !hasProviderSetup,
      source,
    });
  }

  function goProviders() {
    markOnboardingCompleted('byok_providers');
    router.push('/providers/new');
  }

  function enterApp() {
    markOnboardingCompleted('enter_home');
    router.replace(
      resolveEntryRoute({
        hasCompletedOnboarding: true,
        providerCount: providers.length,
      }),
    );
  }

  return (
    <div className={styles.page}>
      <div className={styles.grain} aria-hidden="true" />
      <ThemeToggle className={styles.themeToggle} />
      <LocaleMenu />
      <div className={styles.container}>
        <div className={styles.logoWrap}>
          <OriveoLogo size={112} withGlow />
        </div>

        <h1 className={styles.tagline}>{t('tagline')}</h1>
        <p className={styles.subtitle}>{t('slogan')}</p>
        <p className={styles.privacy}>{t('description')}</p>

        <div className={styles.actions}>
          <Button className={styles.ctaBtn} onClick={goProviders}>
            {t('addProvider')}
          </Button>
          <Button tone="secondary" className={styles.ctaBtn} onClick={enterApp}>
            {t('enterHome')}
          </Button>
        </div>
      </div>
    </div>
  );
}
