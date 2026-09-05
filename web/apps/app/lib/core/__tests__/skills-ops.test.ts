import { beforeEach, describe, expect, it } from 'vitest';
import type { Skill, SkillCategory, SkillUsage } from '@oriveo/shared';
import { createAppStore, type AppStore } from '../store/app-store';
import { getCatalogByCategory, getHomeSkills, getSidebarSkills } from '../skills/ops';
import type { StoreApi } from 'zustand';

let nextSkillID = 1;

function makeSkill(overrides: Partial<Skill> = {}): Skill {
  return {
    id: overrides.id ?? `skill-${nextSkillID++}`,
    key: overrides.key,
    name: overrides.name ?? 'Skill',
    description: overrides.description ?? '',
    icon: overrides.icon ?? '✨',
    color: overrides.color ?? '#4A90D9',
    systemPrompt: overrides.systemPrompt ?? 'Prompt',
    suggestedProviderId: overrides.suggestedProviderId,
    suggestedModelId: overrides.suggestedModelId,
    modelCapabilityHint: overrides.modelCapabilityHint ?? 'any',
    temperature: overrides.temperature,
    reasoningLevel: overrides.reasoningLevel,
    webSearchEnabled: overrides.webSearchEnabled,
    starterMessages: overrides.starterMessages ?? [],
    knowledgeFiles: overrides.knowledgeFiles ?? [],
    useMemory: overrides.useMemory ?? true,
    isPinned: overrides.isPinned ?? false,
    pinOrder: overrides.pinOrder ?? 0,
    source: overrides.source ?? 'builtin',
    forkedFromId: overrides.forkedFromId,
    category: overrides.category,
    sortOrder: overrides.sortOrder ?? 0,
    usageCount: overrides.usageCount ?? 0,
    lastUsedAt: overrides.lastUsedAt,
    createdAt: overrides.createdAt ?? '2026-04-03T00:00:00Z',
    updatedAt: overrides.updatedAt ?? '2026-04-03T00:00:00Z',
  };
}

function makeCategory(overrides: Partial<SkillCategory> = {}): SkillCategory {
  return {
    id: overrides.id ?? 'category',
    name: overrides.name ?? 'Category',
    icon: overrides.icon ?? '',
    sortOrder: overrides.sortOrder ?? 0,
  };
}

describe('skills ops', () => {
  let store: StoreApi<AppStore>;
  const usage: SkillUsage = { count: 0, limit: 5, isPro: false };

  beforeEach(() => {
    store = createAppStore();
    nextSkillID = 1;
  });

  it('getHomeSkills returns the curated default builtin skills for a new user', () => {
    store.getState().setCatalogSkills([
      makeSkill({ id: 'code', key: 'code_assistant', name: 'Code Assistant', sortOrder: 1, category: 'coding' }),
      makeSkill({ id: 'translation', key: 'translation_expert', name: 'Translation Expert', sortOrder: 1, category: 'translation' }),
      makeSkill({ id: 'writing', key: 'writing_coach', name: 'Writing Coach', sortOrder: 1, category: 'writing' }),
      makeSkill({ id: 'email', key: 'email_assistant', name: 'Email Assistant', sortOrder: 2, category: 'writing' }),
      makeSkill({ id: 'brainstorm', key: 'brainstorm', name: 'Brainstorm', sortOrder: 1, category: 'creative' }),
      makeSkill({ id: 'summary', key: 'document_summarizer', name: 'Document Summarizer', sortOrder: 3, category: 'analysis' }),
    ], [], 1);

    const result = getHomeSkills(store).map((skill) => skill.key);

    expect(result.slice(0, 5)).toEqual([
      'translation_expert',
      'writing_coach',
      'email_assistant',
      'brainstorm',
      'document_summarizer',
    ]);
  });

  it('getHomeSkills prioritizes pinned and recent skills, then falls back to builtin recommendations', () => {
    store.getState().setCatalogSkills([
      makeSkill({ id: 'translation', key: 'translation_expert', name: 'Translation Expert' }),
      makeSkill({ id: 'writing', key: 'writing_coach', name: 'Writing Coach' }),
      makeSkill({ id: 'email', key: 'email_assistant', name: 'Email Assistant' }),
      makeSkill({ id: 'brainstorm', key: 'brainstorm', name: 'Brainstorm' }),
      makeSkill({ id: 'summary', key: 'document_summarizer', name: 'Document Summarizer' }),
    ], [], 1);
    store.getState().setUserSkills([
      makeSkill({ id: 'pinned', name: 'Pinned User', source: 'user', isPinned: true, pinOrder: 1 }),
      makeSkill({ id: 'recent', name: 'Recent User', source: 'user', lastUsedAt: '2026-04-03T09:00:00Z' }),
      makeSkill({ id: 'unused', name: 'Unused User', source: 'user' }),
    ], usage);

    const result = getHomeSkills(store).map((skill) => skill.id);

    expect(result.slice(0, 2)).toEqual(['pinned', 'recent']);
    expect(result).not.toContain('unused');
  });

  it('getSidebarSkills only shows pinned and recent skills, capped at 8', () => {
    const recentSkills = Array.from({ length: 9 }, (_, index) =>
      makeSkill({
        id: `recent-${index}`,
        key: `recent_${index}`,
        lastUsedAt: `2026-04-03T0${9 - index}:00:00Z`,
      }),
    );

    store.getState().setCatalogSkills([
      ...recentSkills,
      makeSkill({ id: 'unused-catalog', key: 'code_assistant', lastUsedAt: undefined }),
    ], [], 1);

    const result = getSidebarSkills(store);

    expect(result).toHaveLength(8);
    expect(result.map((skill) => skill.id)).not.toContain('unused-catalog');
  });

  it('getCatalogByCategory follows backend category sort order', () => {
    store.getState().setCatalogSkills([
      makeSkill({ id: 'writing-skill', category: 'writing', key: 'writing_coach' }),
      makeSkill({ id: 'analysis-skill', category: 'analysis', key: 'document_summarizer' }),
    ], [
      makeCategory({ id: 'analysis', name: 'Analysis', sortOrder: 1 }),
      makeCategory({ id: 'writing', name: 'Writing', sortOrder: 2 }),
    ], 1);

    expect(Array.from(getCatalogByCategory(store).keys())).toEqual(['analysis', 'writing']);
  });
});
