import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';
import { updateProviderRelaySettings } from '../provider-ops';
import { readPartitionedStore, writePartitionedStore } from '../../infra/storage/partitioned-local-store';
import { resolveRelayRuntimeFields } from './relay-resolution';

/**
 * One-time switch of existing llama.cpp native-channel connections to the chat channel (shared contract localEngineRules.llamacppMigration).
 *
 * The Web creation flow always uses the chat channel, but connections saved earlier may still be on the native channel,
 * so this runs once at startup. The marker is partitioned per uid: it runs once per browser and profile, after which a native channel
 * chosen by hand is never rewritten again.
 */
const MIGRATION_FLAG_KEY = 'llamacppChatChannelMigration.v1';

export interface LlamacppChannelSnapshot {
  engineProfile?: string | null;
  transport?: string | null;
  resolvedAPIBaseURL?: string | null;
}

export function planLlamacppChannelMigration(input: LlamacppChannelSnapshot, alreadyMigrated: boolean) {
  const transport = input.transport ?? null;
  const resolvedAPIBaseURL = input.resolvedAPIBaseURL ?? null;
  if (alreadyMigrated || input.engineProfile !== 'llamacpp' || transport !== 'llamacpp_native') {
    return { transport, resolvedAPIBaseURL, changed: false };
  }
  // With an empty address only the channel is switched: the runtime-derived address equals the result of appending /v1, and writing the derived value back would turn "not filled in" into "filled in".
  const trimmed = resolvedAPIBaseURL?.trim().replace(/\/+$/, '');
  return {
    transport: 'openai_chat_completions',
    resolvedAPIBaseURL: trimmed ? (trimmed.endsWith('/v1') ? trimmed : `${trimmed}/v1`) : resolvedAPIBaseURL,
    changed: true,
  };
}

export async function migrateLlamacppConnectionsToChatChannelIfNeeded(store: StoreApi<AppStore>): Promise<void> {
  if (readPartitionedStore(MIGRATION_FLAG_KEY) === 'done') return;
  for (const provider of store.getState().providers) {
    const requested = provider.relayRequested;
    if (provider.kind !== 'relay' || !requested) continue;
    const plan = planLlamacppChannelMigration(requested, false);
    if (!plan.changed) continue;
    const relayRequested = {
      ...requested,
      transport: 'openai_chat_completions' as const,
      resolvedAPIBaseURL: plan.resolvedAPIBaseURL ?? undefined,
    };
    // Go through the same entry the user uses to edit a connection: persists as usual and advances the capability evidence identity. Saved parameter values are untouched.
    await updateProviderRelaySettings(store, provider, {
      relayKind: provider.relayKind,
      relayRequested,
      ...resolveRelayRuntimeFields({ baseURLText: provider.baseURLText, relayRequested }),
    });
  }
  writePartitionedStore(MIGRATION_FLAG_KEY, 'done');
}
