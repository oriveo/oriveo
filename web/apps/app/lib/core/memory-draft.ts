import type { AIModel, Provider } from '@oriveo/shared';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { sendStream } from './providers/service';
import { requestBaseURLText } from './providers/endpoint-source';
import { readStream } from '../utils/chat-stream-utils';
import { assemblePurposeRequest } from './chat/context-pipeline/purpose-request';
import { transportInput } from './chat/context-pipeline/transport-input';
import { buildProviderStreamOptions } from './chat/stream-options';

// The instruction part of the memory draft (purposeSystem); the recent-conversation excerpt is sent as the only user message, unchanged.
export const MEMORY_DRAFT_INSTRUCTIONS = `Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
Include: their role/expertise, current projects or tech stack, preferred response style and language.
Only include information clearly evident from the conversations. Do not invent or assume.
Write in first person, as if the user is describing themselves.`;

/** Ask one candidate model for a memory draft and return the full output before trimming. */
export async function requestMemoryDraft(input: {
  provider: Provider;
  model: AIModel;
  excerpts: string;
}): Promise<string> {
  // Purpose memoryExtraction: the instructions go into purposeSystem and the excerpt goes out unchanged as one user message; no memory, instructions or document context is attached.
  const planned = assemblePurposeRequest({
    purpose: 'memoryExtraction',
    purposeSystem: MEMORY_DRAFT_INSTRUCTIONS,
    userText: input.excerpts,
  });
  // Relay runtime options (security mode, transport, resolved root) must ride along; without them a LocalHttp relay is rejected as cleartext.
  const transport = transportInput(planned, { options: buildProviderStreamOptions(input.provider, undefined, input.model), planMessages: true });
  const { stream } = sendStream(
    input.provider.kind,
    resolveProviderAPIKey(input.provider, input.model.id),
    input.model.id,
    transport.messages,
    requestBaseURLText(input.provider),
    transport.options,
  );
  const { fullText } = await readStream(stream, '', () => {});
  return fullText;
}
