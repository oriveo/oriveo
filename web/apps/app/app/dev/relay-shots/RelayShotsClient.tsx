'use client';

import { useEffect, useState } from 'react';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { setRelayShotSeed } from '../../../lib/dev/relay-shots-mode';
import { safeLocalStorage } from '../../../lib/infra/storage/web-storage';
import { ProviderDetailRouter } from '../../providers/[providerId]/ProviderDetailRouter';
import { RelaySetup } from '../../providers/relay/new/RelaySetup';
import { RelayModelOptionsHost } from './RelayModelOptionsHost';
import { relayShotsFenceInstalled } from './relay-shots-fence';
import { prepareRelayShot, type RelayShotDrive, type RelayShotPlan, type ShotsManifest } from './relay-shots-data';
import type { RelayShotPage } from './relay-shots-pages';

type ShotState = { kind: 'preparing' } | { kind: 'refused' } | { kind: 'ready'; plan: RelayShotPlan };

const DRIVE_TIMEOUT_MS = 10_000;

/** Wait until an element appears (a data-testid / id the production page already carries); returns null on timeout. */
function waitForElement<T extends Element>(selector: string, signal: { cancelled: boolean }): Promise<T | null> {
  const startedAt = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      if (signal.cancelled) return resolve(null);
      const element = document.querySelector<T>(selector);
      if (element && !(element as unknown as HTMLButtonElement).disabled) return resolve(element);
      if (Date.now() - startedAt > DRIVE_TIMEOUT_MS) {
        console.warn(`[relay-shots] timed out waiting for ${selector}`);
        return resolve(null);
      }
      window.setTimeout(tick, 50);
    };
    tick();
  });
}

async function drive(kind: RelayShotDrive, signal: { cancelled: boolean }): Promise<void> {
  if (kind === 'detect') {
    // Step 1 has the address and key filled in -> click Next; the fake relay answers the catalog and step 2 opens automatically.
    (await waitForElement<HTMLButtonElement>('[data-testid="relay_setup_next_button"]', signal))?.click();
    return;
  }
  if (kind === 'manualSubmit') {
    // Manual setup: click "Verify and save" -> the fake relay answers 401 -> the production page dismisses the keyboard and scrolls to the failure card (same as iOS / Android; shots no longer steal focus).
    (await waitForElement<HTMLButtonElement>('[data-testid="relay_manual_setup_primary_button"]', signal))?.click();
  }
}

export function RelayShotsClient({ page, manifest }: { page: RelayShotPage; manifest: ShotsManifest }) {
  const [state, setState] = useState<ShotState>({ kind: 'preparing' });

  useEffect(() => {
    // When entered by client-side navigation from another page, StoreProvider has already hydrated and subscribed persistence the normal way: refuse to open and require a full page reload.
    if (!relayShotsFenceInstalled()) {
      console.error('[relay-shots] isolation fence is not installed; refusing to open. Reload this URL directly.');
      setState({ kind: 'refused' });
      return;
    }
    const signal = { cancelled: false };
    void prepareRelayShot(page, manifest, getVanillaStore()).then((plan) => {
      if (signal.cancelled) return;
      // Written through the single entry point; in shots mode the fence has already swapped localStorage for an in-memory table.
      for (const [key, value] of Object.entries(plan.localStorage)) safeLocalStorage.setItem(key, value);
      setRelayShotSeed(plan.seed);
      if (plan.target.kind === 'detail') {
        window.history.replaceState(window.history.state, '', `${window.location.pathname}${plan.target.query}`);
      }
      setState({ kind: 'ready', plan });
    });
    return () => {
      signal.cancelled = true;
    };
  }, [page, manifest]);

  useEffect(() => {
    if (state.kind !== 'ready' || state.plan.drive === 'none') return;
    const signal = { cancelled: false };
    void drive(state.plan.drive, signal);
    return () => {
      signal.cancelled = true;
    };
  }, [state]);

  if (state.kind === 'refused') {
    return <p data-relay-shots-refused>Relay shots: isolation unavailable. Reload this URL directly.</p>;
  }
  if (state.kind === 'preparing') return null;
  const { target } = state.plan;
  if (target.kind === 'modelOptions') return <RelayModelOptionsHost providerId={target.providerId} modelId={target.modelId} />;
  return target.kind === 'detail'
    ? <ProviderDetailRouter providerId={target.providerId} />
    : <RelaySetup />;
}
