'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { ChatView } from '../../../components/chat/ChatView';
import { ContextSettingsPage } from '../../settings/context/ContextSettingsPage';
import { relayShotsFenceInstalled } from '../relay-shots/relay-shots-fence';
import {
  applyContextShotPlan,
  contextShotPlan,
  loadContextShotsMetadata,
  raiseContextShotConfirm,
  type ContextShotPlan,
  type ContextShotsManifest,
} from './context-shots-data';
import type { ContextShotPage } from './context-shots-pages';

type ShotState = { kind: 'preparing' } | { kind: 'refused' } | { kind: 'ready'; plan: ContextShotPlan };

const DRIVE_TIMEOUT_MS = 10_000;

/**
 * Wait until an element appears (data-testid / aria-label of the production page); returns null on timeout.
 * match is an optional second filter (for example by button text).
 */
function waitForElement<T extends Element>(
  selector: string,
  signal: { cancelled: boolean },
  match?: (element: T) => boolean,
): Promise<T | null> {
  const startedAt = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      if (signal.cancelled) return resolve(null);
      const element = [...document.querySelectorAll<T>(selector)].find((candidate) => !match || match(candidate));
      if (element) return resolve(element);
      if (Date.now() - startedAt > DRIVE_TIMEOUT_MS) {
        console.warn(`[context-shots] timed out waiting for ${selector}`);
        return resolve(null);
      }
      window.setTimeout(tick, 50);
    };
    tick();
  });
}

/** Fixed clock: Date.now runs from the manifest moment (only inside the sample page, restored on unmount). */
function pinClock(clockMs: number): () => void {
  const realNow = Date.now.bind(Date);
  const offset = clockMs - realNow();
  Date.now = () => realNow() + offset;
  return () => {
    Date.now = realNow;
  };
}

/** ThemeInitScript hard-codes dark when there is no preference: sample pages set the theme from the system appearance (the tool's --appearance). */
function followSystemAppearance(): () => void {
  const query = window.matchMedia('(prefers-color-scheme: dark)');
  const apply = () => {
    document.documentElement.dataset.theme = query.matches ? 'dark' : 'light';
  };
  apply();
  query.addEventListener('change', apply);
  return () => query.removeEventListener('change', apply);
}

export function ContextShotsClient({ page, manifest }: { page: ContextShotPage; manifest: ContextShotsManifest }) {
  const [state, setState] = useState<ShotState>({ kind: 'preparing' });
  const tChat = useTranslations('pages.chat');
  const settingsLabel = tChat('conversationSettings.title');
  const usageLabel = tChat('conversationSettings.usage');

  useEffect(() => {
    // When navigating in client-side from another page, StoreProvider has long since hydrated and subscribed to persistence on the normal path: refuse to open and require a full page refresh.
    if (!relayShotsFenceInstalled()) {
      console.error('[context-shots] isolation fence is not installed; refusing to open. Reload this URL directly.');
      setState({ kind: 'refused' });
      return;
    }
    const signal = { cancelled: false };
    const plan = contextShotPlan(page, manifest);
    const restoreClock = pinClock(plan.clockMs);
    const stopAppearance = followSystemAppearance();
    const metadata: { restore: (() => void) | null } = { restore: null };
    void (async () => {
      metadata.restore = await loadContextShotsMetadata(manifest);
      if (signal.cancelled) {
        metadata.restore();
        return;
      }
      await applyContextShotPlan(plan, getVanillaStore());
      if (!signal.cancelled) setState({ kind: 'ready', plan });
    })();
    return () => {
      signal.cancelled = true;
      metadata.restore?.();
      stopAppearance();
      restoreClock();
    };
  }, [page, manifest]);

  // Layers stacked after entering: always opened by tapping the production button (the panel is reached through the usage row in conversation settings and opens even without a ring when the window is unknown);
  // the confirm dialog is suspended through the production send gate gateCapConfirm -> requestCapConfirmation.
  useEffect(() => {
    if (state.kind !== 'ready' || state.plan.target !== 'chat' || state.plan.open === null) return;
    const { plan } = state;
    const signal = { cancelled: false };
    const abort = new AbortController();
    const click = async <T extends HTMLElement>(selector: string, match?: (element: T) => boolean) => {
      const element = await waitForElement<T>(selector, signal, match);
      element?.click();
      return element !== null;
    };
    const openSettings = () => click<HTMLButtonElement>(`button[aria-label="${CSS.escape(settingsLabel)}"]`);
    const openPanel = async () =>
      (await openSettings())
      && click<HTMLButtonElement>(
        '[role="dialog"] button',
        (button) => button.querySelector('span')?.textContent === usageLabel,
      );
    void (async () => {
      switch (plan.open) {
        case 'detail':
          await click('[data-testid="compaction-separator"]');
          break;
        case 'conversationSettings':
          await openSettings();
          break;
        case 'panel':
          await openPanel();
          break;
        case 'picker':
          if (await openPanel()) await click('[data-testid="chat-context-cap-row"]');
          break;
        case 'confirm':
          // The suspended request lives in the store and the ChatView confirm dialog reads it by current conversation; unmounting aborts it (settled as cancel).
          await raiseContextShotConfirm(plan, getVanillaStore(), abort.signal);
          break;
        default:
          break;
      }
    })();
    return () => {
      signal.cancelled = true;
      abort.abort();
    };
  }, [state, settingsLabel, usageLabel]);

  if (state.kind === 'refused') {
    return <p data-relay-shots-refused>Context shots: isolation unavailable. Reload this URL directly.</p>;
  }
  if (state.kind === 'preparing') return null;
  // Settings page (Settings > Context): render the production page directly, no conversation page.
  if (state.plan.target === 'settings') return <ContextSettingsPage />;
  return <ChatView conversationId={state.plan.conversationId ?? undefined} />;
}
