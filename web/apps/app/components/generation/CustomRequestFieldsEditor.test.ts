import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { customFragmentRejectionMessage } from './CustomRequestFieldsEditor';

/**
 * Boundary of the copy keys used by this page.
 *
 * `customRequestFieldsConfigurationMode` / `customRequestFieldsAutomatic` /
 * `customRequestFieldsEnable(Scope)` / `customRequestFieldsUnavailable` and the three Reason
 * variants must not exist: there is no automatic/custom two-way radio and no global developer
 * switch, so those keys carry no meaning in any of the 16 locales.
 */
const keys = [
  'customRequestFieldsCustom', 'customRequestFieldsJsonLabel', 'customRequestFieldsFooter',
  'customRequestFieldsPreviewHint', 'customRequestFieldsPreview',
  'customRequestFieldsReasonSyntax', 'customRequestFieldsReasonLimit',
  'customRequestFieldsNotAllowed', 'customRequestFieldsNotAllowedConflict',
  'customRequestFieldsNoSchemaForModel', 'customRequestFieldsNoSchemaForControl',
  'customRequestFieldsLegacyEmpty', 'customRequestFieldsSwitchBackToAutomatic',
  'customRequestFieldsRelayDocs', 'customRequestFieldsDocs',
  'customRequestFieldsRemoveTitle', 'customRequestFieldsRemoveKeep', 'customRequestFieldsRemoveConfirm',
  'customRequestFieldsScopeConnectionModel', 'customRequestFieldsDeleteConnection',
  'customRequestFieldsInUse', 'customRequestFieldsNotInUse', 'customRequestFieldsRequiresSchema',
  // The two advanced settings annotations plus the developer group title, required in all 16 locales.
  'generationParameterTemperatureNote', 'generationParameterMaxTokensNote', 'generationParameterDeveloper',
  'connectionDefaults', 'modelBehaviorConnectionScopeHint',
  // The riskTier-specific hints, required in all 16 locales.
  'capabilityRiskPrivacy', 'capabilityRiskCost',
] as const;

/** Keys that must not appear in any of the 16 locales; leaving one in invites the next person to wire it back up. */
const retiredKeys = [
  'customRequestFields', 'customRequestFieldsConfigurationMode', 'customRequestFieldsAutomatic',
  'customRequestFieldsEnable', 'customRequestFieldsEnableScope', 'customRequestFieldsScope',
  'customRequestFieldsPrivacy', 'customRequestFieldsEmpty', 'customRequestFieldsUnavailable',
  'customRequestFieldsLabel', 'customRequestFieldsReasonScope', 'customRequestFieldsReasonConflict',
  'customRequestFieldsReasonSafety', 'customRequestFieldsInvalid',
  // The web storage key for custom fields has no conversation dimension (`storageKey` in
  // `custom-fragment-settings` is connection x model x transport x owner), so "this conversation"
  // would be a scope promise the user cannot verify and that does not hold.
  'customRequestFieldsScopeConversation', 'customRequestFieldsDeleteConversation',
] as const;

/** Conversation-scope key names that must not appear anywhere in the source; writing one back is another false promise. */
const forbiddenConversationScopeKeys = [
  'customRequestFieldsScopeConversation', 'customRequestFieldsDeleteConversation',
] as const;

describe('Custom request fields localization boundary', () => {
  it('groups compiler rejections into three classes; a path rejection has to answer "what may I write instead" without leaking the raw reason token', () => {
    expect(customFragmentRejectionMessage('invalid_json', [])).toEqual({ key: 'customRequestFieldsReasonSyntax' });
    expect(customFragmentRejectionMessage('duplicate_json_key', ['/a'])).toEqual({ key: 'customRequestFieldsReasonSyntax' });
    expect(customFragmentRejectionMessage('too_large', ['/a'])).toEqual({ key: 'customRequestFieldsReasonLimit' });
    // Path reasons: list the allowed set when it is non-empty; when it is empty (an owner whose schema is absent) do not print an empty list.
    for (const reason of ['unknown_owned_path', 'cross_owner', 'forbidden_root', 'forbidden_channel', 'forbidden_key', 'conflict'] as const) {
      expect(customFragmentRejectionMessage(reason, ['/enable_search', '/reasoning/effort'])).toEqual({
        key: 'customRequestFieldsNotAllowed',
        values: { fields: '/enable_search - /reasoning/effort' },
      });
      expect(customFragmentRejectionMessage(reason, [])).toEqual({ key: 'customRequestFieldsNotAllowedConflict' });
    }
    expect(Object.values(loadMessages('zh-Hans').common).join(' ')).not.toContain('unknown_owned_path');
  });

  it('keeps all 16 locale schemas equal and critical non-English copies actually translated', () => {
    const locales = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const english = loadMessages('en').common;
    for (const locale of locales) {
      const common = loadMessages(locale).common;
      for (const key of keys) expect(typeof common[key], `${locale}.${key}`).toBe('string');
      for (const key of retiredKeys) expect(common[key], `${locale}.${key} must not exist`).toBeUndefined();
      if (locale !== 'en') {
        expect(common.customRequestFieldsNoSchemaForControl, locale).not.toBe(english.customRequestFieldsNoSchemaForControl);
        expect(common.customRequestFieldsLegacyEmpty, locale).not.toBe(english.customRequestFieldsLegacyEmpty);
        expect(common.capabilityRiskPrivacy, locale).not.toBe(english.capabilityRiskPrivacy);
        expect(common.capabilityRiskCost, locale).not.toBe(english.capabilityRiskCost);
        expect(common.generationParameterTemperatureNote, locale).not.toBe(english.generationParameterTemperatureNote);
      }
      // The allowed-fields sentence is meaningless without its placeholder.
      expect(common.customRequestFieldsNotAllowed, locale).toContain('{fields}');
      // Cost and privacy must read differently, or the distinction is not being made at all.
      expect(common.capabilityRiskPrivacy, locale).not.toBe(common.capabilityRiskCost);
      // Same for the two parameter annotations: copying one into the other is the same as having none.
      expect(common.generationParameterTemperatureNote, locale).not.toBe(common.generationParameterMaxTokensNote);
    }
    // Two keys the English copy is short enough for a lazy pass to leave untranslated; they have to
    // read differently from English in a locale that is not English.
    expect(loadMessages('zh-Hans').common.customRequestFieldsCustom)
      .not.toBe(english.customRequestFieldsCustom);
    expect(loadMessages('zh-Hans').common.generationParameterTemperatureNote)
      .not.toBe(english.generationParameterTemperatureNote);
  });

  it('the editor source never references the conversation-scope variants, because the web storage key has no conversation dimension', () => {
    const source = loadEditorSource();
    for (const key of forbiddenConversationScopeKeys) {
      expect(source, `CustomRequestFieldsEditor.tsx still references ${key}`).not.toContain(`'${key}'`);
    }
    // Both the scope and the delete sentences must be the connection_model variant, with no branching on conversationId.
    expect(source).toContain(`tc('customRequestFieldsScopeConnectionModel')`);
    expect(source).toContain(`tc('customRequestFieldsDeleteConnection'`);
  });

  it('keeps the multi-owner editor usable on a narrow composer without horizontal overflow', () => {
    const css = loadEditorCSS();
    expect(css).toMatch(/\.customFields\s*\{[^}]*flex-direction:\s*column/s);
    expect(css).toMatch(/\.customTextarea\s*\{[^}]*width:\s*100%/s);
    expect(css).toMatch(/\.customPreview\s*\{[^}]*overflow:\s*auto/s);
    expect(css).toMatch(/\.customRemoveConfirm\s*\{[^}]*flex-wrap:\s*wrap/s);
    // There is no configuration-mode radio, so its styles must not linger as orphans.
    expect(css).not.toMatch(/\.customConfigurationModes/);
  });
});

function loadMessages(locale: string): { common: Record<string, string | undefined> } {
  let current = process.cwd();
  while (true) {
    const file = path.join(current, 'apps/app/messages', `${locale}.json`);
    if (existsSync(file)) return JSON.parse(readFileSync(file, 'utf8')) as { common: Record<string, string> };
    const next = path.dirname(current);
    if (next === current) throw new Error(`messages/${locale}.json`);
    current = next;
  }
}

function loadEditorSource(): string {
  return readFileSync(resolveFromWorkspace('apps/app/components/generation/CustomRequestFieldsEditor.tsx'), 'utf8');
}

function resolveFromWorkspace(relative: string): string {
  let current = process.cwd();
  while (true) {
    const file = path.join(current, relative);
    if (existsSync(file)) return file;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

function loadEditorCSS(): string {
  let current = process.cwd();
  while (true) {
    const file = path.join(current, 'apps/app/components/generation/GenerationParameterPanel.module.css');
    if (existsSync(file)) return readFileSync(file, 'utf8');
    const next = path.dirname(current);
    if (next === current) throw new Error('GenerationParameterPanel.module.css');
    current = next;
  }
}
