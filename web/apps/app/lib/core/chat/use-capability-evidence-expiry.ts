import { useEffect, useMemo, useState } from 'react';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamOptions } from '../providers/types';
import { nextCapabilityEvidenceExpiry } from './capability-evidence';

export interface CapabilityEvidenceExpiryTarget {
  provider: Provider;
  model: AIModel;
  streamOptions?: StreamOptions;
}

interface ExpiryRegistration {
  expiresAt: number;
  onExpire: () => void;
}

const registrations = new Map<number, ExpiryRegistration>();
let nextRegistrationId = 1;
let scheduledTimer: number | undefined;

/**
 * Re-renders a consumer precisely when its currently visible evidence reaches
 * TTL. Request paths never depend on this tick: they resolve the facade again
 * at dispatch time. The hook only prevents a static UI from showing a stale
 * positive verdict until an unrelated render happens.
 */
export function useCapabilityEvidenceExpiry(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  streamOptions?: StreamOptions,
): number {
  const targets = useMemo(
    () => provider && model ? [{ provider, model, streamOptions }] : [],
    [provider, model, streamOptions],
  );
  return useCapabilityEvidenceCollectionExpiry(targets);
}

/**
 * One subscription for an arbitrary model collection. All hook instances
 * share the module scheduler, which keeps exactly one nearest-expiry timer.
 */
export function useCapabilityEvidenceCollectionExpiry(
  targets: readonly CapabilityEvidenceExpiryTarget[],
): number {
  const [tick, setTick] = useState(0);
  // Collection callers keep `targets` referentially stable. Re-scan only when
  // that collection changes or the previous nearest expiry fires; unrelated
  // search/expand renders must not rebuild 810 model queries and candidates.
  const expiresAt = useMemo(() => nextCollectionExpiry(targets), [targets, tick]);
  useEffect(() => {
    if (!expiresAt) return;
    return registerCapabilityEvidenceExpiry(
      expiresAt,
      () => setTick((current) => current + 1),
    );
  }, [expiresAt]);
  return tick;
}

function nextCollectionExpiry(targets: readonly CapabilityEvidenceExpiryTarget[]): number | undefined {
  let earliest: number | undefined;
  for (const target of targets) {
    const expiresAt = nextCapabilityEvidenceExpiry(target);
    if (expiresAt && (earliest === undefined || expiresAt < earliest)) earliest = expiresAt;
  }
  return earliest;
}

function registerCapabilityEvidenceExpiry(expiresAt: number, onExpire: () => void): () => void {
  const id = nextRegistrationId++;
  registrations.set(id, { expiresAt, onExpire });
  rescheduleNearestExpiry();
  return () => {
    registrations.delete(id);
    rescheduleNearestExpiry();
  };
}

function rescheduleNearestExpiry(): void {
  if (scheduledTimer !== undefined) {
    window.clearTimeout(scheduledTimer);
    scheduledTimer = undefined;
  }
  let earliest: number | undefined;
  for (const registration of registrations.values()) {
    if (earliest === undefined || registration.expiresAt < earliest) {
      earliest = registration.expiresAt;
    }
  }
  if (earliest === undefined) return;
  scheduledTimer = window.setTimeout(
    flushExpiredRegistrations,
    Math.min(2_147_483_647, Math.max(0, earliest - Date.now()) + 1),
  );
}

function flushExpiredRegistrations(): void {
  scheduledTimer = undefined;
  const now = Date.now();
  const callbacks: Array<() => void> = [];
  for (const [id, registration] of registrations) {
    if (registration.expiresAt > now) continue;
    registrations.delete(id);
    callbacks.push(registration.onExpire);
  }
  rescheduleNearestExpiry();
  for (const callback of callbacks) callback();
}

export function __resetCapabilityEvidenceExpirySchedulerForTest(): void {
  if (scheduledTimer !== undefined && typeof window !== 'undefined') {
    window.clearTimeout(scheduledTimer);
  }
  scheduledTimer = undefined;
  registrations.clear();
  nextRegistrationId = 1;
}
