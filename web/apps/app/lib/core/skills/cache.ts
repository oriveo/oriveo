/**
 * Local cache for skills.
 * Reuses the existing IndexedDB session KV store, partitioned by user UID, so no new store is needed.
 *
 * Key format:
 *   skills:catalog:skills → Skill[] (built-in catalog)
 *   skills:catalog:version → number (catalog version)
 *   skills:catalog:categories → SkillCategory[]
 *   skills:user:skills → Skill[] (user-created)
 *   skills:local-usage → Record<skillId, isoString> (per-user last-used override)
 */

import type { Skill, SkillCategory } from '@oriveo/shared';
import { getSessionValue, setSessionValue } from '../../infra/storage/idb';

const K_CATALOG_SKILLS = 'skills:catalog:skills';
const K_CATALOG_VERSION = 'skills:catalog:version';
const K_CATALOG_CATEGORIES = 'skills:catalog:categories';
const K_USER_SKILLS = 'skills:user:skills';
const K_LOCAL_USAGE = 'skills:local-usage';

/* ── Catalog ─────────────────────────────────────────── */

export async function loadCachedCatalog(expectedUID?: string): Promise<{
  skills: Skill[];
  categories: SkillCategory[];
  version: number | null;
}> {
  const [skills, categories, version] = await Promise.all([
    getSessionValue<Skill[]>(K_CATALOG_SKILLS, expectedUID),
    getSessionValue<SkillCategory[]>(K_CATALOG_CATEGORIES, expectedUID),
    getSessionValue<number>(K_CATALOG_VERSION, expectedUID),
  ]);
  return {
    skills: skills ?? [],
    categories: categories ?? [],
    version: version ?? null,
  };
}

export async function saveCatalog(
  skills: Skill[],
  categories: SkillCategory[],
  version: number,
  expectedUID?: string,
): Promise<void> {
  await Promise.all([
    setSessionValue(K_CATALOG_SKILLS, skills, expectedUID),
    setSessionValue(K_CATALOG_CATEGORIES, categories, expectedUID),
    setSessionValue(K_CATALOG_VERSION, version, expectedUID),
  ]);
}

/* ── User Skills ─────────────────────────────────────── */

export async function loadCachedUserSkills(expectedUID?: string): Promise<Skill[]> {
  return (await getSessionValue<Skill[]>(K_USER_SKILLS, expectedUID)) ?? [];
}

export async function saveUserSkills(skills: Skill[], expectedUID?: string): Promise<void> {
  await setSessionValue(K_USER_SKILLS, skills, expectedUID);
}

/* ── Per-user lastUsedAt override, so a built-in skill is not counted globally ── */

export async function getLocalUsageOverrides(expectedUID?: string): Promise<Record<string, string>> {
  return (await getSessionValue<Record<string, string>>(K_LOCAL_USAGE, expectedUID)) ?? {};
}

export async function setLocalUsageOverride(
  skillId: string,
  isoTime: string,
  expectedUID?: string,
): Promise<void> {
  // The read-modify-write spans an await: without binding the partition it can read one user's
  // records and write them into the guest partition, merging their skill usage into guest.
  const current = await getLocalUsageOverrides(expectedUID);
  await setSessionValue(K_LOCAL_USAGE, { ...current, [skillId]: isoTime }, expectedUID);
}
