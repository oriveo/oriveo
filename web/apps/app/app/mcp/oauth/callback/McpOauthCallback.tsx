'use client';

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import {
  collectCallbackParams,
  deliverCallbackResult,
  scrubCallbackUrl,
  type OauthCallbackDelivery,
} from './callback-handoff';
import styles from './McpOauthCallback.module.css';

/**
 * Three presentations (see callback-handoff.ts for the handoff protocol):
 *   - during the short wait for the acknowledgement: nothing is rendered;
 *   - a starting page claimed the result: shows "done, you can close this page" and tries to close
 *     itself (a script can only close a window a script opened; when it cannot, that sentence is
 *     what the user reads);
 *   - no page claimed it (the tab that started the sign-in has been closed or reloaded): says
 *     "please return to the app".
 */
export function McpOauthCallback() {
  const t = useTranslations('mcp.oauthCallback');
  const [delivery, setDelivery] = useState<OauthCallbackDelivery | null>(null);
  // Hand off only once. The address bar is cleared after the first read, so if the effect runs again
  // (strict mode in development does that) it reads empty parameters and would overwrite a
  // successful handoff with "please return to the app".
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    // Read the address bar directly instead of useSearchParams: the address bar is changed right
    // below, and that must not trigger a re-render in turn.
    const params = collectCallbackParams(window.location.search);
    scrubCallbackUrl(window);

    void deliverCallbackResult({
      params,
      origin: window.location.origin,
      opener: window.opener as Window | null,
      messageTarget: window,
    }).then((outcome) => {
      setDelivery(outcome);
      if (outcome === 'claimed') window.close();
    });
  }, []);

  if (delivery === null) return null;

  if (delivery === 'claimed') {
    return (
      <main className={styles.page}>
        <h1 className={styles.title}>{t('completed')}</h1>
        <p className={styles.description}>{t('completedDescription')}</p>
      </main>
    );
  }

  return (
    <main className={styles.page}>
      <h1 className={styles.title}>{t('returnToApp')}</h1>
      <p className={styles.description}>{t('returnToAppDescription')}</p>
    </main>
  );
}
