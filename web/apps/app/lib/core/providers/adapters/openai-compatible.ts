/**
 * Shared logic for OpenAI-compatible APIs.
 *
 * Groq / Together AI / Fireworks AI / MiniMax / Zhipu / Qwen / SiliconFlow all speak the
 * OpenAI-compatible API. The truth about official models comes from backend metadata; this module
 * only gives the model entries a uniform structure.
 */

import type { ProviderKind } from "@oriveo/shared";
import { buildCatalogModel, compactContextText } from "../catalog-model";

export { compactContextText };

export interface RemoteModel {
  id: string;
  context_window?: number;
  context_length?: number;
  created?: number;
  created_at?: number;
  owned_by?: string;
  type?: string;
  display_name?: string;
}

export interface BuildModelsConfig {
  displayName?: (remote: RemoteModel) => string;
  contextLength?: (remote: RemoteModel) => number | undefined;
  createdAt?: (remote: RemoteModel) => number | undefined;
}

export function buildModelsFromCatalog(
  remoteModels: RemoteModel[],
  config: BuildModelsConfig,
  providerKind: ProviderKind | string,
) {
  return remoteModels
    .map((remote) => {
      const contextLength = config.contextLength
        ? config.contextLength(remote)
        : (remote.context_window ?? remote.context_length);

      return buildCatalogModel({
        providerKind,
        runtimeModelId: remote.id,
        fallbackName: config.displayName
          ? config.displayName(remote)
          : (remote.display_name ?? remote.id),
        fallbackContextLength: contextLength,
        createdAt: config.createdAt ? config.createdAt(remote) : remote.created,
      });
    })
    .sort(compareCatalogModels);
}

function compareCatalogModels(
  left: { sortRank?: number; createdAt?: number; name: string },
  right: { sortRank?: number; createdAt?: number; name: string },
) {
  const rankDiff = (right.sortRank ?? 0) - (left.sortRank ?? 0);
  if (rankDiff !== 0) return rankDiff;

  const createdDiff = (right.createdAt ?? 0) - (left.createdAt ?? 0);
  if (createdDiff !== 0) return createdDiff;

  return left.name.localeCompare(right.name, undefined, {
    numeric: true,
    sensitivity: "base",
  });
}
