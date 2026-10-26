'use client';

import { useEffect, useState } from 'react';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { safeLocalStorage } from '../../../lib/infra/storage/web-storage';
import { waitForElement } from '../../../lib/dev/shots-driver';
import { MemoryPage } from '../../settings/memory/MemoryPage';
import { MemoryInboxPage } from '../../settings/memory/MemoryInboxPage';
import { relayShotsFenceInstalled } from '../relay-shots/relay-shots-fence';
import { applyMemoryShotPlan, memoryShotPlan, type MemoryShotDrive, type MemoryShotPlan, type MemoryShotsManifest } from './memory-shots-data';
import type { MemoryShotPage } from './memory-shots-pages';

type ShotState = { kind: 'preparing' } | { kind: 'refused' } | { kind: 'ready'; plan: MemoryShotPlan };

/** The key read by production getOrCreateStableWebDeviceId (an in-memory table under the fence). */
const WEB_SYNC_DEVICE_ID_KEY = 'oriveo.sync.deviceId';

async function drive(step: MemoryShotDrive, signal: { cancelled: boolean }): Promise<void> {
  if (step.kind !== 'rawTooLong') return;
  (await waitForElement<HTMLButtonElement>('[data-testid="memory-raw-toggle"]', signal, { label: 'memory-shots' }))?.click();
  const textarea = await waitForElement<HTMLTextAreaElement>('[data-testid="memory-raw-textarea"]', signal, { label: 'memory-shots' });
  if (!textarea) return;
  // Go through the native setter of the React controlled input, then dispatch an input event, so the production onChange receives it as usual.
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(textarea, step.text);
  textarea.dispatchEvent(new Event('input', { bubbles: true }));
  (await waitForElement<HTMLButtonElement>('[data-testid="memory-raw-save"]', signal, { label: 'memory-shots' }))?.click();
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

export function MemoryShotsClient({ page, manifest }: { page: MemoryShotPage; manifest: MemoryShotsManifest }) {
  const [state, setState] = useState<ShotState>({ kind: 'preparing' });

  useEffect(() => {
    // When navigating in client-side from another page, StoreProvider has long since hydrated and subscribed to persistence on the normal path: refuse to open and require a full page refresh.
    if (!relayShotsFenceInstalled()) {
      console.error('[memory-shots] isolation fence is not installed; refusing to open. Reload this URL directly.');
      setState({ kind: 'refused' });
      return;
    }
    const signal = { cancelled: false };
    const plan = memoryShotPlan(page, manifest);
    const restoreClock = pinClock(plan.clockMs);
    const stopAppearance = followSystemAppearance();
    safeLocalStorage.setItem(WEB_SYNC_DEVICE_ID_KEY, plan.deviceId);
    window.history.replaceState(window.history.state, '', `${window.location.pathname}${plan.query}`);
    void applyMemoryShotPlan(plan, getVanillaStore()).then(() => {
      if (!signal.cancelled) setState({ kind: 'ready', plan });
    });
    return () => {
      signal.cancelled = true;
      stopAppearance();
      restoreClock();
    };
  }, [page, manifest]);

  useEffect(() => {
    if (state.kind !== 'ready' || state.plan.drive.kind === 'none') return;
    const signal = { cancelled: false };
    void drive(state.plan.drive, signal);
    return () => {
      signal.cancelled = true;
    };
  }, [state]);

  if (state.kind === 'refused') {
    return <p data-relay-shots-refused>Memory shots: isolation unavailable. Reload this URL directly.</p>;
  }
  if (state.kind === 'preparing') return null;
  return state.plan.target === 'inbox' ? <MemoryInboxPage /> : <MemoryPage />;
}
