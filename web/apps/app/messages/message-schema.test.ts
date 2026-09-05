import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };

function loadMessages(fileName: string): JsonValue {
  return JSON.parse(readFileSync(join(process.cwd(), 'messages', fileName), 'utf8')) as JsonValue;
}

function collectLeafPaths(value: JsonValue, prefix = ''): string[] {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return [prefix];
  }

  return Object.entries(value).flatMap(([key, child]) => {
    const nextPrefix = prefix ? `${prefix}.${key}` : key;
    return collectLeafPaths(child, nextPrefix);
  });
}

describe('app message schema', () => {
  const translationProtectionTokenPattern = /ZXPH\d+QZ|__ORIVEO_TOKEN_/i;

  it('keeps every locale on the same leaf-key schema as English', () => {
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json'))
      .sort();
    const englishPaths = collectLeafPaths(loadMessages('en.json')).sort();

    const mismatches = localeFiles.map((fileName) => {
      const localePaths = collectLeafPaths(loadMessages(fileName)).sort();
      return {
        locale: fileName.replace(/\.json$/, ''),
        missing: englishPaths.filter((path) => !localePaths.includes(path)),
        extra: localePaths.filter((path) => !englishPaths.includes(path)),
      };
    }).filter(({ missing, extra }) => missing.length > 0 || extra.length > 0);

    expect(mismatches).toEqual([]);
  });

  it('does not expose translation-protection tokens to users', () => {
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json'))
      .sort();

    const leakedTokens = localeFiles.flatMap((fileName) => {
      const messages = loadMessages(fileName);
      return collectLeafPaths(messages)
        .filter((path) => translationProtectionTokenPattern.test(String(getNestedValue(messages, path))))
        .map((path) => ({
          locale: fileName.replace(/\.json$/, ''),
          path,
        }));
    });

    expect(leakedTokens).toEqual([]);
  });


  it('does not expose translation-protection tokens in the offline fallback page', () => {
    const offlineHtml = readFileSync(join(process.cwd(), 'public', 'offline.html'), 'utf8');

    expect(offlineHtml).not.toMatch(translationProtectionTokenPattern);
  });




  it('contains the required note UI translation keys', () => {
    const requiredPaths = [
      'nav.notes',
      'contextMenu.saveAsNote',
      'pages.chat.addSelectionToNote',
      'pages.chat.replaceCurrentNote',
      'pages.chat.noteReplaced',
      'pages.chat.returnToNote',
      'pages.chat.saveAsNote',
      'pages.chat.savedNoteUntitled',
      'pages.chat.savedAsNote',
      'pages.chat.noteCaptureHint',
      'pages.chat.viewNote',
      'pages.chat.relatedNotesTitle',
      'pages.chat.attachNoteContext',
      'pages.chat.dismissNoteSuggestion',
      'pages.chat.noteAttachedToContext',
      'pages.chat.crosscheckAction',
      'sidebar.deleteConversationReferencedByNotes',
      'sidebar.deleteConversationsReferencedByNotes',
      'notes.title',
      'notes.subtitle',
      'notes.untitled',
      'notes.actions.backToNotes',
      'notes.actions.cancel',
      'notes.actions.create',
      'notes.actions.delete',
      'notes.actions.edit',
      'notes.actions.export',
      'notes.actions.newBlank',
      'notes.actions.pin',
      'notes.actions.save',
      'notes.actions.undo',
      'notes.actions.unpin',
      'notes.delete.message',
      'notes.delete.title',
      'notes.detail.body',
      'notes.detail.inTrash',
      'notes.detail.manualTitle',
      'notes.detail.notFound',
      'notes.detail.notFoundDescription',
      'notes.detail.placeholderTitle',
      'notes.detail.snapshot',
      'notes.detail.title',
      'notes.detail.userNote',
      'notes.detail.userNotePlaceholder',
      'notes.empty.body',
      'notes.empty.description',
      'notes.empty.title',
      'notes.folders.all',
      'notes.folders.delete',
      'notes.folders.deleteMessage',
      'notes.folders.edit',
      'notes.folders.moveTo',
      'notes.folders.name',
      'notes.folders.new',
      'notes.folders.rename',
      'notes.folders.uncategorized',
      'notes.labels.pinned',
      'notes.search.clear',
      'notes.search.placeholder',
      'notes.sort.createdAt',
      'notes.sort.sourceProviderKind',
      'notes.sort.updatedAt',
      'notes.source.blank',
      'notes.source.backToConversation',
      'notes.source.crosscheck',
      'notes.source.prompt',
      'notes.source.title',
      'notes.crosscheck.title',
      'notes.crosscheck.subtitle',
      'notes.crosscheck.model',
      'notes.crosscheck.run',
      'notes.crosscheck.running',
      'notes.crosscheck.original',
      'notes.crosscheck.secondOpinion',
      'notes.crosscheck.empty',
      'notes.crosscheck.save',
      'notes.crosscheck.close',
      'notes.tags.add',
      'notes.tags.filter',
      'notes.tags.remove',
      'notes.tags.title',
      'notes.tabs.label',
      'notes.tabs.notes',
      'notes.tabs.trash',
      'notes.toast.deleted',
      'notes.toast.exported',
      'notes.toast.folderCreated',
      'notes.toast.restored',
      'notes.toast.savedPlain',
      'notes.toast.trashEmptied',
      'notes.toast.view',
      'notes.trash.description',
      'notes.trash.empty',
      'notes.trash.emptyDescription',
      'notes.trash.emptyTitle',
      'notes.trash.restore',
      'notes.trash.title',
    ];
    const englishMessages = loadMessages('en.json');

    const missing = requiredPaths.filter((path) => getNestedValue(englishMessages, path) === undefined);

    expect(missing).toEqual([]);
  });

  it('keeps note entry and detail labels focused on saved chat notes', () => {
    const englishMessages = loadMessages('en.json') as { notes: { subtitle: string; detail: { body: string }; empty: { description: string } } };
    const simplifiedChineseMessages = loadMessages('zh-Hans.json') as { notes: { subtitle: string; detail: { body: string }; empty: { description: string } } };
    const traditionalChineseMessages = loadMessages('zh-Hant.json') as { notes: { detail: { body: string } } };

    expect(englishMessages.notes.detail.body).toBe('Saved note');
    expect(simplifiedChineseMessages.notes.detail.body).not.toBe(englishMessages.notes.detail.body);
    expect(traditionalChineseMessages.notes.detail.body).not.toBe(englishMessages.notes.detail.body);
    expect(englishMessages.notes.subtitle).toBe('Save chat content as notes');
    expect(simplifiedChineseMessages.notes.subtitle).not.toBe(englishMessages.notes.subtitle);
    expect(englishMessages.notes.empty.description).toBe('Save chat content as notes');
    expect(simplifiedChineseMessages.notes.empty.description).not.toBe(englishMessages.notes.empty.description);
  });

  it('keeps note capture action labels unified in every locale', () => {
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json'))
      .sort();
    const unifiedPaths = [
      'contextMenu.saveAsNote',
      'pages.chat.addSelectionToNote',
      'notes.crosscheck.save',
    ];

    const mismatches = localeFiles.flatMap((fileName) => {
      const messages = loadMessages(fileName);
      const saveAsNote = getNestedValue(messages, 'pages.chat.saveAsNote');
      return unifiedPaths
        .filter((path) => getNestedValue(messages, path) !== saveAsNote)
        .map((path) => ({
          locale: fileName.replace(/\.json$/, ''),
          path,
        }));
    });

    expect(mismatches).toEqual([]);
  });

  it('localizes the note engine copy in every non-English locale', () => {
    const noteEnginePaths = [
      'pages.chat.relatedNotesTitle',
      'pages.chat.savedAsNote',
      'pages.chat.attachNoteContext',
      'pages.chat.dismissNoteSuggestion',
      'pages.chat.noteAttachedToContext',
      'pages.chat.crosscheckAction',
      'notes.source.backToConversation',
      'notes.source.crosscheck',
      'notes.crosscheck.title',
      'notes.crosscheck.subtitle',
      'notes.crosscheck.model',
      'notes.crosscheck.run',
      'notes.crosscheck.running',
      'notes.crosscheck.original',
      'notes.crosscheck.secondOpinion',
      'notes.crosscheck.empty',
      'notes.crosscheck.save',
      'notes.crosscheck.close',
    ];
    const englishMessages = loadMessages('en.json');
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json') && name !== 'en.json')
      .sort();

    const untranslated = localeFiles.flatMap((fileName) => {
      const messages = loadMessages(fileName);
      return noteEnginePaths
        .filter((path) => getNestedValue(messages, path) === getNestedValue(englishMessages, path))
        .map((path) => ({
          locale: fileName.replace(/\.json$/, ''),
          path,
        }));
    });

    expect(untranslated).toEqual([]);
  });

  it('localizes regional endpoint setup copy in every non-English locale', () => {
    const regionalSetupPaths = [
      'pages.providerSetup.officialEndpointDescriptionMoonshot',
      'pages.providerSetup.endpointOptions.moonshot.intl',
      'pages.providerSetup.endpointOptions.moonshot.cn',
      'pages.providerSetup.officialEndpointDescriptionSiliconFlow',
      'pages.providerSetup.endpointOptions.siliconFlow.intl',
      'pages.providerSetup.endpointOptions.siliconFlow.cn',
    ];
    const englishMessages = loadMessages('en.json');
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json') && name !== 'en.json')
      .sort();

    const untranslated = localeFiles.flatMap((fileName) => {
      const messages = loadMessages(fileName);
      return regionalSetupPaths
        .filter((path) => getNestedValue(messages, path) === getNestedValue(englishMessages, path))
        .map((path) => ({
          locale: fileName.replace(/\.json$/, ''),
          path,
        }));
    });

    expect(untranslated).toEqual([]);
  });

  // P5b -   J dormant   16  
  //   {count}  
  it('keeps the dormant summary copy free of implementation jargon in every locale', () => {
    const dormantPaths = [
      'common.generationParameterDormantSummary',
      'common.generationParameterDormantView',
      'common.generationParameterDormantClear',
      'common.generationParameterDormantRestored',
    ];
    const countPlaceholderPaths = [
      'common.generationParameterDormantSummary',
      'common.generationParameterDormantRestored',
    ];
    const jargon = /dormant|frozen|hibernat/i;
    const localeFiles = readdirSync(join(process.cwd(), 'messages'))
      .filter((name) => name.endsWith('.json'))
      .sort();

    const problems = localeFiles.flatMap((fileName) => {
      const messages = loadMessages(fileName);
      return dormantPaths.flatMap((path) => {
        const value = getNestedValue(messages, path);
        const issues: string[] = [];
        if (typeof value !== 'string' || value.trim().length === 0) issues.push('missing');
        else {
          if (jargon.test(value)) issues.push('jargon');
          if (countPlaceholderPaths.includes(path) && !value.includes('{count}')) issues.push('placeholder');
        }
        return issues.map((issue) => ({ locale: fileName.replace(/\.json$/, ''), path, issue }));
      });
    });

    expect(problems).toEqual([]);
  });

  /*
   * Token  ** **  §4.9.3 
   *
   *  `l10n-coverage.mjs`   MISSING /
   * UNTRANSLATED / ENGLISH_PASSTHROUGH / VISIBLE_WIRE_ID  16  
   * 9  16   it  
   *
   *  token  
   * `Unavailable`  7/16  token  
   *  —— 
   *
   *  ** ** 
   */
  const localeMessageFiles = () => readdirSync(join(process.cwd(), 'messages'))
    .filter((name) => name.endsWith('.json'))
    .sort();

  it('keeps the token-usage missing state meaning "no data", never "unsupported"', () => {
    //   /  
    const unsupportedDirection = new RegExp([
      'desteklenmez',
      'desteklenmiyor',
      'incompatível',
      'indisponible',
      'indisponível',
      'keine unterstützung',
      'không dùng được',
      'không hỗ trợ',
      'không khả dụng',
      'kullanılam',
      'mevcut değil',
      'nicht unterstütz',
      'nicht verfüg',
      'no compatible',
      'no disponible',
      'no soportado',
      'no support',
      'non disponible',
      'non pris en charge',
      'non supporté',
      'not available',
      'not supported',
      'não disponível',
      'não suportado',
      'pas disponible',
      'pas pris en charge',
      'sem suporte',
      'sin soporte',
      'tidak didukung',
      'tidak mendukung',
      'tidak tersedia',
      'unavailable',
      'unsupported',
      'unterstützt nicht',
      'не поддержив',
      'недоступн',
      'غير متاح',
      'غير متوفر',
      'غير مدعوم',
      'لا يدعم',
      'उपलब्ध नहीं',
      'समर्थन नहीं',
      'समर्थित नहीं',
      'ใช้ไม่ได้',
      'ไม่พร้อมใช้',
      'ไม่รองรับ',
      '사용할 수 없',
      '이용할 수 없',
      '지원되지 않',
      '지원하지 않',
    ].join('|'), 'i');

    const problems = localeMessageFiles().flatMap((fileName) => {
      const value = getNestedValue(loadMessages(fileName), 'pages.chat.tokenUsage.unavailable');
      const locale = fileName.replace(/\.json$/, '');
      if (typeof value !== 'string' || value.trim().length === 0) return [{ locale, issue: 'missing' }];
      return unsupportedDirection.test(value) ? [{ locale, issue: `unsupported-direction: ${value}` }] : [];
    });

    expect(problems).toEqual([]);
  });

  it('keeps the token-usage subtitle free of any single-request promise', () => {
    //   Managed   usage   N  
    //  §4.9.3  
    const countPromise = new RegExp([
      'bu istek',
      'bu sefer',
      'cette fois',
      'cette requête',
      'diese anfrage',
      'dieses mal',
      'esta solicitação',
      'esta solicitud',
      'esta vez',
      'lần này',
      'per request',
      'permintaan ini',
      'this model request',
      'this request',
      'this time',
      'this turn',
      'yêu cầu này',
      'этот запрос',
      'هذا الطلب',
      'इस बार',
      'यह अनुरोध',
      'ครั้งนี้',
      '이 요청',
      '이번',
    ].join('|'), 'i');

    const problems = localeMessageFiles().flatMap((fileName) => {
      const value = getNestedValue(loadMessages(fileName), 'pages.chat.tokenUsage.subtitle');
      const locale = fileName.replace(/\.json$/, '');
      if (typeof value !== 'string' || value.trim().length === 0) return [{ locale, issue: 'missing' }];
      return countPromise.test(value) ? [{ locale, issue: `count-promise: ${value}` }] : [];
    });

    expect(problems).toEqual([]);
  });

  it('never merges the token-usage missing state with a capability-unsupported string', () => {
    // §4.9.3   key 
    //   key  ** **—— 
    const en = loadMessages('en.json');
    const missingState = getNestedValue(en, 'pages.chat.tokenUsage.unavailable');
    const capabilityUnsupported = getNestedValue(en, 'pages.chat.reasoning.unavailable');

    expect(typeof missingState).toBe('string');
    expect(typeof capabilityUnsupported).toBe('string');
    expect(missingState).not.toBe(capabilityUnsupported);
  });
});

function getNestedValue(value: JsonValue, path: string): JsonValue | undefined {
  return path.split('.').reduce<JsonValue | undefined>((current, key) => {
    if (!current || typeof current !== 'object' || Array.isArray(current)) {
      return undefined;
    }
    return current[key];
  }, value);
}
