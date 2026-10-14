import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// User-facing strings that were whole-sentence English leftovers, untranslated button verbs,
// trade-term mistranslations of backup export/import, and skill terminology.
const ENGLISH_LEFTOVERS = [
  'pages.providerSetup.directProvidersSubtitle',
  'pages.providerSetup.kindAlreadyConnected',
  'pages.relaySetup.importBanner.title',
  'pages.relaySetup.paste.placeholder',
  'pages.relaySetup.error.unrecognized',
  'pages.relaySetup.error.empty',
  'pages.relaySetup.disableResponseStorage',
  'pages.relayDetail.disableResponseStorage',
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
      'pages.relayDetail.securityModeClearCredentialsWarning',
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
      'pages.relayDetail.serviceTier',
      'pages.relayDetail.disableResponseStorage',
      'pages.relayDetail.keyPlaceholder',
      'pages.relayDetail.valuePlaceholder',
    ];
    // "cloud" is a common loanword in de / fr / id and others (in der Cloud / dans le cloud / di cloud), so it is not a
    // leftover; flagging it once pushed translations toward in der Wolke / dans le nuage / di awan.
    const leftover = /\b(Headers|Header|Query|Params|capabilities|Reasoning|effort|Stream|Custom|Save|Edit|Apply|Undo|Keep|identity|responses|settings|suggestion)\b|\{count, (?!plural)/;
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
      'pages.relaySetup.field.serviceTier',
      'pages.relaySetup.field.disableResponseStorage',
      'pages.relaySetup.field.headers',
      'pages.relaySetup.field.queryParams',
      'pages.relaySetup.advanced.title',
      'pages.relaySetup.advanced.stream',
      'pages.relaySetup.advanced.headers',
      'pages.relaySetup.advanced.queryParams',
      'pages.relaySetup.advanced.serviceTier',
      'pages.relaySetup.advanced.disableResponseStorage',
      'pages.relaySetup.advanced.imageRoute',
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
      'pages.relaySetup.apiKeyRequired',
      'pages.relaySetup.importBanner.title',
      'pages.relaySetup.paste.title',
      'pages.relaySetup.paste.placeholder',
      'pages.relaySetup.summary.needsReview',
      'pages.relaySetup.error.unrecognized',
      'pages.relaySetup.error.empty',
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
  // Relay error guidance is the same sentence as iOS in 16 languages; the retired identity toggle and relay rate-limit guidance are removed.
  it('relay guidance keys exist in all 16 locales and retired keys are gone', () => {
    const guidance = [
      'codexIdentityRequiredSwitch', 'codexIdentityRejected', 'imageGenerationEndpointUnavailable',
      'chatCompletionsRejectedByCodexHost', 'imageResponseFormatRejected', 'upstreamUnavailable', 'modelUnavailable',
      'responsesProtocolRequired', 'storeRejected', 'serviceTierRejected', 'maxTokensRequired', 'anthropicAuthRequired',
      'imageSchemaMismatch', 'clientGated', 'webPageReturned',
    ].map((key) => `errors.relay.${key}`);
    const retired = [
      'errors.relay.codexIdentityEnable',
      'errors.relay.rateLimited',
      'pages.relayDetail.webSearchToolHintLegacy',
      'pages.relayDetail.webSearchToolHintDefault',
      'pages.relaySetup.webSearchToolHintLegacy',
      'pages.relaySetup.webSearchToolHintDefault',
    ];
    const problems: string[] = [];
    for (const locale of ['en', 'ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant']) {
      const localized = messages(locale);
      for (const key of guidance) {
        if (!localized[key]) problems.push(`${locale} ${key} missing`);
        else if (locale !== 'en' && localized[key] === english[key]) problems.push(`${locale} ${key} English`);
      }
      for (const key of retired) if (key in localized) problems.push(`${locale} ${key} still present`);
    }
    expect(problems).toEqual([]);
    const zh = messages('zh-Hans');
    expect(zh['errors.relay.clientGated']).toBe('\u8fd9\u628a\u5bc6\u94a5\u6240\u5728\u7684\u5206\u7ec4\u53ea\u5141\u8bb8\u5b98\u65b9 Claude CLI \u4f7f\u7528。\u8bf7\u5230\u7b7e\u53d1\u8fd9\u628a\u5bc6\u94a5\u7684\u7f51\u7ad9，\u5728\u8d26\u6237\u63a7\u5236\u53f0\u91cc\u628a\u5bc6\u94a5\u79fb\u5230\u5141\u8bb8 API \u8c03\u7528\u7684\u5206\u7ec4，\u6216\u65b0\u5efa\u4e00\u628a\u5bc6\u94a5\u5e76\u6dfb\u52a0\u5230 \u4f9b\u5e94\u5546 → \u8fd9\u6761\u8fde\u63a5 → API \u5bc6\u94a5，\u7136\u540e\u91cd\u8bd5。');
    expect(zh['errors.relay.webPageReturned']).toBe('\u8fd9\u6761\u8fde\u63a5\u8fd4\u56de\u7684\u662f\u7f51\u9875，\u800c\u4e0d\u662f\u6a21\u578b\u7684\u56de\u590d。\u8bf7\u68c0\u67e5\u8bf7\u6c42\u5730\u5740，\u4ee5\u53ca\u4e3a\u8fd9\u4e2a\u6a21\u578b\u8bbe\u7f6e\u7684\u534f\u8bae。');
  });
});
