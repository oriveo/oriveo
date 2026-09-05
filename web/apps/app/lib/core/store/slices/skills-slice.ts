import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type SkillsActions = Pick<
  AppActions,
  'setCatalogSkills' | 'setUserSkills' | 'updateSkillInStore' | 'addUserSkill' | 'removeUserSkill'
>;

/** Skills slice: catalog skills, user skills, plus categories, usage and catalog version. */
export function createSkillsSlice(set: AppStoreSet): SkillsActions {
  return {
    setCatalogSkills: (skills, categories, version) =>
      set({ catalogSkills: skills ?? [], skillCategories: categories ?? [], catalogVersion: version }),
    setUserSkills: (skills, usage) =>
      set({ userSkills: skills ?? [], skillUsage: usage }),
    updateSkillInStore: (id, patch) =>
      set((s) => ({
        catalogSkills: (s.catalogSkills ?? []).map((sk) => sk.id === id ? { ...sk, ...patch } : sk),
        userSkills: (s.userSkills ?? []).map((sk) => sk.id === id ? { ...sk, ...patch } : sk),
      })),
    addUserSkill: (skill) =>
      set((s) => ({ userSkills: [skill, ...(s.userSkills ?? [])] })),
    removeUserSkill: (id) =>
      set((s) => ({ userSkills: (s.userSkills ?? []).filter((sk) => sk.id !== id) })),
  };
}
