"use client";

import { useSyncExternalStore } from 'react';
import { getRelayAvatarChoice, subscribeRelayAvatarChoices } from '../core/providers/relay-avatar-choices';

/** Subscribes to one connection's on-device avatar choice; always undefined without a connection id. */
export function useRelayAvatarChoice(providerId: string | null | undefined): string | undefined {
  return useSyncExternalStore(
    subscribeRelayAvatarChoices,
    () => getRelayAvatarChoice(providerId),
    () => undefined,
  );
}
