import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// User-facing strings that were whole-sentence English leftovers, untranslated button verbs,
// trade-term mistranslations of backup export/import, and skill terminology.
const ENGLISH_LEFTOVERS = [
  'pages.providerSetup.directProvidersSubtitle',
  'pages.providerSetup.kindAlreadyConnected',
  'pages.relaySetup.saveAndStartChat',
  'pages.relaySetup.importBanner.title',
  'pages.relaySetup.paste.placeholder',
  'pages.relaySetup.summary.willApplyEmpty',
  'pages.relaySetup.error.parseFailed',
  'pages.relaySetup.error.unrecognized',
  'pages.relaySetup.error.empty',
  'pages.relaySetup.disableResponseStorage',
  'pages.relayDetail.disableResponseStorage',
  'pages.relayDetail.modelKindSuggestionDetail',
  'pages.backup.knowledgeReuploadNotice',
  'mobileHome.greeting',
  'mobileHome.subtitle',
];

function flat(value: unknown, prefix = ''): Record<string, string> {
  if (typeof value === 'string') return { [prefix]: value };
  if (!value || typeof value !== 'object') return {};
  const out: Record<string, string> = {};
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    Object.assign(out, flat(child, prefix ? `${prefix}.${key}` : key));
  }
  return out;
}

function messages(locale: string): Record<string, string> {
  return flat(JSON.parse(readFileSync(join(process.cwd(), 'messages', `${locale}.json`), 'utf8')));
}

function placeholders(text: string): string[] {
  return [...text.matchAll(/\{[^{}]+\}/g)].map((match) => match[0]).sort();
}

describe('follow-up copy', () => {
  const english = messages('en');

  it.each(['th', 'vi'])('%s has no whole-sentence English leftover', (locale) => {
    const localized = messages(locale);
    const problems = ENGLISH_LEFTOVERS.filter((key) => localized[key] === english[key]);
    expect(problems).toEqual([]);
  });

  it.each(['th', 'vi'])('%s keeps the English placeholders on that list', (locale) => {
    const localized = messages(locale);
    const problems = ENGLISH_LEFTOVERS.filter((key) => placeholders(localized[key] ?? '').join('|') !== placeholders(english[key] ?? '').join('|'));
    expect(problems).toEqual([]);
  });

  it('provider setup labels are not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'pages.providerSetup.directProvidersTitle',
      'pages.providerSetup.directProvidersSubtitle',
      'pages.providerSetup.aggregatorsTitle',
      'pages.providerSetup.aggregatorsSubtitle',
      'pages.providerSetup.kindAlreadyConnected',
      'pages.providerSetup.manageExisting',
      'pages.providerSetup.addAnotherAccount',
    ];
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        if (value === english[key]) problems.push(`${locale} ${key}`);
        else if (placeholders(localized[key] ?? '').join('|') !== placeholders(english[key] ?? '').join('|')) {
          problems.push(`${locale} ${key} placeholders`);
        }
      }
    }
    expect(problems).toEqual([]);
  });

  it('mobile home greeting is not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'mobileHome.greeting',
      'mobileHome.greetingName',
      'mobileHome.subtitle',
      'mobileHome.newChat',
      'mobileHome.quickStart',
      'mobileHome.composerPlaceholder',
    ];
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        if (value === english[key]) problems.push(`${locale} ${key}`);
        else if (placeholders(localized[key] ?? '').join('|') !== placeholders(english[key] ?? '').join('|')) {
          problems.push(`${locale} ${key} placeholders`);
        }
      }
    }
    expect(problems).toEqual([]);
  });

  it('relay confirm and model-count copy is not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'pages.relayDetail.privacyNote',
      'pages.relayDetail.confirmKindChangeTitle',
      'pages.relayDetail.confirmKindChangeDesc',
      'pages.relayDetail.securityModeClearCredentialsWarning',
      'pages.relayDetail.codexCompatIdentitySubtitle',
      'pages.relayDetail.webSearchToolHintDefault',
      'pages.relayDetail.webSearchToolHintLegacy',
      'pages.relayDetail.noModelsHint',
      'pages.relayDetail.addModelsConfirm',
    ];
    const leftover = /Custom LLM|\bHeaders?\b|\bheaders\b|\bQuery\b|response storage|service tier|Model IDs?|\bModels\b|\{count, (?!plural)/;
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        if (value === english[key] || leftover.test(value)) problems.push(`${locale} ${key}`);
        if (key.endsWith('addModelsConfirm') && !value.includes('{count, plural')) problems.push(`${locale} ${key} icu`);
      }
    }
    expect(problems).toEqual([]);
  });

  it('relay detail copy is not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'pages.relayDetail.modelsCount',
      'pages.relayDetail.editCapabilities',
      'pages.relayDetail.editCapabilitiesTitle',
      'pages.relayDetail.saveCapabilities',
      'pages.relayDetail.saveRelaySettings',
      'pages.relayDetail.reasoningEffort',
      'pages.relayDetail.serviceTier',
      'pages.relayDetail.customUserAgent',
      'pages.relayDetail.stream',
      'pages.relayDetail.disableResponseStorage',
      'pages.relayDetail.codexCompatIdentity',
      'pages.relayDetail.headers',
      'pages.relayDetail.queryParams',
      'pages.relayDetail.addHeader',
      'pages.relayDetail.removeHeader',
      'pages.relayDetail.addQueryParam',
      'pages.relayDetail.removeQueryParam',
      'pages.relayDetail.keyPlaceholder',
      'pages.relayDetail.valuePlaceholder',
      'pages.relayDetail.modelKindSuggestionDetail',
      'pages.relayDetail.applySuggestedKind',
      'pages.relayDetail.keepCurrentKind',
      'pages.relayDetail.undoKindChange',
    ];
    const leftover = /\b(Headers|Header|Query|Params|capabilities|Reasoning|effort|Stream|Custom|Save|Edit|Apply|Undo|Keep|identity|responses|cloud|settings|suggestion)\b|\{count, (?!plural)/;
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        if (value === english[key] || leftover.test(value)) problems.push(`${locale} ${key}`);
        if (key === 'pages.relayDetail.modelsCount' && !value.includes('{count, plural')) problems.push(`${locale} ${key} icu`);
      }
    }
    expect(problems).toEqual([]);
  });

  it('relay advanced copy is not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'pages.relaySetup.field.model',
      'pages.relaySetup.field.reasoningEffort',
      'pages.relaySetup.field.serviceTier',
      'pages.relaySetup.field.disableResponseStorage',
      'pages.relaySetup.field.defaultModel',
      'pages.relaySetup.field.headers',
      'pages.relaySetup.field.queryParams',
      'pages.relaySetup.advanced.title',
      'pages.relaySetup.advanced.stream',
      'pages.relaySetup.advanced.headers',
      'pages.relaySetup.advanced.queryParams',
      'pages.relaySetup.advanced.reasoningEffort',
      'pages.relaySetup.advanced.serviceTier',
      'pages.relaySetup.advanced.serviceTierHelp',
      'pages.relaySetup.advanced.disableResponseStorage',
      'pages.relaySetup.advanced.imageSection',
      'pages.relaySetup.advanced.imageEnable',
      'pages.relaySetup.advanced.imageRoute',
      'pages.relaySetup.advanced.imageRouteSameModel',
      'pages.relaySetup.advanced.imageRouteToolModel',
      'pages.relaySetup.advanced.imageToolModel',
      'pages.relaySetup.advanced.imageOutputFormat',
      'pages.relaySetup.advanced.webSearchToolName',
    ];
    const leftover = /\b(Advanced|Extra|Headers|Header|Disable|Enable|Only|Reasoning|Effort|Stream|Query|Params|Storage|forwarded|response|generation|Dedicated|Output|Default|route|tool)\b|\bService\b(?!-)|Usage Insights|Service [Tt]ier|Same model|Web search/;
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        // In Indonesian and Turkish the field label really is "Model"; native review confirmed it reads as the word for model.
        if ((locale === 'id' || locale === 'tr') && key === 'pages.relaySetup.field.model') continue;
        if (value === english[key] || leftover.test(value)) problems.push(`${locale} ${key}`);
      }
    }
    expect(problems).toEqual([]);
  });

  it('relay setup import copy is not leftover English', () => {
    const locales = ['ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant'];
    const keys = [
      'pages.relaySetup.saveAndStartChat',
      'pages.relaySetup.apiKeyRequired',
      'pages.relaySetup.pasteCcSwitchAction',
      'pages.relaySetup.backToSimple',
      'pages.relaySetup.importBanner.title',
      'pages.relaySetup.paste.title',
      'pages.relaySetup.paste.placeholder',
      'pages.relaySetup.paste.fromClipboard',
      'pages.relaySetup.detected.pasteAnother',
      'pages.relaySetup.detected.requiredBelow',
      'pages.relaySetup.apiKey.notInConfig',
      'pages.relaySetup.summary.needsReview',
      'pages.relaySetup.summary.willApplyEmpty',
      'pages.relaySetup.summary.needsReviewEmpty',
      'pages.relaySetup.summary.ignoredEmpty',
      'pages.relaySetup.error.parseFailed',
      'pages.relaySetup.error.unrecognized',
      'pages.relaySetup.error.empty',
      'pages.relaySetup.summary.fieldCount',
    ];
    const leftover = /\b(Save|Paste|Nothing|Import|Back|We|Enter|Try)\b|Simple Mode|Needs Review|bewerben|postuler|للتقديم|\bfields?\b/;
    const problems: string[] = [];
    for (const locale of locales) {
      const localized = messages(locale);
      for (const key of keys) {
        const value = localized[key] ?? '';
        if (value === english[key] || leftover.test(value)) problems.push(`${locale} ${key}`);
      }
    }
    expect(problems).toEqual([]);
  });

  it('fixes the listed button, retry, and trade-term strings', () => {
    const hi = messages('hi');
    const ru = messages('ru');
    const tr = messages('tr');
    const id = messages('id');
    const vi = messages('vi');
    expect(hi['pages.providerDetail.recoveryCard.retry']).not.toBe('Retry');
    expect(hi['pages.relaySetup.field.model']).not.toBe('Model');
    expect(ru['common.save']).not.toBe('Сохранять');
    expect(ru['common.confirm']).not.toBe('Подтверждать');
    expect(tr['common.delete']).not.toBe('Silmek');
    expect(id['common.delete']).not.toBe('Menghapus');
    expect(tr['pages.backup.export']).not.toBe('İhracat');
    expect(tr['pages.backup.import']).not.toBe('İçe aktarmak');
    expect(vi['pages.backup.export']).not.toBe('Xuất khẩu');
    expect(vi['pages.backup.import']).not.toBe('Nhập khẩu');
    expect(hi['pages.backup.export']).not.toBe('निर्यात');
    expect(hi['pages.backup.import']).not.toBe('आयात');
    expect(tr['skills.title']).not.toBe('Yetenekler');
    expect(tr['skills.newSkill']).toContain('Beceri');
    expect(tr['skills.editSkill'].toLowerCase()).toContain('beceri');
  });
});
