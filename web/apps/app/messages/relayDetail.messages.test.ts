import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const REQUIRED_RELAY_SETUP_KEYS = [
  'kind',
  'quickTitle',
  'quickSubtitle',
  'requestURLLabel',
  'requestURLFootnote',
  'apiKeyPrivacy',
  'defaultModelRecommendedFootnote',
  'modelsFound',
  'relayDetected',
  'relayDetectionFailed',
  'verifiedProtocol',
  'probeProtocol',
  'emptyCatalog',
  'manualSetup',
  'manualSetupSubtitle',
  'detectConnectionSettings',
  'connectAndSave',
  'saveAndContinue',
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
  'testRelay',
  'testingRelay',
  'testRelayPassed',
  'testRelayFailed',
  'testRelayConnected',
  'testRelayConnectedWithModels',
  'testRelayHint',
  'endpointEmpty',
  'transport',
  'reasoningEffort',
  'serviceTier',
  'stream',
  'disableResponseStorage',
  'codexCompatIdentity',
  'customUserAgent',
  'headers',
  'queryParams',
  'addHeader',
  'removeHeader',
  'addQueryParam',
  'removeQueryParam',
  'keyPlaceholder',
  'valuePlaceholder',
] as const;

const REQUIRED_RELAY_DETAIL_KEYS = [
  'endpoint',
  'privacyNote',
  'relaySettings',
  'relaySettingsHint',
  'testRelay',
  'testingRelay',
  'testRelayPassed',
  'testRelayFailed',
  'testRelayConnected',
  'testRelayConnectedWithModels',
  'testRelayHint',
  'endpointEmpty',
  'noEndpointSet',
  'saveRelaySettings',
  'relayType',
  'transport',
  'authMode',
  'reasoningEffort',
  'serviceTier',
  'customUserAgent',
  'stream',
  'disableResponseStorage',
  'codexCompatIdentity',
  'headers',
  'queryParams',
  'addHeader',
  'removeHeader',
  'addQueryParam',
  'removeQueryParam',
  'keyPlaceholder',
  'valuePlaceholder',
  'modelKindSuggestionDetail',
  'applySuggestedKind',
  'keepCurrentKind',
  'kindChangeApplied',
  'undoKindChange',
  // Copy for the five credential states S0-S3.
  'apiKeyRequired',
  'addKey',
  'changeKey',
  'removeKey',
  'savedPlaceholder',
  'credentialNotRequired',
  'credentialNotSentNote',
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
  'connectionTypeReconnected',
] as const;

const REQUIRED_RELAY_ERROR_KEYS = [
  'codexIdentityRequiredSwitch',
  'codexIdentityEnable',
  'codexIdentityRejected',
  'chatCompletionsRejectedByCodexHost',
  'upstreamUnavailable',
  'modelUnavailable',
  'responsesProtocolRequired',
  'storeRejected',
  'serviceTierRejected',
  'maxTokensRequired',
  'anthropicAuthRequired',
  'imageSchemaMismatch',
  'rateLimited',
] as const;

const P9_ENTITY_KEYS = [
  'pages.providerSetup.customEndpoint',
  'pages.providerSetup.relaySubtitle',
  'pages.providerList.relaySection',
  'pages.providerList.noRelays',
  'pages.providerList.noRelaysHint',
  'pages.relaySetup.title',
  'pages.relaySetup.customLLMTitle',
  'pages.relayDetail.defaultName',
  'pages.relayDetail.deleteRelay',
  'pages.relayDetail.relaySettings',
  'pages.relayDetail.relayType',
  'pages.providerDetail.relayPriceDisclaimer',
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
      'pages.relayDetail.editCapabilitiesHint',
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
    expect(valueAtPath(english, 'pages.relaySetup.relayScenario')).toBe(
      'Relay service',
    );
    expectTranslated(simplifiedChinese, english, 'pages.relaySetup.relayScenario');
    expect(valueAtPath(english, 'pages.relaySetup.advancedModeHeader')).toBe(
      'Add custom LLM - Advanced',
    );
    expectTranslated(simplifiedChinese, english, 'pages.relaySetup.advancedModeHeader');
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
      'pages.relayDetail.changeKey',
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
        ...['testRelay', 'testingRelay', 'testRelayPassed', 'testRelayFailed']
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
