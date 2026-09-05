import type { StoreApi } from 'zustand';
import type { Conversation, Skill } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { createCanonicalUUID } from '../../utils/id-utils';
import { resolveModelForSkill } from './query';
import { loadSkillOps } from './ops-lazy';
import { withErrorReporting } from '../../sentry/report-silent';

export type StartSkillConversationResult =
  | { kind: 'ok'; conversationId: string }
  | { kind: 'no-provider' };

export interface StartSkillConversationOptions {
  /** Initial title, overwritten automatically once the first message is sent (hasCustomTitle=false) */
  title: string;
}

/**
 * Create a draft conversation from a skill:
 *   - resolve the model the skill recommends
 *   - create it and write it to the store (isDraft=true, with skillId already bound)
 *   - set activeConversationId and lastUsedModelRef
 *   - defer one task before the fire-and-forget usage record, so SkillsLanding does not
 *     reflow in the same frame it unmounts in
 */
export function startConversationWithSkill(
  store: StoreApi<AppStore>,
  skill: Skill,
  options: StartSkillConversationOptions,
): StartSkillConversationResult {
  const resolved = resolveModelForSkill(store, skill);
  if (!resolved) return { kind: 'no-provider' };

  const now = new Date().toISOString();
  const conversation: Conversation = {
    id: createCanonicalUUID(),
    title: options.title,
    hasCustomTitle: false,
    providerID: resolved.provider.id,
    providerKind: resolved.provider.kind,
    ...(resolved.provider.kind === 'relay' && resolved.provider.relayKind
      ? { relayKind: resolved.provider.relayKind }
      : {}),
    modelID: resolved.model.id,
    previewText: '',
    estimatedCost: 0,
    isDraft: true,
    messages: [],
    draftText: '',
    updatedAt: now,
    createdAt: now,
    skillId: skill.id,
    ...(skill.useMemory !== undefined ? { useMemory: skill.useMemory } : {}),
  };

  const state = store.getState();
  state.addConversation(conversation);
  state.setActiveConversationId(conversation.id);
  state.setLastUsedModelRef({
    providerID: resolved.provider.id,
    modelID: resolved.model.id,
  });

  scheduleSkillUseRecord(store, skill.id);

  return { kind: 'ok', conversationId: conversation.id };
}

function scheduleSkillUseRecord(store: StoreApi<AppStore>, skillId: string): void {
  const fire = () => {
    void loadSkillOps()
      .then(({ recordSkillUseOp }) => recordSkillUseOp(store, skillId))
      .catch(withErrorReporting('skills.recordUse.schedule'));
  };
  if (typeof window !== 'undefined') {
    window.setTimeout(fire, 0);
  } else {
    fire();
  }
}
