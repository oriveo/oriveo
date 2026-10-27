import {
  APPEARANCE_SEGMENTS,
  CUSTOM_PRESET_DOTS,
  PALETTE_CARDS,
  appearanceLabelKey,
  cardLabelKey,
} from '../app/settings/theme/theme-page-rules';

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

// 主题页的卡名、外观段名、预置色名与摘要模板都按映射表取键（theme-page-rules.ts），源码里没有完整字面量。
const THEME_SUMMARY_KEYS = ['themeSummaryLight', 'themeSummaryDark', 'themeSummaryFollowSystem'];

describe('theme page message keys', () => {
  const locales = readdirSync(MESSAGES_DIR).filter((name) => name.endsWith('.json'));
  const keys = [
    ...PALETTE_CARDS.map(cardLabelKey),
    ...APPEARANCE_SEGMENTS.map(appearanceLabelKey),
    ...CUSTOM_PRESET_DOTS.map((dot) => dot.labelKey),
    ...THEME_SUMMARY_KEYS,
  ];

  it.each(locales)('%s has every pages.settings theme key; summaries keep {palette}', (file) => {
    const messages = JSON.parse(readFileSync(join(MESSAGES_DIR, file), 'utf8')) as { pages: { settings: Record<string, unknown> } };
    const settings = messages.pages.settings;
    expect(keys.filter((key) => typeof settings[key] !== 'string')).toEqual([]);
    expect(THEME_SUMMARY_KEYS.filter((key) => !String(settings[key]).includes('{palette}'))).toEqual([]);
    // 跟随系统开关已删，提示文案随之删除
    expect(settings.themeFollowSystemHint).toBeUndefined();
  });
});
