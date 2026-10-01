import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import type { SkillKnowledgeBaseFile } from '@oriveo/shared';

// Keys composed at runtime never appear as a full literal in the source, so a cleanup that treats
// "no literal reference" as "unused" would delete them. Assert each composed key exists in every locale,
// built the same way the production code builds it.
const KNOWLEDGE_STATUSES: Record<SkillKnowledgeBaseFile['status'] | 'disabled', true> = {
  uploading: true,
  extracting: true,
  indexing: true,
  ready: true,
  failed: true,
  deleting: true,
  replacing: true,
  disabled: true,
};

const MESSAGES_DIR = __dirname;

function knowledgeStatusKey(status: string): string {
  // Same composition as SkillEditPage: t(`knowledgeStatus${status[0].toUpperCase()}${status.slice(1)}`)
  return `knowledgeStatus${status[0].toUpperCase()}${status.slice(1)}`;
}

describe('dynamically composed message keys', () => {
  const locales = readdirSync(MESSAGES_DIR).filter((name) => name.endsWith('.json'));

  it('covers all 16 locales', () => {
    expect(locales).toHaveLength(16);
  });

  it.each(locales)('%s has every skills.knowledgeStatus* key', (file) => {
    const messages = JSON.parse(readFileSync(join(MESSAGES_DIR, file), 'utf8')) as { skills: Record<string, unknown> };
    const missing = Object.keys(KNOWLEDGE_STATUSES)
      .map(knowledgeStatusKey)
      .filter((key) => typeof messages.skills[key] !== 'string');
    expect(missing).toEqual([]);
  });
});
