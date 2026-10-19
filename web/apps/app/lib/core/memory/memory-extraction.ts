import type { LastUsedModelRef, Provider } from '@oriveo/shared';
import { getProviderInstanceDisplayName } from '../providers/provider-display';
import { stripFreeSuffix } from '../../utils/strip-free-suffix';
import { memoryModelCandidates, type MemoryModelCandidate } from './memory-organize';

/**
 * Disclosure before a model call on the memory page (AI draft / organize into items):
 * only the first provider + model among the candidates is used and a failure does not switch to another; the box shows exactly the one actually used for sending.
 */
/** Disclosure scope: a draft sends the user messages of the selected provider from recent conversations; organizing sends only the original text of this one memory. */
export type MemoryExtractionScope = 'draft' | 'organize';

/** The same disclosure box swaps its title and scope line by scope (pages.memory.*). */
export const MEMORY_EXTRACTION_COPY = {
  draft: { title: 'extractionTitleDraft', scope: 'extractionScopeDraft' },
  organize: { title: 'extractionTitleOrganize', scope: 'extractionScopeOrganize' },
} as const satisfies Record<MemoryExtractionScope, { title: string; scope: string }>;

export interface MemoryExtractionDisclosure {
  candidate: MemoryModelCandidate;
  providerName: string;
  modelName: string;
}

/** Candidates keep the existing order (last used model first) and only the first is taken; null when there is none. */
export function memoryExtractionDisclosure(
  providers: readonly Provider[],
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): MemoryExtractionDisclosure | null {
  const candidate = memoryModelCandidates(providers, lastUsedModelRef)[0];
  if (!candidate) return null;
  // The model name comes from the same source as the model pill in the chat header (ModelTrigger shows model.name with the "(free)" suffix stripped), not from a catalog display-name lookup.
  return {
    candidate,
    providerName: getProviderInstanceDisplayName(candidate.provider),
    modelName: stripFreeSuffix(candidate.model.name || candidate.model.id),
  };
}

export interface MemoryDraftSourceMessage {
  role: string;
  text: string;
  providerID?: string;
}

/**
 * Draft send scope: per conversation keep only messages with role=user and providerID == the selected provider (messages with an empty providerID are dropped),
 * in the line format `role: text`, truncated to the first limit characters per conversation; conversations that end up empty are dropped, and conversations are joined with `\n---\n`.
 * Returns an empty string when everything is empty (the caller reports "not enough conversation content").
 */
export function memoryDraftExcerpts(
  conversations: ReadonlyArray<{ messages: readonly MemoryDraftSourceMessage[] }>,
  providerID: string,
  limit: number,
): string {
  return conversations
    .map((conv) =>
      conv.messages
        .filter((m) => m.role === 'user' && !!m.providerID && m.providerID === providerID)
        .map((m) => `${m.role}: ${m.text}`)
        .join('\n')
        .slice(0, limit),
    )
    .filter((s) => s.trim().length > 0)
    .join('\n---\n');
}
