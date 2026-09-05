/**
 * Local skills operations. Custom skills live in IndexedDB only.
 * There is no cloud catalog, account token, or skill quota.
 */

import type { StoreApi } from 'zustand';
import type { Skill, SkillUsage } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import * as cache from './cache';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { trackEvent } from '../telemetry';
import { createCanonicalUUID } from '../../utils/id-utils';
export { getHomeSkills, getSidebarSkills, getSkillById, resolveModelForSkill, type ResolvedModel } from './query';

const UNLIMITED_USAGE: SkillUsage = { count: 0, limit: null, isPro: true };

function localUsage(count: number): SkillUsage {
  return { count, limit: null, isPro: true };
}

export async function refreshAllSkills(store: StoreApi<AppStore>): Promise<void> {
  const boundUID = getActiveUIDSync();
  const [cachedCatalog, cachedUserSkills, localUsageOverrides] = await Promise.all([
    cache.loadCachedCatalog(boundUID),
    cache.loadCachedUserSkills(boundUID),
    cache.getLocalUsageOverrides(boundUID),
  ]);

  if (cachedCatalog.skills.length > 0) {
    store.getState().setCatalogSkills(
      applyLocalUsageOverrides(cachedCatalog.skills, localUsageOverrides),
      cachedCatalog.categories,
      cachedCatalog.version ?? 0,
    );
  } else {
    store.getState().setCatalogSkills([], [], 0);
  }
  store.getState().setUserSkills(cachedUserSkills, localUsage(cachedUserSkills.length));
}

function applyLocalUsageOverrides(
  skills: Skill[],
  overrides: Record<string, string>,
): Skill[] {
  if (Object.keys(overrides).length === 0) return skills;
  return skills.map((s) =>
    overrides[s.id] ? { ...s, lastUsedAt: overrides[s.id] } : s,
  );
}

export function getCatalogByCategory(store: StoreApi<AppStore>): Map<string, Skill[]> {
  const { catalogSkills = [], skillCategories = [] } = store.getState();
  const orderedMap = new Map<string, Skill[]>();

  for (const category of [...skillCategories].sort((a, b) => a.sortOrder - b.sortOrder)) {
    orderedMap.set(category.id, []);
  }

  for (const skill of catalogSkills) {
    const categoryId = skill.category ?? 'other';
    if (!orderedMap.has(categoryId)) {
      orderedMap.set(categoryId, []);
    }
    orderedMap.get(categoryId)!.push(skill);
  }

  return new Map(
    Array.from(orderedMap.entries()).filter(([, skills]) => skills.length > 0),
  );
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function buildSkillFromBody(body: Record<string, unknown>, existing?: Skill): Skill {
  const now = new Date().toISOString();
  const id = existing?.id ?? createCanonicalUUID();
  return {
    id,
    key: existing?.key,
    name: asString(body.name, existing?.name ?? 'Untitled'),
    description: asString(body.description, existing?.description ?? ''),
    translations: existing?.translations,
    icon: asString(body.icon, existing?.icon ?? 'sparkles'),
    color: asString(body.color, existing?.color ?? '#8B5CF6'),
    systemPrompt: asString(body.systemPrompt, existing?.systemPrompt ?? ''),
    suggestedProviderId: asString(body.suggestedProviderId, existing?.suggestedProviderId ?? '') || undefined,
    suggestedModelId: asString(body.suggestedModelId, existing?.suggestedModelId ?? '') || undefined,
    modelCapabilityHint: asString(body.modelCapabilityHint, existing?.modelCapabilityHint ?? 'any'),
    temperature: typeof body.temperature === 'number' ? body.temperature : existing?.temperature,
    reasoningLevel: asString(body.reasoningLevel, existing?.reasoningLevel ?? '') || undefined,
    webSearchEnabled: typeof body.webSearchEnabled === 'boolean' ? body.webSearchEnabled : existing?.webSearchEnabled,
    starterMessages: Array.isArray(body.starterMessages)
      ? body.starterMessages.filter((item): item is string => typeof item === 'string')
      : existing?.starterMessages ?? [],
    knowledgeFiles: Array.isArray(body.knowledgeFiles)
      ? body.knowledgeFiles as Skill['knowledgeFiles']
      : existing?.knowledgeFiles ?? [],
    knowledgeBase: body.knowledgeBase === undefined
      ? existing?.knowledgeBase ?? null
      : (body.knowledgeBase as Skill['knowledgeBase']),
    useMemory: asBoolean(body.useMemory, existing?.useMemory ?? true),
    isPinned: asBoolean(body.isPinned, existing?.isPinned ?? false),
    pinOrder: asNumber(body.pinOrder, existing?.pinOrder ?? 0),
    source: existing?.source ?? 'user',
    forkedFromId: existing?.forkedFromId,
    category: existing?.category,
    sortOrder: existing?.sortOrder ?? 0,
    usageCount: existing?.usageCount ?? 0,
    lastUsedAt: existing?.lastUsedAt,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };
}

export async function createSkillOp(
  store: StoreApi<AppStore>,
  body: Record<string, unknown>,
): Promise<Skill> {
  const uid = getActiveUIDSync();
  const skill = buildSkillFromBody(body);
  const next = [skill, ...store.getState().userSkills.filter((s) => s.id !== skill.id)];
  store.getState().setUserSkills(next, localUsage(next.length));
  await cache.saveUserSkills(next, uid);
  trackEvent('skill_created', {
    skill_id: skill.id,
    has_knowledge_base: Boolean(skill.knowledgeBase && skill.knowledgeBase.files.length > 0),
    use_memory: Boolean(skill.useMemory),
  });
  return skill;
}

export async function updateSkillOp(
  store: StoreApi<AppStore>,
  id: string,
  body: Record<string, unknown>,
): Promise<Skill> {
  const uid = getActiveUIDSync();
  const existing = store.getState().userSkills.find((s) => s.id === id)
    ?? store.getState().catalogSkills.find((s) => s.id === id);
  const skill = buildSkillFromBody(body, existing ? { ...existing, id } : { ...buildSkillFromBody({}), id });
  store.getState().updateSkillInStore(id, skill);
  await cache.saveUserSkills(store.getState().userSkills, uid);
  return skill;
}

export async function togglePinOp(
  store: StoreApi<AppStore>,
  skill: Skill,
  pinOrder: number,
): Promise<void> {
  const patch = { isPinned: !skill.isPinned, pinOrder };
  const boundUID = getActiveUIDSync();
  store.getState().updateSkillInStore(skill.id, patch);
  if (skill.source === 'builtin') {
    await cache.saveCatalog(
      store.getState().catalogSkills,
      store.getState().skillCategories,
      store.getState().catalogVersion ?? 0,
      boundUID,
    );
    return;
  }
  await cache.saveUserSkills(store.getState().userSkills, boundUID);
}

export async function deleteSkillOp(
  store: StoreApi<AppStore>,
  id: string,
  _body?: Record<string, unknown>,
): Promise<void> {
  const uid = getActiveUIDSync();
  store.getState().removeUserSkill(id);
  store.getState().setUserSkills(store.getState().userSkills, localUsage(store.getState().userSkills.length));
  await cache.saveUserSkills(store.getState().userSkills, uid);
}

export async function forkSkillOp(
  store: StoreApi<AppStore>,
  id: string,
): Promise<Skill> {
  const source = store.getState().userSkills.find((s) => s.id === id)
    ?? store.getState().catalogSkills.find((s) => s.id === id);
  if (!source) throw new Error('Skill not found');
  const forked = buildSkillFromBody({
    name: `${source.name} copy`,
    description: source.description,
    icon: source.icon,
    color: source.color,
    systemPrompt: source.systemPrompt,
    modelCapabilityHint: source.modelCapabilityHint,
    starterMessages: source.starterMessages,
    knowledgeFiles: source.knowledgeFiles,
    knowledgeBase: null,
    useMemory: source.useMemory,
  });
  forked.forkedFromId = source.id;
  const uid = getActiveUIDSync();
  const next = [forked, ...store.getState().userSkills];
  store.getState().setUserSkills(next, localUsage(next.length));
  await cache.saveUserSkills(next, uid);
  trackEvent('skill_forked', {
    origin_skill_id: id,
    skill_id: forked.id,
  });
  return forked;
}

export async function recordSkillUseOp(
  store: StoreApi<AppStore>,
  id: string,
): Promise<void> {
  const boundUID = getActiveUIDSync();
  const now = new Date().toISOString();
  store.getState().updateSkillInStore(id, { lastUsedAt: now });
  await cache.setLocalUsageOverride(id, now, boundUID);
  const skill = store.getState().userSkills.find((s) => s.id === id)
    ?? store.getState().catalogSkills.find((s) => s.id === id);
  trackEvent('skill_used', {
    skill_id: id,
    is_user_skill: skill?.source !== 'builtin',
    knowledge_enabled: Boolean(skill?.knowledgeBase && skill.knowledgeBase.files.length > 0),
  });
}

void UNLIMITED_USAGE;
