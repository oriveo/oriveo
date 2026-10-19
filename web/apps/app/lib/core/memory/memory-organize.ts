import type { AIModel, LastUsedModelRef, Provider } from '@oriveo/shared';
import { MemoryItems } from '@oriveo/core/context/memory-items';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { sendStream } from '../providers/service';
import { requestBaseURLText } from '../providers/endpoint-source';
import { readStream } from '../../utils/chat-stream-utils';
import { assemblePurposeRequest } from '../chat/context-pipeline/purpose-request';
import { transportInput } from '../chat/context-pipeline/transport-input';

export interface MemoryModelCandidate {
  provider: Provider;
  model: AIModel;
}

/**
 * Candidate order shared by the memory page's model calls (AI draft / organize into items):
 * the last used model goes first when it is still valid; a relay ignores the old isDefault and is not excluded for lacking a key
 * (connections that need no authentication, such as a local engine, never have a key).
 */
export function memoryModelCandidates(
  providers: readonly Provider[],
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): MemoryModelCandidate[] {
  const lastUsedModel = (p: Provider) => (
    lastUsedModelRef && p.id === lastUsedModelRef.providerID
      ? p.models.find((m) => m.id === lastUsedModelRef.modelID) ?? null
      : null
  );
  return providers
    .filter((p) => p.kind === 'relay' || resolveProviderAPIKey(p))
    .map((p) => ({
      provider: p,
      model: lastUsedModel(p)
        ?? (p.kind !== 'relay' ? p.models.find((m) => m.isDefault) : undefined)
        ?? p.models[0]
        ?? null,
    }))
    .sort((lhs, rhs) => Number(Boolean(lastUsedModel(rhs.provider))) - Number(Boolean(lastUsedModel(lhs.provider))))
    .filter((c): c is MemoryModelCandidate => c.model !== null);
}

/**
 * Ask one candidate model to split a memory into several: the request follows organizeRequest and the full raw reply is returned.
 * The caller judges an empty reply and the parse result (empty reply = failure; non-empty but parsed to nothing = no items split out).
 */
export async function requestMemoryOrganize(input: {
  provider: Provider;
  model: AIModel;
  content: string;
}): Promise<string> {
  const request = MemoryItems.organizeRequest(input.content);
  // Same purpose as the AI draft: the instructions go into purposeSystem and the original text goes out unchanged as one user message; no memory, instructions or document context is attached.
  const planned = assemblePurposeRequest({
    purpose: 'memoryExtraction',
    purposeSystem: request.system,
    userText: request.messages.map((m) => m.text).join('\n'),
  });
  const transport = transportInput(planned, { options: undefined, planMessages: true });
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
