/**
 * Pre-send check: whether this message has attachments that will not fit when it is actually sent.
 *
 * It uses the same line resolver and the same inputs as the outbound history build
 * (`buildOutboundChatHistory`): connection, model, and stream options derived from intent. The one thing
 * the entry point cannot know is whether this send will take the tool loop (the send function decides that
 * from MCP / library state), so both cases are computed and the send is blocked only when neither fits;
 * anything else is left to the check at send time. If the line cannot be determined, nothing is blocked.
 */
import type { AIModel, Attachment, Provider, ReasoningMode } from '@oriveo/shared';
import {
  attachmentOverLimitCode,
  findUnsendableTextAttachments,
} from '../attachments/attachment-delivery';
import type { SkippedAttachment } from '../attachments/attachment-injector';
import { resolveAttachmentLine } from '../attachments/attachment-transport-resolver';
import { telemetryProviderKind, trackEvent } from '../telemetry';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';

export interface AttachmentPreflightInput {
  attachments: Attachment[] | undefined;
  provider: Provider;
  model: AIModel;
  reasoningMode?: ReasoningMode;
  webSearchEnabled?: boolean;
}

export async function findUnsendableAttachmentsBeforeSend(
  input: AttachmentPreflightInput,
): Promise<SkippedAttachment[]> {
  const { attachments, provider, model } = input;
  if (!attachments?.some((attachment) => attachment.kind === 'file')) return [];
  let blocked: SkippedAttachment[] | undefined;
  for (const toolLoop of [false, true]) {
    const streamOptions = buildProviderStreamOptions(
      provider,
      // A tool loop does not also turn on web search (the same rule as in the send function).
      buildStreamOptionsFromIntent(model, input.reasoningMode, toolLoop ? false : input.webSearchEnabled),
      model,
    );
    const line = await resolveAttachmentLine({ provider, model, streamOptions, toolLoop });
    if (!line.exact) return [];
    const skipped = findUnsendableTextAttachments(attachments, model, line);
    if (skipped.length === 0) return [];
    blocked ??= skipped;
  }
  return blocked ?? [];
}

/** Event recorded when a send is blocked: only the stable code and provider_kind, never file names. */
export function trackAttachmentSendBlocked(skipped: readonly SkippedAttachment[], provider: Provider): void {
  trackEvent('attachment_send_blocked', {
    error_code: attachmentOverLimitCode(skipped),
    provider_kind: telemetryProviderKind(provider.kind),
  });
}
