import type { StoreApi } from 'zustand';
import type { Skill, Provider, AIModel } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { getEffectiveStatusKind, isEffectiveWarning } from '../providers/provider-status';
import { modelSupportsCapabilityFilter } from '../chat/model-capability-presentation';
import { resolveModelCapabilityEvidence } from '../chat/capability-evidence';

const DEFAULT_ONBOARDING_SKILL_KEYS = [
  'translation_expert',
  'writing_coach',
  'email_assistant',
  'brainstorm',
  'document_summarizer',
];

const HOME_SKILLS_LIMIT = 7;
const SIDEBAR_SKILLS_LIMIT = 8;

function appendUniqueSkills(
  target: Skill[],
  seenIds: Set<string>,
  candidates: Skill[],
  limit: number,
): void {
  for (const skill of candidates) {
    if (target.length >= limit) return;
    if (seenIds.has(skill.id)) continue;
    seenIds.add(skill.id);
    target.push(skill);
  }
}

function getPinnedSkills(allSkills: Skill[]): Skill[] {
  return allSkills
    .filter((skill) => skill.isPinned)
    .sort((a, b) => a.pinOrder - b.pinOrder);
}

function getRecentSkills(allSkills: Skill[]): Skill[] {
  return allSkills
    .filter((skill) => !skill.isPinned && Boolean(skill.lastUsedAt))
    .sort((a, b) => (b.lastUsedAt ?? '').localeCompare(a.lastUsedAt ?? ''));
}

export function getHomeSkills(store: StoreApi<AppStore>): Skill[] {
  const { catalogSkills = [], userSkills = [] } = store.getState();
  const all = [...catalogSkills, ...userSkills];
  const pinned = getPinnedSkills(all);
  const recent = getRecentSkills(all);
  const selected: Skill[] = [];
  const seenIds = new Set<string>();

  appendUniqueSkills(selected, seenIds, pinned, HOME_SKILLS_LIMIT);
  appendUniqueSkills(selected, seenIds, recent, HOME_SKILLS_LIMIT);

  const recommendedBuiltin = DEFAULT_ONBOARDING_SKILL_KEYS
    .map((key) => catalogSkills.find((skill) => skill.key === key))
    .filter((skill): skill is Skill => Boolean(skill));
  appendUniqueSkills(selected, seenIds, recommendedBuiltin, HOME_SKILLS_LIMIT);

  const remainingBuiltin = catalogSkills.filter((skill) => !seenIds.has(skill.id));
  appendUniqueSkills(selected, seenIds, remainingBuiltin, HOME_SKILLS_LIMIT);

  return selected;
}

export function getSidebarSkills(store: StoreApi<AppStore>): Skill[] {
  const { catalogSkills = [], userSkills = [] } = store.getState();
  const all = [...catalogSkills, ...userSkills];
  return [...getPinnedSkills(all), ...getRecentSkills(all)].slice(0, SIDEBAR_SKILLS_LIMIT);
}

export function getSkillById(store: StoreApi<AppStore>, id: string): Skill | undefined {
  const { catalogSkills, userSkills } = store.getState();
  return catalogSkills.find((skill) => skill.id === id) ?? userSkills.find((skill) => skill.id === id);
}

export interface ResolvedModel {
  provider: Provider;
  model: AIModel;
}

export function resolveModelForSkill(
  store: StoreApi<AppStore>,
  skill: Skill,
): ResolvedModel | null {
  const { providers, lastUsedModelRef } = store.getState();
  // A provider with no key on this client cannot actually be used, so it has to be excluded from the active set; the effective state matches needsKey
  const activeProviders = providers.filter(
    (provider) => !isEffectiveWarning(getEffectiveStatusKind(provider)) && provider.models.length > 0,
  );

  if (activeProviders.length === 0) return null;

  if (skill.suggestedModelId && skill.suggestedProviderId) {
    const provider = activeProviders.find((candidate) => (
      candidate.id === skill.suggestedProviderId ||
      candidate.kind === skill.suggestedProviderId
    ));
    if (provider) {
      const model = provider.models.find((candidate) => candidate.id === skill.suggestedModelId);
      if (model) return { provider, model };
    }
  }

  if (skill.modelCapabilityHint !== 'any') {
    const fallback = findByCapabilityHint(activeProviders, skill.modelCapabilityHint);
    if (fallback) return fallback;
  }

  if (lastUsedModelRef) {
    const provider = activeProviders.find((candidate) => candidate.id === lastUsedModelRef.providerID);
    if (provider) {
      const model = provider.models.find((candidate) => candidate.id === lastUsedModelRef.modelID);
      if (model) return { provider, model };
    }
  }

  for (const provider of activeProviders) {
    const model = provider.models.find((candidate) => candidate.isDefault) ?? provider.models[0];
    if (model) return { provider, model };
  }

  return null;
}

/**
 * Whether any thinking level on this model is judged supported by production evidence.
 *
 * Only keys that appear in `capabilityEvidenceCandidates` are asked of the facade, rather than
 * enumerating level names here: the set of levels is sent by the server, and a client-side copy
 * would quietly miss levels as upstream changes. The verdict still comes only from
 * `resolveModelCapabilityEvidence`; the candidates are read just to know which keys to ask about.
 */
function hasEvidencedReasoningLevel(provider: Provider, model: AIModel): boolean {
  const keys = new Set(
    (model.capabilityEvidenceCandidates ?? [])
      .map((candidate) => candidate.key)
      .filter((key): key is `reasoning_level/${string}` => key.startsWith('reasoning_level/')),
  );
  for (const key of keys) {
    if (resolveModelCapabilityEvidence({ key, provider, model }).support === 'supported') return true;
  }
  return false;
}

function findByCapabilityHint(
  providers: Provider[],
  hint: string,
): ResolvedModel | null {
  const capabilityMap: Record<string, (provider: Provider, model: AIModel) => boolean> = {
    // Picking a model and rendering a badge are two different questions with different criteria.
    //
    // `modelSupportsCapabilityFilter(…, 'reasoning')` goes through the control verdict
    // (presentCapabilityControl), which returns unknown whenever the server has not sent
    // capabilityRuntime. That strictness is necessary for badges, which must never promise a
    // control the chat view refuses to offer, and it is what fixed "45 Qwen models showed a
    // reasoning badge on the web while the chat view kept it disabled".
    //
    // Borrowing the same predicate to pick a model is wrong, though: with runtime missing it
    // judges every model unsupported, this returns null, and the caller falls back to
    // `lastUsedModelRef`. That fallback is arbitrary rather than conservative: the skill then
    // runs on a model that may not think at all, which is worse than picking the one that has
    // effect_verified evidence but no runtime yet.
    //
    // The vision branch in this file has always gone through the evidence facade
    // (`isSupported('vision_input')`), which is exactly this semantics; reasoning is brought back
    // into symmetry with it here.
    //
    // The relaxation applies only to picking a model. `modelSupportsCapabilityFilter` itself is
    // untouched, so the badge path is unaffected.
    reasoning: (provider, model) => (
      modelSupportsCapabilityFilter(provider, model, 'reasoning')
      || hasEvidencedReasoningLevel(provider, model)
    ),
    vision: (provider, model) => modelSupportsCapabilityFilter(provider, model, 'vision'),
    fast: (_provider, model) => (
      model.priceTier === 'low' ||
      model.name.toLowerCase().includes('mini') ||
      model.name.toLowerCase().includes('haiku') ||
      model.name.toLowerCase().includes('flash')
    ),
    'large-context': (_provider, model) => (model.contextLength ?? 0) >= 128000,
    any: () => true,
  };

  const matcher = capabilityMap[hint] ?? capabilityMap.any;

  for (const provider of providers) {
    const model = provider.models.find((candidate) => matcher(provider, candidate));
    if (model) return { provider, model };
  }

  return null;
}
