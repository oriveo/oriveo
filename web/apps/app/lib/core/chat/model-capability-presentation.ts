import type { AIModel, Provider } from '@oriveo/shared';
import { resolveCapabilityEvidence } from '@oriveo/core/providers/capability-evidence-facade';
import { capabilityAvailableForDisplay } from './capability-control-presentation';
import {
  currentCapabilityEvidenceModel,
  modelCapabilityEvidenceCandidates,
  modelCapabilityEvidenceQuery,
  resolveModelCapabilityEvidence,
} from './capability-evidence';

const EVIDENCE_BACKED_BADGES = new Set(['reasoning', 'image', 'web']);

export interface ModelCapabilityPresentation {
  reasoning: boolean;
  image: boolean;
  web: boolean;
  tool: boolean;
  badges: readonly string[];
}

export type ModelCapabilityPresentationProjector = (
  provider: Provider,
  model: AIModel,
) => ModelCapabilityPresentation;

/**
 * Creates one render-lifetime projection cache. Callers recreate it when the
 * provider/model collection or the shared TTL tick changes, so it cannot keep
 * stale evidence across identity/metadata/expiry renders.
 */
export function createModelCapabilityPresentationProjector(): ModelCapabilityPresentationProjector {
  const byProvider = new WeakMap<Provider, WeakMap<AIModel, ModelCapabilityPresentation>>();
  return (provider, model) => {
    let byModel = byProvider.get(provider);
    if (!byModel) {
      byModel = new WeakMap();
      byProvider.set(provider, byModel);
    }
    const cached = byModel.get(model);
    if (cached) return cached;
    const projected = projectModelCapabilityPresentation(provider, model);
    byModel.set(model, projected);
    return projected;
  };
}

export function projectModelCapabilityPresentation(
  provider: Provider,
  model: AIModel,
): ModelCapabilityPresentation {
  // Model lists have no Relay dispatch context, so the shared query correctly
  // keeps Relay transport/identity unknown. Build the current model, query and
  // candidate arrays once, then resolve every presentation key from that same
  // immutable context instead of rebuilding the adapter chain per badge/filter.
  const currentModel = currentCapabilityEvidenceModel(provider, model);
  const query = modelCapabilityEvidenceQuery({ provider, model: currentModel });
  const candidates = modelCapabilityEvidenceCandidates(
    provider,
    currentModel,
    query.effectiveTransport,
  );
  // tool_call has a stricter H4 namespace withdrawal rule than the other
  // presentation keys. Ask the sole adapter for that second candidate shape;
  // presentation must not interpret the raw namespace itself.
  const toolCandidates = modelCapabilityEvidenceCandidates(
    provider,
    currentModel,
    query.effectiveTransport,
    undefined,
    'tool_call',
  );
  const supported = (key: 'vision_input' | 'web_search' | 'tool_call' | `reasoning_level/${string}`) => (
    resolveCapabilityEvidence(key, query, key === 'tool_call' ? toolCandidates : candidates).support
      === 'supported'
  );
  // web/reasoning resolve through the same verdict the composer uses, so a badge
  // can never promise a control the chat page refuses to offer (2026-08-12: 45
  // Qwen models badged Web while the composer had it hard-gated off).
  // vision/tool have no v2 control, so they stay on the evidence facade.
  const support = {
    reasoning: capabilityAvailableForDisplay(provider, model, 'reasoning', currentModel),
    image: supported('vision_input'),
    web: capabilityAvailableForDisplay(provider, model, 'web', currentModel),
    tool: supported('tool_call'),
  };
  return {
    ...support,
    badges: projectBadges(model, support),
  };
}

/**
 * UI-only projection for the capability evidence facade. Relay callers on
 * model lists do not have the actual dispatch transport/endpoint, so the
 * facade intentionally returns unknown and these optimistic affordances stay
 * hidden until a request context exists.
 */
export function modelSupportsCapabilityFilter(
  provider: Provider,
  model: AIModel,
  filter: string,
  presentation?: ModelCapabilityPresentation,
): boolean {
  if (filter === 'reasoning') {
    return presentation?.reasoning ?? capabilityAvailableForDisplay(provider, model, 'reasoning');
  }
  if (filter === 'image' || filter === 'vision') {
    return presentation?.image ?? isSupported(provider, model, 'vision_input');
  }
  if (filter === 'web') return presentation?.web ?? capabilityAvailableForDisplay(provider, model, 'web');
  if (filter === 'tool' || filter === 'tools' || filter === 'toolCall') {
    return presentation?.tool ?? isSupported(provider, model, 'tool_call');
  }

  // file/video/imageGeneration are presentation metadata, not one of H2's
  // evidence keys. Preserve those existing filters without pretending they
  // prove vision input, tool calling, Web search, or a reasoning level.
  return model.capabilities.includes(filter as never);
}

/** Produces the only capability array that model rows may render as badges. */
export function visibleModelCapabilityBadges(
  provider: Provider | undefined,
  model: AIModel,
  presentation?: ModelCapabilityPresentation,
): string[] {
  if (provider && presentation) return [...presentation.badges];
  const supported = provider
    ? {
        reasoning: capabilityAvailableForDisplay(provider, model, 'reasoning'),
        image: isSupported(provider, model, 'vision_input'),
        web: capabilityAvailableForDisplay(provider, model, 'web'),
        tool: isSupported(provider, model, 'tool_call'),
      }
    : { reasoning: false, image: false, web: false, tool: false };
  return projectBadges(model, supported);
}

function projectBadges(
  model: AIModel,
  supported: Pick<ModelCapabilityPresentation, 'reasoning' | 'image' | 'web' | 'tool'>,
): string[] {
  const projected = model.capabilities.filter((capability) => (
    EVIDENCE_BACKED_BADGES.has(capability)
      ? supported[capability as keyof typeof supported]
      : true
  ));

  for (const capability of ['reasoning', 'image', 'web'] as const) {
    if (supported[capability] && !projected.includes(capability)) projected.push(capability);
  }
  if (supported.tool) projected.push('toolCall');

  return [...new Set(projected)];
}

function isSupported(
  provider: Provider,
  model: AIModel,
  key: 'vision_input' | 'web_search' | 'tool_call' | `reasoning_level/${string}`,
): boolean {
  return resolveModelCapabilityEvidence({ key, provider, model }).support === 'supported';
}
