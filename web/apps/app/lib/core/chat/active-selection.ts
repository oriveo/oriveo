import type { AIModel, Conversation, LastUsedModelRef, Provider } from '@oriveo/shared';
import { sameNormalizedID } from '../../utils/id-utils';
import type { AppStore } from '../store/app-store';
import { createProviderSelectionSnapshot, resolveProviderModelRetirement } from '../providers/provider-selection-snapshot';
import { getEffectiveStatusKind } from '../providers/provider-status';
import {
  resolveConversationModelRemoval,
  type ConversationModelRemoval,
  type ModelRetirement,
} from './conversation-model-status';

export interface ActiveSelection {
  provider: Provider | undefined;
  currentModel: AIModel | undefined;
  /** The relay session model has been removed: currentModel is empty here, and the send entry returns with zero requests accordingly. */
  modelRemoval?: ConversationModelRemoval;
  /** The official session model is retired or missing (retirement contract): currentModel is empty here, and the send entry returns with zero requests. */
  modelRetirement?: ModelRetirement;
  /** Set to last_used_retired when the preferred model of a new chat (last used / user default) is retired and the catalog default is used instead; never given for existing conversations. */
  defaultModelHint?: 'last_used_retired' | null;
  /** Given together with defaultModelHint: the preferred model id that was not used (the hint dedupe is keyed on it and the provider). */
  unusedPreferredModelId?: string | null;
  /**
   * The connection the conversation is bound to is no longer among the current connections: provider and currentModel are both empty,
   * and it does not fall through to selected / lastUsed / the first connection; the UI shows a "connection removed" banner plus model
   * selection, and sending is disabled. The stored provider / model of the conversation stay untouched; only a user selection
   * (updateConversationModel) rewrites them.
   */
  connectionRemoved?: ConnectionRemoval;
}

export interface ConnectionRemoval {
  /** The (removed) connection id stored in the conversation */
  providerId: string;
  /** The model id stored in the conversation */
  modelId: string;
}

/**
 * UI verdict of the "connection removed" banner (contract key banner.connection_removed, action choose_model):
 * while usable connections remain, "choose model" opens the model switcher; with no connection at all it goes to the add-connection path. Sending is always disabled while the banner shows.
 */
export interface ConnectionRemovedPrompt {
  banner: 'banner.connection_removed';
  action: 'choose_model';
  target: 'model_switcher' | 'connection_setup';
  sendAllowed: false;
}

export function resolveConnectionRemovedPrompt(
  selection: Pick<ActiveSelection, 'connectionRemoved'>,
  connectionCount: number,
): ConnectionRemovedPrompt | null {
  if (!selection.connectionRemoved) return null;
  return {
    banner: 'banner.connection_removed',
    action: 'choose_model',
    target: connectionCount > 0 ? 'model_switcher' : 'connection_setup',
    sendAllowed: false,
  };
}

/**
 * "Connection removed" is judgeable = the local connection list has loaded.
 * Otherwise it stays pending: no banner, no fallback to another connection, and sending gives a reason.
 */
export function selectConnectionRemovalJudgeable(
  state: Pick<AppStore, 'providersHydrated'>,
): boolean {
  return state.providersHydrated;
}

/**
 * Returns a verdict when the conversation is bound to a connection that is not among the current ones; null when unbound, when the connection still exists, or when not judgeable (connectionsJudgeable is false).
 */
export function resolveConnectionRemoval(
  provider: Provider | undefined,
  conversation: Pick<Conversation, 'providerID' | 'modelID'>,
  connectionsJudgeable: boolean,
): ConnectionRemoval | null {
  // List not loaded yet: being absent from the list does not mean removed.
  if (!connectionsJudgeable) return null;
  const providerId = conversation.providerID?.trim();
  if (!providerId || provider) return null;
  return { providerId, modelId: conversation.modelID ?? '' };
}

/**
 * Resolve the provider and model in effect for the current ChatView:
 * conversation binding > the selected value the user switched to > the last used
 * lastUsedModelRef > the first provider as a fallback.
 * A pure function with no React dependency, so a focused unit test can pin the four-level fallback order.
 */
export function resolveActiveSelection(
  runtimeProviders: Provider[],
  conversation: Conversation | undefined,
  selectedProviderId: string | null,
  selectedModelId: string | null,
  lastUsedModelRef: LastUsedModelRef | null,
  connectionsJudgeable: boolean,
): ActiveSelection {
  if (conversation) {
    const p = runtimeProviders.find((pr) => sameNormalizedID(pr.id, conversation.providerID));
    // The conversation connection was removed: do not silently switch to another connection and do not rewrite the conversation; leave it to the banner so the user picks a model.
    // Only a conversation that is not bound to a connection yet (empty providerID) falls through by the new-conversation rules.
    const connectionRemoval = resolveConnectionRemoval(p, conversation, connectionsJudgeable);
    if (connectionRemoval) {
      return { provider: undefined, currentModel: undefined, connectionRemoved: connectionRemoval };
    }
    // The bound connection is not in the list but does not count as removed (the list has not loaded): do not fall back to another connection,
    // provider stays empty and the send entry's existing provider_missing guard blocks it.
    const boundProviderId = conversation.providerID?.trim();
    if (!p && boundProviderId && !connectionsJudgeable) {
      return { provider: undefined, currentModel: undefined };
    }
    // Session model removed: do not silently swap in the fallback model and do not rewrite the session model; leave it to the banner so the user reselects.
    const modelRemoval = resolveConversationModelRemoval(p, conversation.modelID);
    if (p && modelRemoval) {
      return { provider: p, currentModel: undefined, modelRemoval };
    }
    // Same rule for official connections: a verdict other than available does not fall through to selected / lastUsed / the first provider.
    const modelRetirement = resolveProviderModelRetirement(p, conversation.modelID);
    if (p && modelRetirement && modelRetirement.status !== 'available') {
      return { provider: p, currentModel: undefined, modelRetirement };
    }
    const snapshot = createProviderSelectionSnapshot(p, {
      requestedModelId: conversation.modelID,
      lastUsedModelRef,
    });
    if (snapshot) {
      return {
        provider: snapshot.provider,
        currentModel: snapshot.currentModel ?? undefined,
      };
    }
  }
  if (selectedProviderId) {
    const p = runtimeProviders.find((pr) => sameNormalizedID(pr.id, selectedProviderId));
    const snapshot = createProviderSelectionSnapshot(p, {
      preferredModelId: selectedModelId,
      lastUsedModelRef,
    });
    if (snapshot) {
      return {
        provider: snapshot.provider,
        currentModel: snapshot.currentModel ?? undefined,
        defaultModelHint: snapshot.defaultModelHint,
        unusedPreferredModelId: snapshot.unusedPreferredModelId,
      };
    }
  }
  // A new conversation across all connections: the same chain as creating in a folder and the last skill tier. When nothing is usable no connection is given, and no conversation opens with an empty model.
  const picked = resolveNewChatSelection(runtimeProviders, lastUsedModelRef);
  return {
    provider: picked?.provider,
    currentModel: picked?.model ?? undefined,
    defaultModelHint: picked?.defaultModelHint ?? null,
    unusedPreferredModelId: picked?.unusedPreferredModelId ?? null,
  };
}

/**
 * The single criterion for an "unusable connection" in a new chat: it only means missing credentials - an official / relay connection without a key,
 * or a subscription that is not signed in (effective needsKey). A connection in an error state (issue) is not skipped. The /chat new conversation,
 * folder creation and skill model selection share this one function.
 */
export function isProviderUsableForNewChat(provider: Provider): boolean {
  return getEffectiveStatusKind(provider) !== 'needsKey';
}

export interface NewChatSelection {
  provider: Provider | undefined;
  model: AIModel | null;
  defaultModelHint: 'last_used_retired' | null;
  unusedPreferredModelId: string | null;
}

/**
 * New conversation across all connections: the /chat new conversation, folder creation and the last skill tier all call it. The connection of the last use goes first
 * (if the last use is usable -> it; otherwise that connection's new-conversation default, with last_used_retired), then the next connection in order that has a usable model
 * (catalog defaultModelId, then the first usable one); when none has one, model is null and provider is empty.
 * The hint for an unused last-use model is carried to the later connections. Entries limited to one connection (the detail page) do not call it and never cross connections.
 * Connection order: unusable connections (missing key / subscription not signed in, i.e. needsKey) are dropped first, the rest keep list order, and the connection of the last use is tried first.
 */
export function resolveNewChatSelection(
  allProviders: readonly Provider[],
  lastUsedModelRef: LastUsedModelRef | null,
): NewChatSelection | null {
  const providers = allProviders.filter((pr) => isProviderUsableForNewChat(pr));
  let defaultModelHint: 'last_used_retired' | null = null;
  let unusedPreferredModelId: string | null = null;
  const lastUsedProvider = lastUsedModelRef
    ? providers.find((pr) => sameNormalizedID(pr.id, lastUsedModelRef.providerID))
    : undefined;
  if (lastUsedModelRef && lastUsedProvider) {
    const snapshot = createProviderSelectionSnapshot(lastUsedProvider, {
      preferredModelId: lastUsedModelRef.modelID,
      lastUsedModelRef,
    });
    defaultModelHint = snapshot?.defaultModelHint ?? null;
    unusedPreferredModelId = snapshot?.unusedPreferredModelId ?? null;
    if (snapshot?.currentModel) {
      return { provider: snapshot.provider, model: snapshot.currentModel, defaultModelHint, unusedPreferredModelId };
    }
  }
  for (const provider of providers) {
    if (provider === lastUsedProvider) continue;
    const snapshot = createProviderSelectionSnapshot(provider, { lastUsedModelRef });
    if (snapshot?.currentModel) {
      return { provider: snapshot.provider, model: snapshot.currentModel, defaultModelHint, unusedPreferredModelId };
    }
  }
  return null;
}
