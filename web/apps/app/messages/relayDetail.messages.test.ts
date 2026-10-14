import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const REQUIRED_RELAY_SETUP_KEYS = [
  'requestURLLabel',
  'apiKeyPrivacy',
  'modelsFound',
  'verifiedProtocol',
  'probeProtocol',
  'emptyCatalog',
  'manualSetup',
  'detectConnectionSettings',
  'connectAndSave',
  'noProtocolVerified',
  'embeddedQuery',
  'authenticationRejected',
  'relayRateLimited',
  'temporaryFailure',
  'networkFailure',
  'routeUnavailable',
  'automaticRetries',
  'attemptedRequests',
  'networkStatus',
  'upstreamDiagnostic',
  'invalidResponse',
  'connectionUnverified',
  'invalidRequestURL',
  'testRelayFailed',
  'endpointEmpty',
  'transport',
  'serviceTier',
  'stream',
  'disableResponseStorage',
  'codexCompatIdentity',
  'customUserAgent',
  'headers',
  'queryParams',
] as const;

const REQUIRED_RELAY_DETAIL_KEYS = [
  'endpoint',
  'privacyNote',
  'testRelay',
  'testingRelay',
  'testRelayFailed',
  'endpointEmpty',
  'transport',
  'authMode',
  'serviceTier',
  'disableResponseStorage',
  'headers',
  'queryParams',
  // Screen-reader names of the delete buttons for headers / query params in the edit-connection page
  // (RelayEditConnection picks the key with a ternary over a template string).
  'removeHeader',
  'removeQueryParam',
  'keyPlaceholder',
  'valuePlaceholder',
  // Copy for the five credential states S0-S3.
  'apiKeyRequired',
  'addKey',
  'removeKey',
  'savedPlaceholder',
  'cleartextCredentialsBlocked',
  'clearAndStay',
  'connectionType',
  'changeConnectionType',
  'changeConnectionTypeShort',
  'connectionTypeHint',
  'connectionTypeSuggestion',
  'connectionTypeRemoteHttps',
  'connectionTypePairedHttps',
  'connectionTypePairedHttpsDesc',
  'connectionTypeRemoteHttpsDesc',
  'connectionTypeLocalHttp',
  'connectionTypeLocalHttpDesc',
  'connectionTypePrivateVpn',
  'connectionTypePrivateVpnDesc',
  'confirmPlainHttpTitle',
  'securityModeClearCredentialsWarning',
  'securityModePlainHttpWarning',
  'clearCredentialsAndSwitch',
  'switchToHttpsConnection',
  'confirmPlainHttp',
  'connectionTypePublicDisabled',
  'connectionTypeInvalidAddress',
  'authModeNone',
] as const;

const REQUIRED_RELAY_ERROR_KEYS = [
  'codexIdentityRequiredSwitch',
  'codexIdentityRejected',
  'imageGenerationEndpointUnavailable',
  'chatCompletionsRejectedByCodexHost',
  'imageResponseFormatRejected',
  'upstreamUnavailable',
  'modelUnavailable',
  'responsesProtocolRequired',
  'storeRejected',
  'serviceTierRejected',
  'maxTokensRequired',
  'anthropicAuthRequired',
  'imageSchemaMismatch',
  'clientGated',
  'webPageReturned',
] as const;

const P9_ENTITY_KEYS = [
  'pages.providerSetup.customEndpoint',
  'pages.providerSetup.relaySubtitle',
  'pages.relaySetup.title',
  'library.confirm.unknown_relay.title',
  'library.confirm.unknown_relay.message',
] as const;

function valueAtPath(messages: unknown, path: string): unknown {
  return path
    .split('.')
    .reduce<unknown>(
      (value, key) =>
        value && typeof value === 'object'
          ? (value as Record<string, unknown>)[key]
          : undefined,
      messages,
    );
}

describe('relayDetail message coverage', () => {
  it('does not ship the English source for relay capability hints or user-facing stream errors', () => {
    const files = readdirSync(join(process.cwd(), 'messages')).filter((file) => file.endsWith('.json'));
    const english = JSON.parse(readFileSync(join(process.cwd(), 'messages/en.json'), 'utf8')) as unknown;
    const paths = [
      'errors.relayStreamError.moderation',
      'errors.relayStreamError.imageGenUser',
    ];

    for (const file of files) {
      if (file === 'en.json') continue;
      const messages = JSON.parse(readFileSync(join(process.cwd(), 'messages', file), 'utf8')) as unknown;
      for (const path of paths) {
        expect(valueAtPath(messages, path), `${file} translates ${path}`)
          .not.toBe(valueAtPath(english, path));
      }
    }
  });
  it('uses approved Custom LLM entry copy in production message files', () => {
    const messagesDir = existsSync(join(process.cwd(), 'messages'))
      ? join(process.cwd(), 'messages')
      : join(process.cwd(), 'apps/app/messages');
    const byLocale = new Map(
      readdirSync(messagesDir)
        .filter((name) => name.endsWith('.json'))
        .sort()
        .map((fileName) => [
          fileName.replace(/\.json$/, ''),
          JSON.parse(
            readFileSync(join(messagesDir, fileName), 'utf8'),
          ) as unknown,
        ]),
    );
    const english = byLocale.get('en');
    const simplifiedChinese = byLocale.get('zh-Hans');
    // A translated locale must carry its own non-empty copy for each entity name,
    // not fall back to the English source string.
    const expectTranslated = (locale: unknown, source: unknown, path: string) => {
      const value = valueAtPath(locale, path);
      expect(typeof value).toBe('string');
      expect((value as string).trim().length).toBeGreaterThan(0);
      expect(value).not.toBe(valueAtPath(source, path));
    };

    expect(valueAtPath(english, 'pages.providerSetup.customEndpoint')).toBe(
      'Custom Relay',
    );
    expectTranslated(simplifiedChinese, english, 'pages.providerSetup.customEndpoint');
    expect(valueAtPath(english, 'pages.providerSetup.relayEndpointLabel')).toBe(
      'Request URL',
    );
    expectTranslated(simplifiedChinese, english, 'pages.providerSetup.relayEndpointLabel');
    expect(valueAtPath(english, 'pages.relayDetail.connectionType')).toBe(
      'Connection security',
    );
    expectTranslated(simplifiedChinese, english, 'pages.relayDetail.connectionType');

    const missing = [...byLocale.entries()].flatMap(([locale, messages]) =>
      P9_ENTITY_KEYS.filter(
        (path) =>
          typeof valueAtPath(messages, path) !== 'string' ||
          valueAtPath(messages, path) === '',
      ).map((path) => `${locale}:${path}`),
    );
    expect(missing).toEqual([]);

    for (const path of [
      'pages.relayDetail.connectionTitle',
    ]) {
      const sourceValue = valueAtPath(english, path);
      const untranslated = [...byLocale.entries()]
        .filter(
          ([locale, messages]) =>
            locale !== 'en' && valueAtPath(messages, path) === sourceValue,
        )
        .map(([locale]) => `${locale}:${path}`);
      expect(untranslated).toEqual([]);
    }
  });

  it('includes privacy disclosure copy in every locale', () => {
    const messagesDir = existsSync(join(process.cwd(), 'messages'))
      ? join(process.cwd(), 'messages')
      : join(process.cwd(), 'apps/app/messages');
    const localeFiles = readdirSync(messagesDir)
      .filter((name) => name.endsWith('.json'))
      .sort();

    const missingByLocale = localeFiles.map((fileName) => {
      const filePath = join(messagesDir, fileName);
      const messages = JSON.parse(readFileSync(filePath, 'utf8')) as {
        pages?: {
          relaySetup?: Record<string, unknown>;
          relayDetail?: Record<string, string>;
        };
        errors?: {
          relay?: Record<string, unknown>;
        };
      };
      const relaySetup = messages.pages?.relaySetup ?? {};
      const relayDetail = messages.pages?.relayDetail ?? {};
      const relayErrors = messages.errors?.relay ?? {};
      const missingSetupKeys = REQUIRED_RELAY_SETUP_KEYS.filter((key) => !(key in relaySetup));
      const missingDetailKeys = REQUIRED_RELAY_DETAIL_KEYS.filter((key) => !(key in relayDetail));
      const missingRelayErrorKeys = REQUIRED_RELAY_ERROR_KEYS.filter((key) => !(key in relayErrors));

      return {
        locale: fileName.replace(/\.json$/, ''),
        missingKeys: [
          ...missingSetupKeys.map((key) => `relaySetup.${key}`),
          ...missingDetailKeys.map((key) => `relayDetail.${key}`),
          ...missingRelayErrorKeys.map((key) => `errors.relay.${key}`),
        ],
      };
    }).filter((entry) => entry.missingKeys.length > 0);

    expect(missingByLocale).toEqual([]);
  });

  it('keeps setup and detail privacy disclosures identical in every locale', () => {
    const messagesDir = existsSync(join(process.cwd(), 'messages'))
      ? join(process.cwd(), 'messages')
      : join(process.cwd(), 'apps/app/messages');
    const mismatches = readdirSync(messagesDir)
      .filter((name) => name.endsWith('.json'))
      .sort()
      .flatMap((fileName) => {
        const messages = JSON.parse(readFileSync(join(messagesDir, fileName), 'utf8')) as {
          pages?: {
            relaySetup?: { apiKeyPrivacy?: string };
            relayDetail?: { privacyNote?: string };
          };
        };
        return messages.pages?.relaySetup?.apiKeyPrivacy === messages.pages?.relayDetail?.privacyNote
          ? []
          : [fileName];
      });

    expect(mismatches).toEqual([]);
  });

  it('does not leave relay test controls untranslated in non-English locales', () => {
    const messagesDir = existsSync(join(process.cwd(), 'messages'))
      ? join(process.cwd(), 'messages')
      : join(process.cwd(), 'apps/app/messages');
    const localeFiles = readdirSync(messagesDir)
      .filter((name) => name.endsWith('.json') && name !== 'en.json')
      .sort();
    const englishFallbacks = new Set([
      'Test connection',
      'Testing...',
      'Testing…',
      'Connection test passed.',
      'Connection test passed',
      'Connection test failed.',
      'Connection test failed',
    ]);

    const untranslatedByLocale = localeFiles.map((fileName) => {
      const filePath = join(messagesDir, fileName);
      const messages = JSON.parse(readFileSync(filePath, 'utf8')) as {
        pages?: {
          relaySetup?: Record<string, unknown>;
          relayDetail?: Record<string, unknown>;
        };
      };
      const relaySetup = messages.pages?.relaySetup ?? {};
      const relayDetail = messages.pages?.relayDetail ?? {};
      const untranslatedKeys = [
        ...['testRelayFailed']
          .filter((key) => englishFallbacks.has(String(relaySetup[key])))
          .map((key) => `relaySetup.${key}`),
        ...['testRelay', 'testingRelay', 'testRelayPassed', 'testRelayFailed']
          .filter((key) => englishFallbacks.has(String(relayDetail[key])))
          .map((key) => `relayDetail.${key}`),
      ];

      return {
        locale: fileName.replace(/\.json$/, ''),
        untranslatedKeys,
      };
    }).filter((entry) => entry.untranslatedKeys.length > 0);

    expect(untranslatedByLocale).toEqual([]);
  });

});

/** Cleanup map (web entries): unreferenced keys are deleted, and keys that have an iOS counterpart take the iOS value verbatim (en / zh-Hans spot check; other locales are not the English source). */
const REMOVED_KEYS = [
  'pages.providerDetail.relayPriceDisclaimer',
  'pages.providerList.noRelays',
  'pages.providerList.noRelaysHint',
  'pages.providerList.relaySection',
  'pages.relayDetail.defaultName',
  'pages.relayDetail.deleteRelay',
  'pages.relayDetail.editCapabilitiesHint',
  'pages.relayDetail.noModels',
  'pages.relaySetup.advancedModeHeader',
  'pages.relaySetup.apiKey.helper',
  'pages.relaySetup.customLLMTitle',
  'pages.relaySetup.family',
  'pages.relaySetup.relayDetected',
  'pages.relaySetup.relayDetectionFailed',
] as const;

const MAPPED_EN: Record<string, string> = {
  'library.confirm.unknown_relay.title': 'Confirm unrecognized connection',
  'library.confirm.unknown_relay.message': "Oriveo couldn't identify the service behind this connection, so token usage and cost may be harder to predict.",
  'pages.relayDetail.noModelsHint': 'No models added yet. Use the button below to add model IDs.',
  'pages.relaySetup.probeProtocol': 'Couldn\u2019t get the model list. Add the model IDs you want to use.',
  'pages.relaySetup.relayRateLimited': "The service at this address is rate limiting requests. Wait a moment and try again; Oriveo didn't switch to another key or protocol.",
  'pages.relaySetup.temporaryFailure': "Couldn't connect to this address reliably. Check the address and try again.",
  'pages.relaySetup.networkFailure': "Couldn't connect to this address reliably. Check the address and try again.",
};

describe('relay copy cleanup', () => {
  const dir = join(process.cwd(), 'messages');
  const locales = readdirSync(dir).filter((file) => file.endsWith('.json'));
  const load = (file: string) => JSON.parse(readFileSync(join(dir, file), 'utf8')) as unknown;

  it('deletes unreferenced cleanup keys from all 16 locales', () => {
    expect(locales).toHaveLength(16);
    for (const file of locales) {
      const messages = load(file);
      for (const key of REMOVED_KEYS) {
        expect(valueAtPath(messages, key), `${file} ${key}`).toBeUndefined();
      }
    }
  });

  it('keys with an iOS counterpart take the iOS value: en verbatim, other locales translated with no placeholder', () => {
    const english = load('en.json');
    for (const [key, value] of Object.entries(MAPPED_EN)) {
      expect(valueAtPath(english, key), key).toBe(value);
    }
    const zh = load('zh-Hans.json');
    expect(valueAtPath(zh, 'pages.relaySetup.probeProtocol')).not.toContain('{protocol}');
    for (const file of locales) {
      if (file === 'en.json') continue;
      const messages = load(file);
      for (const key of Object.keys(MAPPED_EN)) {
        const value = valueAtPath(messages, key);
        expect(typeof value, `${file} ${key}`).toBe('string');
        expect(value, `${file} ${key}`).not.toBe(MAPPED_EN[key]);
        expect(value as string, `${file} ${key}`).not.toMatch(/\{protocol\}/);
      }
    }
  });
});
