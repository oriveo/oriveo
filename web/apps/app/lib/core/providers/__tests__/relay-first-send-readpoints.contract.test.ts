// When the Relay protocol is undecided, every read point takes the first-send protocol.
// Fixture: shared/test-fixtures/relay/first-send-readpoints.v1.json (firstSendCases / inputRevisionCases).
// Each expect field calls the matching production function in its assertion; null = that read point is not shown.

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Attachment, type Provider, type RelayModelTransport } from '@oriveo/shared';
import { relayGenerationEndpointFingerprint } from '@oriveo/core/providers/relay-orchestrator';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { getActiveUIDSync } from '../../../infra/storage/partition';
import { getRelayRuntimeConfig } from '../../metadata/metadata-client';
import { relayFirstSendTransport } from '../relay-first-send-transport';
import { rememberRelayCatalogEndpointTypes } from '../relay-probe-candidates';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../capability-evidence-identity';
import { relayCapabilityEvidenceIdentity } from '../../chat/capability-evidence';
import { recordToolCallFallback, relayFirstSendMessagesBlockedByFiles, relayNegativeCacheModelKey } from '../../chat/relay-rejection-loop';
import { isRelayNegativeCached } from '../../chat/relay-negative-cache';
import { relayNativeFileCacheKey } from '../../attachments/attachment-transport-resolver';
import { inputNegativeCacheTarget } from '../../capability/truth/input-truth-adapter';
import { relayCatalogBoard } from '../../../../app/providers/[providerId]/relay-catalog-board';
import { relayModelAdvancedBoard } from '../../../../app/providers/[providerId]/relay-model-advanced-board';

type Protocol = 'chat' | 'responses' | 'messages';

interface FirstSendCase {
  id: string;
  connectionProtocol: 'auto' | Protocol;
  modelProtocol: Protocol | null;
  modelProtocolSource?: 'user' | 'detected';
  firstCandidate: Protocol | null;
  localEngine: boolean;
  turnFellBackToChatForFiles?: boolean;
  expect: Partial<Record<
    'firstSend' | 'inputEntry' | 'evidenceIdentity' | 'boardCatalogSource' | 'boardAutoEquals'
    | 'negativeCacheKey' | 'toolFinalTransport' | 'turnSentWith' | 'rejectionRecordedUnder',
    Protocol | null
  >>;
}

interface InputRevisionCase {
  id: string;
  key: 'vision_input' | 'file_input' | 'video_input';
  connectionEvidence: 'supported' | 'unsupported' | null;
  firstSend: Protocol;
  canonical: string;
  revision: string;
}

interface FileFallbackCase {
  id: string;
  firstSend: Protocol;
  effectiveTransport: Protocol;
  files: Array<{ hasExtractedText: boolean; messagesNative: boolean }>;
  historyFiles?: Array<{ hasExtractedText: boolean; messagesNative: boolean }>;
  images?: number;
  expect: { turnSentWith: Protocol };
}

interface Fixture {
  firstSendCases: FirstSendCase[];
  inputRevisionCases: InputRevisionCase[];
  fileFallbackCases: FileFallbackCase[];
}

function fixturePath(): string {
  let dir = process.cwd();
  for (let i = 0; i < 8; i += 1) {
    const candidate = path.join(dir, 'shared/test-fixtures/relay/first-send-readpoints.v1.json');
    if (existsSync(candidate)) return candidate;
    dir = path.dirname(dir);
  }
  throw new Error('first-send-readpoints.v1.json not found');
}

const FIXTURE = JSON.parse(readFileSync(fixturePath(), 'utf8')) as Fixture;
const NOW = Date.parse('2026-10-18T08:00:00.000Z');

const TRANSPORT: Readonly<Record<Protocol, RelayModelTransport>> = {
  chat: 'openai_chat_completions',
  responses: 'openai_responses',
  messages: 'anthropic_messages',
};
const ENDPOINT_TYPES: Readonly<Record<Protocol, string[]>> = {
  chat: ['openai'],
  responses: ['openai-response'],
  messages: ['anthropic', 'openai'],
};
const WIRE_PROTOCOL: Readonly<Record<string, Protocol>> = {
  openai_chat: 'chat',
  openai_responses: 'responses',
  anthropic: 'messages',
};
const PROTOCOLS: readonly Protocol[] = ['chat', 'responses', 'messages'];

function protocolOf(transport: string | null | undefined): Protocol | null {
  const hit = PROTOCOLS.find((protocol) => TRANSPORT[protocol] === transport);
  return hit ?? null;
}

function setupProtocolName(value: string | null | undefined): Protocol | null {
  return value ? (value.toLowerCase() as Protocol) : null;
}

function relayProvider(item: AIModel, connectionProtocol: 'auto' | Protocol): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = connectionProtocol === 'auto' ? 'auto' : TRANSPORT[connectionProtocol];
  requested.resolvedAPIBaseURL = 'https://api.firstsend.dev/v1';
  return {
    id: 'relay-first-send',
    kind: 'relay',
    customName: 'firstsend.dev',
    status: { kind: 'connected' },
    models: [item],
    catalogModels: [item],
    apiKey: 'sk-relay-first-send-0123456789',
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.firstsend.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'https://api.firstsend.dev/v1',
    relayResolvedAuthMode: 'bearer',
  };
}

/** Fixture source -> production source: detected is a protocol landed by probing (reachable, counted as an automatic result). */
const SOURCE = { user: 'user', detected: 'reachable' } as const;

function modelFor(id: string, modelProtocol: Protocol | null, source: 'user' | 'detected' | undefined, extra: Partial<AIModel> = {}): AIModel {
  return {
    id: `fs-${id}`,
    name: `fs-${id}`,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...(modelProtocol ? { relayTransport: TRANSPORT[modelProtocol], relayTransportSource: SOURCE[source ?? 'user'] } : {}),
    ...extra,
  };
}

function connectionFor(c: { id: string; connectionProtocol: 'auto' | Protocol; modelProtocol: Protocol | null; modelProtocolSource?: 'user' | 'detected'; firstCandidate: Protocol | null }, extra: Partial<AIModel> = {}) {
  const item = modelFor(c.id, c.modelProtocol, c.modelProtocolSource, extra);
  const provider = relayProvider(item, c.connectionProtocol);
  rememberRelayCatalogEndpointTypes(provider.id, c.firstCandidate ? { [item.id]: ENDPOINT_TYPES[c.firstCandidate] } : undefined);
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return { provider, model: item };
}

/** Evidence identity looks the protocol up by endpoint fingerprint: compared one by one against each protocol's production fingerprint. */
function identityProtocol(provider: Provider, model: AIModel): Protocol | null {
  const identity = relayCapabilityEvidenceIdentity(provider, model);
  if (!identity) return null;
  const hit = PROTOCOLS.find((protocol) => relayGenerationEndpointFingerprint(
    provider.baseURLText,
    model.id,
    { relayTransport: TRANSPORT[protocol] },
    getRelayRuntimeConfig(),
  ) === identity.endpointFingerprint);
  return hit ?? null;
}

function inputEntryProtocol(provider: Provider, model: AIModel): Protocol | null {
  const target = inputNegativeCacheTarget(provider, model, undefined, 'vision_input');
  if (!target) return null;
  return WIRE_PROTOCOL[target.key.wireFamily.split('.')[0]!] ?? null;
}

function cachedToolProtocol(provider: Provider, model: AIModel): Protocol | null {
  const hits = PROTOCOLS.filter((protocol) => isRelayNegativeCached(
    { connectionId: provider.id, modelId: model.id, transport: TRANSPORT[protocol], kind: 'toolCall' },
    NOW,
  ));
  return hits.length === 1 ? hits[0]! : null;
}

const TOOL_REJECTION = {
  status: 400,
  structuredError: { error: { message: 'tools is not supported by this model', type: 'invalid_request_error' } },
};

beforeEach(() => {
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe('RELAY-FIRST-SEND firstSendCases', () => {
  it('fixture is not empty', () => {
    expect(FIXTURE.firstSendCases.length).toBeGreaterThan(0);
    expect(FIXTURE.inputRevisionCases.length).toBeGreaterThan(0);
  });

  for (const c of FIXTURE.firstSendCases) {
    it(`RELAY-FIRST-SEND-${c.id}`, () => {
      expect(c.localEngine).toBe(false);
      const { provider, model } = connectionFor(c);
      const e = c.expect;
      if ('firstSend' in e) expect(protocolOf(relayFirstSendTransport(provider, model))).toBe(e.firstSend);
      if ('inputEntry' in e) expect(inputEntryProtocol(provider, model)).toBe(e.inputEntry);
      if ('evidenceIdentity' in e) expect(identityProtocol(provider, model)).toBe(e.evidenceIdentity);
      if ('boardCatalogSource' in e) {
        const catalog = relayCatalogBoard({
          provider, enabledModels: [model], catalogModels: [model], catalogLoaded: true, filter: 'all' as never, now: NOW,
        });
        const row = catalog.enabled.rows.find((item) => item.model.id === model.id);
        expect(setupProtocolName(row?.protocol)).toBe(e.boardCatalogSource);
      }
      if ('boardAutoEquals' in e) {
        const row = relayModelAdvancedBoard({ provider, model, now: NOW }).protocolRow;
        expect(row.kind).toBe('relay');
        const relayRow = row as Extract<typeof row, { kind: 'relay' }>;
        // When the connection is decided it reads as "follow connection", not the "Auto =" read point.
        const shown = relayRow.autoEquals && !relayRow.autoEqualsConnectionDefault ? relayRow.autoEquals : null;
        expect(setupProtocolName(shown)).toBe(e.boardAutoEquals);
      }
      if ('negativeCacheKey' in e) expect(protocolOf(relayNegativeCacheModelKey(provider, model)?.transport)).toBe(e.negativeCacheKey);
      if ('toolFinalTransport' in e) {
        const identity = {
          accountId: 'account-a', connectionId: provider.id, authMode: 'bearer', canonicalModelId: model.id, finalTransport: 'unknown',
        };
        recordToolCallFallback(provider, model, identity, TOOL_REJECTION, undefined, NOW);
        expect(cachedToolProtocol(provider, model)).toBe(e.toolFinalTransport);
      }
      if ('turnSentWith' in e) {
        const sent = relayFirstSendTransport(provider, model, { messagesBlockedByFiles: c.turnFellBackToChatForFiles === true });
        expect(protocolOf(sent)).toBe(e.turnSentWith);
        if ('rejectionRecordedUnder' in e) {
          expect(protocolOf(relayNativeFileCacheKey(provider, model, sent)?.transport)).toBe(e.rejectionRecordedUnder);
          const identity = {
            accountId: 'account-a', connectionId: provider.id, authMode: 'bearer', canonicalModelId: model.id, finalTransport: 'unknown',
          };
          recordToolCallFallback(provider, model, identity, TOOL_REJECTION, sent, NOW);
          expect(cachedToolProtocol(provider, model)).toBe(e.rejectionRecordedUnder);
        }
      }
    });
  }
});

const PDF_BASE64 = 'JVBERi0xLjQKRmlsZUZhbGxiYWNr';

/** One fixture file -> an attachment: hasExtractedText decides the body and the error code; messagesNative decides the model allowlist and the original bytes. */
function fileAttachment(index: number, file: FileFallbackCase['files'][number]): Attachment {
  return {
    id: `file-${index}`,
    kind: 'file',
    fileName: `doc-${index}.pdf`,
    mimeType: 'application/pdf',
    base64Data: file.hasExtractedText ? 'extracted body text' : '',
    ...(file.hasExtractedText ? {} : { extractionErrorCode: 'scanned_pdf' }),
    ...(file.messagesNative ? { originalBase64Data: PDF_BASE64 } : {}),
  } as Attachment;
}

function imageAttachment(index: number): Attachment {
  return { id: `image-${index}`, kind: 'image', fileName: `img-${index}.png`, mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
}

describe('RELAY-FIRST-SEND fileFallbackCases', () => {
  it('fixture is not empty', () => {
    expect(FIXTURE.fileFallbackCases.length).toBeGreaterThan(0);
  });

  for (const c of FIXTURE.fileFallbackCases) {
    it(`RELAY-FIRST-SEND-${c.id}`, async () => {
      const history = c.historyFiles ?? [];
      const native = [...c.files, ...history].some((file) => file.messagesNative);
      const { provider, model } = connectionFor(
        { id: c.id, connectionProtocol: 'auto', modelProtocol: null, firstCandidate: c.firstSend },
        native ? { nativeFileMimes: ['application/pdf'] } : {},
      );
      expect(protocolOf(relayFirstSendTransport(provider, model))).toBe(c.firstSend);
      const attachments = [
        ...c.files.map((file, index) => fileAttachment(index, file)),
        ...Array.from({ length: c.images ?? 0 }, (_, index) => imageAttachment(index)),
      ];
      // historyFiles lands on an earlier outbound message: the criterion looks at the whole outbound history
      const historyMessages = history.length > 0
        ? [{ attachments: history.map((file, index) => fileAttachment(c.files.length + index, file)) }]
        : [];
      const messagesBlockedByFiles = await relayFirstSendMessagesBlockedByFiles({
        provider, model, messages: [...historyMessages, { attachments }], streamOptions: undefined,
      });
      expect(protocolOf(relayFirstSendTransport(provider, model, { messagesBlockedByFiles }))).toBe(c.expect.turnSentWith);
    });
  }
});

describe('RELAY-FIRST-SEND inputRevisionCases', () => {
  for (const c of FIXTURE.inputRevisionCases) {
    it(`RELAY-FIRST-SEND-${c.id}`, () => {
      const evidence = c.connectionEvidence
        ? { relayCapabilityOverrides: { image: { value: c.connectionEvidence === 'supported', source: 'tested' } } } as Partial<AIModel>
        : {};
      const { provider, model } = connectionFor(
        { id: c.id, connectionProtocol: 'auto', modelProtocol: null, firstCandidate: c.firstSend },
        evidence,
      );
      expect(protocolOf(relayFirstSendTransport(provider, model))).toBe(c.firstSend);
      const target = inputNegativeCacheTarget(provider, model, undefined, c.key);
      expect(target).not.toBeNull();
      const canonical = JSON.parse(c.canonical) as { wireFamily: string };
      expect(target!.key.wireFamily).toBe(canonical.wireFamily);
      expect(target!.verdictRevision).toBe(c.revision);
      expect(target!.verdictRevision).not.toBe('857ae8b4');
    });
  }
});
