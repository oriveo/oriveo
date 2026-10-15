/**
 * The single emitter of chat_message_failed: the plain, MCP, library and continuation paths all go through here,
 * and the attribution fields always come from chatFailureTelemetry.
 */
import type { AIModel, Provider } from '@oriveo/shared';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { relaySendTelemetryProperties } from '../telemetry/relay-properties';
import {
  chatFailureTelemetry,
  failureOutputStarted,
  type ChatAttemptKind,
  type ChatSendBlockedReason,
} from '../telemetry/chat-failure';

export function reportChatFailed(input: {
  provider: Provider;
  model: AIModel;
  attemptKind: ChatAttemptKind;
  /** The normalized failure object (output of normalizeChatFailure). */
  error: unknown;
  /** The raw thrown value: stream-runner attaches outputStarted to it; defaults to the same as error. */
  rawError?: unknown;
  sendStartedAt: number;
}): void {
  const { provider, model, attemptKind, error, sendStartedAt } = input;
  const raw = input.rawError ?? error;
  trackEvent('chat_message_failed', {
    provider_kind: telemetryProviderKind(provider.kind),
    model_id: telemetryModelID(provider.kind, model.id),
    attempt_kind: attemptKind,
    // Report only the normalized short slug; the raw error body never goes into telemetry
    ...chatFailureTelemetry({
      error,
      outputStarted: failureOutputStarted(raw) || failureOutputStarted(error),
      latencyMs: Date.now() - sendStartedAt,
      ...(typeof navigator !== 'undefined' && typeof navigator.onLine === 'boolean'
        ? { deviceOnline: navigator.onLine }
        : {}),
    }),
    // A relay failure has to be traceable to the relay address that broke; same helper as sent/completed
    ...relaySendTelemetryProperties(provider, model),
  });
}

/**
 * The user pressed send but the request was blocked before going out (no usable model, etc.): only chat_send_blocked is reported, never sent / failed.
 * Empty input is not a block, so callers must not call this for it.
 */
export function reportSendBlocked(reason: ChatSendBlockedReason, providerKind?: Provider['kind']): void {
  trackEvent('chat_send_blocked', {
    reason,
    ...(providerKind ? { provider_kind: telemetryProviderKind(providerKind) } : {}),
  });
}
