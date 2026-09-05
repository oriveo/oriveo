import { describe, expect, it } from 'vitest';
import {
  ALLOWED_CHANNELS,
  CHANNELS,
  ERROR_CODE_META,
  IPC_ERROR_CODES,
  RENDERER_SEND_CHANNELS,
  RENDERER_INVOKE_CHANNELS,
  type MainWindowStatePatch,
  type ShellOpenExternalRequest,
  type ShellSetMenuLabelsRequest,
  type ChatStreamRequest,
  type IpcStreamEvent,
  type ProviderValidateRequest,
  type RelayForwardRequest,
  type ShellMenuCommand,
  type WindowState,
  createPartitionedKeyRef,
  isPartitionedKeyRef,
  codeForProviderError,
  codeForProviderErrorKind,
  flattenChannels,
  toIpcError,
} from './index';

describe('desktop IPC contract', () => {
  it('uses partition-scoped opaque key refs and rejects legacy global provider IDs', () => {
    const ref = createPartitionedKeyRef('user-A', 'same/provider');
    expect(ref).toBe('oriveo-kv:1:user-A:same%2Fprovider');
    expect(isPartitionedKeyRef(ref)).toBe(true);
    expect(isPartitionedKeyRef('same/provider')).toBe(false);
    expect(isPartitionedKeyRef('oriveo-kv:1:user-A:same/provider')).toBe(false);
  });

  it('keeps key channels write-only from renderer by never exposing keys:get', () => {
    expect(CHANNELS.keys).toEqual({
      set: 'keys:set',
      has: 'keys:has',
      delete: 'keys:delete',
      preview: 'keys:preview',
    });
    expect('get' in CHANNELS.keys).toBe(false);
    expect(ALLOWED_CHANNELS.has('keys:get' as never)).toBe(false);
  });

  it('keeps a registry of every channel leaf while narrowing renderer invoke exposure', () => {
    const leaves = flattenChannels(CHANNELS);
    expect(ALLOWED_CHANNELS).toEqual(new Set([...RENDERER_INVOKE_CHANNELS, ...RENDERER_SEND_CHANNELS]));
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.chat.start)).toBe(true);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.provider.clearUnsupportedParamLearning)).toBe(true);
    expect(RENDERER_SEND_CHANNELS.has(CHANNELS.chat.cancel)).toBe(true);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.sync.stateChanged)).toBe(false);
    expect(RENDERER_SEND_CHANNELS.has(CHANNELS.sync.stateChanged)).toBe(false);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.updater.status)).toBe(false);
    // updater.* is off the renderer allow list entirely: there is no main handler and the check
    // runs in the background only. The channel definitions stay for later reuse, and since no
    // allow list contains them there are no dangling channels.
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.updater.check)).toBe(false);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.updater.download)).toBe(false);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.updater.install)).toBe(false);
    expect(RENDERER_SEND_CHANNELS.has(CHANNELS.updater.cancel)).toBe(false);
    expect(leaves).toContain('chat:stream:start');
    expect(leaves).toContain('chat:stream:cancel');
    expect(leaves).toContain('relay:forward:start');
    expect(leaves).toContain('skills:knowledge:retrieve:start');
    expect(leaves).toContain('shell:persist-window-state');
    expect(leaves).toContain('shell:menu-command');
  });

  it('keeps channel names unique and in the documented namespace format', () => {
    const leaves = flattenChannels(CHANNELS);
    expect(new Set(leaves).size).toBe(leaves.length);
    for (const channel of leaves) {
      expect(channel).toMatch(/^[a-z]+(:[a-z-]+)+$/);
    }
  });

  it('defines retry metadata for every IPC error code', () => {
    expect(Object.keys(ERROR_CODE_META).sort()).toEqual([...IPC_ERROR_CODES].sort());
    expect(ERROR_CODE_META.IPC_PROVIDER_QUOTA).toMatchObject({
      i18nKey: 'error.providerQuota',
      retryable: false,
      quotaSource: 'provider',
    });
    expect(ERROR_CODE_META.IPC_ENTITLEMENT_QUOTA.quotaSource).toBe('entitlement');
    expect(ERROR_CODE_META.IPC_SSRF_BLOCKED.retryable).toBe(false);
    expect(ERROR_CODE_META.IPC_UPSTREAM_NETWORK.retryable).toBe(true);
  });

  it('maps provider error kinds into the top-level IPC transport errors', () => {
    expect(codeForProviderErrorKind('invalidKey')).toBe('IPC_AUTH');
    expect(codeForProviderErrorKind('unauthorized')).toBe('IPC_AUTH');
    expect(codeForProviderErrorKind('quotaExceeded')).toBe('IPC_PROVIDER_QUOTA');
    expect(codeForProviderErrorKind('rateLimited')).toBe('IPC_RATE_LIMITED');
    expect(codeForProviderErrorKind('network')).toBe('IPC_UPSTREAM_NETWORK');
    expect(codeForProviderErrorKind('emptyResponse')).toBe('IPC_EMPTY_RESPONSE');
    expect(codeForProviderErrorKind('upstream')).toBe('IPC_UPSTREAM');
  });

  it('maps quota exceeded errors by quota source and preserves provider guidance in IPC errors', () => {
    expect(codeForProviderError({ kind: 'quotaExceeded', quotaSource: 'entitlement' })).toBe('IPC_ENTITLEMENT_QUOTA');

    const ipcError = toIpcError({
      kind: 'quotaExceeded',
      title: 'Provider quota reached',
      message: 'This API key is out of credit.',
      detail: 'limit=20',
      nextAction: {
        kind: 'waitOrChangeProvider',
        labelKey: 'error.action.providerQuota',
      },
      retryable: false,
      source: 'provider',
      severity: 'warning',
      status: 429,
      quotaSource: 'provider',
    });

    expect(ipcError).toMatchObject({
      code: 'IPC_PROVIDER_QUOTA',
      quotaSource: 'provider',
      source: 'provider',
      status: 429,
      retryable: false,
    });
  });

  it('keeps Relay forward requests transport based and includes Gemini without raw upstream bodies', () => {
    const relayRequest: RelayForwardRequest = {
      baseURL: 'https://relay.example.com',
      transport: 'gemini_generate_content',
      authMode: 'x_goog_api_key',
      apiKeyRef: 'key_ref',
      modelID: 'gemini-2.5-pro',
      messages: [{ role: 'user', content: [{ type: 'text', text: 'Hello' }] }],
      headers: [{ key: 'x-trace-id', value: 'trace-1' }],
    };

    expect(relayRequest.transport).toBe('gemini_generate_content');
    expect('body' in relayRequest).toBe(false);
  });

  it('keeps official provider validation metadata driven while Relay owns custom base URLs', () => {
    const official: ProviderValidateRequest = {
      providerKind: 'openAI',
      apiKeyRef: 'key_ref',
      providerConfigId: 'openai-default',
      validation: {
        modelID: 'gpt-5.4-mini',
        authMode: 'bearer',
        probePath: '/models',
        invalidKeySignals: [{ status: 401, bodyIncludes: ['invalid_api_key'] }],
      },
    };
    const relay: ProviderValidateRequest = {
      providerKind: 'relay',
      apiKeyRef: 'key_ref',
      relay: {
        baseURL: 'https://relay.example.com/v1',
        transport: 'openai_responses',
        authMode: 'bearer',
      },
    };

    expect(official.validation?.probePath).toBe('/models');
    expect('relay' in official).toBe(false);
    expect(relay.relay?.transport).toBe('openai_responses');
  });

  it('uses structured chat messages and options instead of unknown payloads', () => {
    const request: ChatStreamRequest = {
      conversationId: 'conversation-1',
      providerKind: 'openAI',
      modelID: 'gpt-5.4',
      apiKeyRef: 'key_ref',
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Summarize this' },
            { type: 'file', fileName: 'brief.pdf', mimeType: 'application/pdf', dataRef: 'file_ref' },
          ],
        },
      ],
      options: {
        reasoningMode: 'balanced',
        webSearchEnabled: true,
      },
    };

    const content = request.messages[0]?.content;
    expect(Array.isArray(content) ? content[1]?.type : undefined).toBe('file');
    expect(request.options?.webSearchEnabled).toBe(true);
  });

  it('carries structured provider error fields on stream error events', () => {
    const event: IpcStreamEvent = {
      type: 'error',
      error: 'The provider rejected the request.',
      errorKind: 'badRequest',
      retryable: false,
      source: 'provider',
      severity: 'error',
      status: 400,
      nextAction: {
        kind: 'adjustRequest',
        labelKey: 'error.action.adjustRequest',
      },
    };

    expect(event.nextAction?.kind).toBe('adjustRequest');
    expect(event.status).toBe(400);
  });

  it('exports F00 shell contracts without exposing event-only channels to renderer invoke', () => {
    const state: WindowState = {
      bounds: { width: 1280, height: 840 },
      isMaximized: false,
      isFullScreen: false,
      leftSidebarWidth: 280,
      rightAsideWidth: 320,
      leftCollapsed: false,
      rightCollapsed: false,
      rightTab: 'notes',
    };
    const mainPatch: MainWindowStatePatch = {
      bounds: { width: 1440 },
      isFullScreen: true,
    };
    const command: ShellMenuCommand = { command: 'navigate', to: 'dashboard' };
    const external: ShellOpenExternalRequest = {
      url: 'https://github.com/oriveo/oriveo',
      allowlist: 'support',
    };
    const menuLabels: ShellSetMenuLabelsRequest = {
      locale: 'en',
      labels: {
        file: 'File',
      },
    };

    expect(state.rightTab).toBe('notes');
    expect(mainPatch.bounds?.width).toBe(1440);
    expect(command.to).toBe('dashboard');
    expect(external.allowlist).toBe('support');
    expect(menuLabels.labels.file).toBe('File');
    expect(RENDERER_SEND_CHANNELS.has(CHANNELS.shell.persistWindowState)).toBe(true);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.shell.persistWindowState)).toBe(false);
    expect(RENDERER_INVOKE_CHANNELS.has(CHANNELS.shell.menuCommand)).toBe(false);
  });
});
