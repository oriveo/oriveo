/**
 * System prompt injection: Skill.systemPrompt -> knowledge files -> memory.
 *
 * This layer collects the conversation material that the assembler turns into the final system prompt:
 * - `resolvePromptUseMemory`: the conversation-level useMemory overrides the skill-level one, then
 *   falls back to the global default of true.
 * - `buildChatContextSources`: collects the skill / pinned notes / knowledge files / memory and hands them to the assembler to build the system prompt.
 */

import type { StoreApi } from 'zustand';
import type { Conversation } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import type { StreamUsage } from '../providers/types';
import { getSkillById } from '../skills/query';
import { normalizePinnedNoteIDs, sameNormalizedID } from '../../utils/id-utils';
import { isRuntimeFeatureEnabled } from '../metadata/metadata-client';
import type {
  AssembleConversation,
  ContextKnowledgeFile,
  ContextMemoryItem,
  ContextPinnedNote,
} from '@oriveo/core/context/assemble';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';

const MAX_PINNED_NOTES = 3;
// English fallback for a pinned note with a blank title; this module has no React i18n context.
const UNTITLED_NOTE_FALLBACK = 'Untitled note';

export interface PromptInjectionContext {
  systemContent: string | null;
  remainingChars: number;
  useMemory: boolean;
  memoryInjected: boolean;
  retrievalUsage?: StreamUsage;
  retrievalCost: number;
  retrievalModelId?: string;
  /** Billing marker for this retrieval's usage (shared with the retrieval cache entry): set when a successful finish emits the retrieval usage event. */
  retrievalUsageClaim?: SkillRetrievalUsageClaim;
}

/** "Usage already billed" marker for one real retrieval: cache hits share the same object, and only the first real send bills it. */
export interface SkillRetrievalUsageClaim {
  claimed: boolean;
}

/**
 * Retrieval usage for the real send path: if this retrieval was already billed by an earlier successful send (a cache hit), return empty usage and zero cost;
 * otherwise return it unchanged. Read only, never sets the marker: failed or aborted sends are not billed, so a retry within 60 s still records the real usage once. Pre-checks do not call this.
 */
export function unbilledSkillRetrievalUsage<T extends PromptInjectionContext>(promptContext: T): T {
  if (!promptContext.retrievalUsageClaim?.claimed) return promptContext;
  return { ...promptContext, retrievalUsage: undefined, retrievalCost: 0 };
}

/** Called when a successful finish emits the retrieval usage event: the first call sets the marker and returns true; if already billed (two concurrent sends both succeeded) it returns false and no event is sent. */
export function claimSkillRetrievalUsage(claim: SkillRetrievalUsageClaim | undefined): boolean {
  if (!claim) return true;
  if (claim.claimed) return false;
  claim.claimed = true;
  return true;
}

export function resolvePromptUseMemory(
  conversationUseMemory: boolean | undefined,
  skillUseMemory?: boolean,
): boolean {
  if (typeof conversationUseMemory === 'boolean') {
    return conversationUseMemory;
  }
  if (typeof skillUseMemory === 'boolean') {
    return skillUseMemory;
  }
  return true;
}

/** Conversation material the main chat path hands to ContextAssembler (no character budget here; the assembler shrinks it by token budget). */
export interface ChatContextSources {
  conversation: Omit<AssembleConversation, 'id'>;
  memoryItems: ContextMemoryItem[];
  /** Remote switch context_reminder_enabled (defaults to true): false only turns off the reminder, the instructions still go into system. */
  reminderEnabled: boolean;
  /** Retrieval usage and cost are still booked with the message; systemContent is always null (the plan provides system). */
  promptContext: PromptInjectionContext;
}

/** Remote featureFlags key: the conversation-instructions reminder switch. */
export const CONTEXT_REMINDER_FEATURE_KEY = 'context_reminder_enabled';

/**
 * Collects the skill / pinned notes / knowledge files / memory for the assembler to build system.
 * Memory: when the conversation switch is on, take the injectable items from the local item slice (`MemoryItems.injectable`),
 * standing instructions first and the other memory after, and hand them to the assembler; when off, pass none. memoryText is only a legacy dual-write and is no longer injected.
 */
export async function buildChatContextSources(
  store: StoreApi<AppStore>,
  conversation: Conversation | undefined,
  _latestUserText: string,
): Promise<ChatContextSources> {
  const state = store.getState();
  const skill = conversation?.skillId ? getSkillById(store, conversation.skillId) : undefined;
  const useMemory = resolvePromptUseMemory(conversation?.useMemory, skill?.useMemory);
  // This build ships no document retrieval source, so only the skill's own reference files are placed.

  const pinnedNotes: ContextPinnedNote[] = [];
  for (const id of normalizePinnedNoteIDs(conversation?.pinnedNoteIds, MAX_PINNED_NOTES)) {
    const note = state.notes.find((candidate) => sameNormalizedID(candidate.id, id) && !candidate.deletedAt);
    if (note) pinnedNotes.push({ title: note.title.trim() || UNTITLED_NOTE_FALLBACK, text: note.body });
  }
  const knowledgeFiles: ContextKnowledgeFile[] = skill
    ? [
        ...skill.knowledgeFiles.map((file) => ({ name: file.name, text: file.content })),
      ]
    : [];
  const memoryItems = useMemory ? injectableMemoryItems(state.memoryItems, conversation) : [];
  const memoryInjected = memoryItems.length > 0;
  return {
    conversation: {
      useMemory,
      ...(skill ? { skillPrompt: skill.systemPrompt } : {}),
      instructions: conversation?.instructions ?? '',
      pinnedNotes,
      knowledgeFiles,
    },
    reminderEnabled: isRuntimeFeatureEnabled(CONTEXT_REMINDER_FEATURE_KEY),
    memoryItems,
    promptContext: {
      systemContent: null,
      remainingChars: 0,
      useMemory,
      memoryInjected,
      retrievalCost: 0,
    },
  };
}

/** Items injectable into this conversation: scope is filtered by conversation / folder with standing instructions first; converted to the assembler's memory items. */
function injectableMemoryItems(items: MemoryItem[], conversation: Conversation | undefined): ContextMemoryItem[] {
  const injection = MemoryItems.injectable({
    items,
    conversationId: conversation?.id ?? '',
    folderId: conversation?.folderID ?? null,
    now: new Date().toISOString(),
  });
  // Scope and status were already filtered by injectable, so they are not handed to the assembler for a second check (it does not know the folder scope).
  return [...injection.standingInstructions, ...injection.memory].map((m) => ({
    id: m.id,
    kind: m.kind,
    content: m.content,
    pinned: m.pinned,
  }));
}
