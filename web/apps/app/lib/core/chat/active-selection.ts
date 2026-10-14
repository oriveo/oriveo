import type { AIModel, Conversation, LastUsedModelRef, Provider } from '@oriveo/shared';
import { sameNormalizedID } from '../../utils/id-utils';
import { createProviderSelectionSnapshot } from '../providers/provider-selection-snapshot';
import { resolveConversationModelRemoval, type ConversationModelRemoval } from './conversation-model-status';

export interface ActiveSelection {
  provider: Provider | undefined;
  currentModel: AIModel | undefined;
  /** The relay session model has been removed: currentModel is empty here, and the send entry returns with zero requests accordingly. */
  modelRemoval?: ConversationModelRemoval;
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
): ActiveSelection {
  if (conversation) {
    const p = runtimeProviders.find((pr) => sameNormalizedID(pr.id, conversation.providerID));
    // Session model removed: do not silently swap in the fallback model and do not rewrite the session model; leave it to the banner so the user reselects.
    const modelRemoval = resolveConversationModelRemoval(p, conversation.modelID);
    if (p && modelRemoval) {
      return { provider: p, currentModel: undefined, modelRemoval };
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
      requestedModelId: selectedModelId,
      lastUsedModelRef,
    });
    if (snapshot) {
      return {
        provider: snapshot.provider,
        currentModel: snapshot.currentModel ?? undefined,
      };
    }
  }
  if (lastUsedModelRef) {
    const p = runtimeProviders.find((pr) => sameNormalizedID(pr.id, lastUsedModelRef.providerID));
    const snapshot = createProviderSelectionSnapshot(p, {
      requestedModelId: lastUsedModelRef.modelID,
      lastUsedModelRef,
    });
    if (snapshot) {
      return {
        provider: snapshot.provider,
        currentModel: snapshot.currentModel ?? undefined,
      };
    }
  }
  const p = runtimeProviders[0];
  const snapshot = createProviderSelectionSnapshot(p, { lastUsedModelRef });
  return {
    provider: snapshot?.provider,
    currentModel: snapshot?.currentModel ?? undefined,
  };
}
