import type { AIModel, Provider } from '@oriveo/shared';
import { resolveCapabilityEvidence } from '@oriveo/core/providers/capability-evidence-facade';
import { capabilityAvailableForDisplay } from './capability-control-presentation';
import {
  currentCapabilityEvidenceModel,
  modelCapabilityEvidenceCandidates,
  modelCapabilityEvidenceQuery,
  resolveModelCapabilityEvidence,
} from './capability-evidence';
import { resolveInputCapabilityProjections } from '../capability/truth/input-truth-adapter';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';
import { providerFormOf } from '../capability/truth/provider-form';
import { connectionToolCallVerdict } from './tool-call-verdict';

const EVIDENCE_BACKED_BADGES = new Set(['reasoning', 'image', 'web', 'file', 'video']);

export interface ModelCapabilityPresentation {
  reasoning: boolean;
  /** Vision / file / video badges = the visible flag of the input capability projection; subscription (no projection) keeps the old criterion. */
  image: boolean;
  file: boolean;
  video: boolean;
  web: boolean;
  tool: boolean;
  badges: readonly string[];
}

type SupportedBadges = Pick<ModelCapabilityPresentation, 'reasoning' | 'image' | 'file' | 'video' | 'web' | 'tool'>;

/**
 * Badges for the three input keys: with a projection only visible counts (unknown does not light up;
 * the send context is filled in the same way as the entry points);
 * when subscription returns null, vision goes through the evidence facade and file / video keep the catalog capability bits.
 */
function inputBadgeSupport(
  provider: Provider,
  model: AIModel,
  legacyImage: () => boolean,
): Pick<ModelCapabilityPresentation, 'image' | 'file' | 'video'> {
  // The model list has no send context: fill it in as the entry point (resolveAttachmentCapabilities) does,
  // with automatic, so a Relay can get its connection identity; only an identity still missing after that is a hard block.
  const streamOptions = buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, 'automatic', false),
    model,
  );
  const projections = resolveInputCapabilityProjections(provider, model, streamOptions);
  if (projections) {
    return {
      image: projections.vision_input.visible,
      file: projections.file_input.visible,
      video: projections.video_input.visible,
    };
  }
  return {
    image: legacyImage(),
    file: model.capabilities.includes('file'),
    video: model.capabilities.includes('video'),
  };
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
  // tool_call has a stricter evidence-withdrawal rule than the other
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
    ...inputBadgeSupport(provider, model, () => supported('vision_input')),
    web: capabilityAvailableForDisplay(provider, model, 'web', currentModel),
    tool: toolBadgeSupport(provider, model, () => supported('tool_call')),
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
    return presentation?.image ?? inputBadgeSupport(provider, model, () => isSupported(provider, model, 'vision_input')).image;
  }
  if (filter === 'file' || filter === 'video') {
    return presentation?.[filter] ?? inputBadgeSupport(provider, model, () => false)[filter];
  }
  if (filter === 'web') return presentation?.web ?? capabilityAvailableForDisplay(provider, model, 'web');
  if (filter === 'tool' || filter === 'tools' || filter === 'toolCall') {
    return presentation?.tool ?? toolBadgeSupport(provider, model, () => isSupported(provider, model, 'tool_call'));
  }

  // imageGeneration is catalog presentation metadata, not an evidence-backed capability.
  // Preserve that existing filter without pretending it proves an input capability,
  // tool calling, web search, or a reasoning level.
  return model.capabilities.includes(filter as never);
}

/** Produces the only capability array that model rows may render as badges. */
export function visibleModelCapabilityBadges(
  provider: Provider | undefined,
  model: AIModel,
  presentation?: ModelCapabilityPresentation,
): string[] {
  if (provider && presentation) return [...presentation.badges];
  const supported: SupportedBadges = provider
    ? {
        reasoning: capabilityAvailableForDisplay(provider, model, 'reasoning'),
        ...inputBadgeSupport(provider, model, () => isSupported(provider, model, 'vision_input')),
        web: capabilityAvailableForDisplay(provider, model, 'web'),
        tool: toolBadgeSupport(provider, model, () => isSupported(provider, model, 'tool_call')),
      }
    : { reasoning: false, image: false, file: false, video: false, web: false, tool: false };
  return projectBadges(model, supported);
}

function projectBadges(
  model: AIModel,
  supported: SupportedBadges,
): string[] {
  const projected = model.capabilities.filter((capability) => (
    EVIDENCE_BACKED_BADGES.has(capability)
      ? supported[capability as keyof typeof supported]
      : true
  ));

  for (const capability of ['reasoning', 'image', 'file', 'video', 'web'] as const) {
    if (supported[capability] && !projected.includes(capability)) projected.push(capability);
  }
  if (supported.tool) projected.push('toolCall');

  return [...new Set(projected)];
}

/** Tool badge: official / subscription use the same verdict as the send path (including the rejection memory); other forms still look only at the facade evidence. */
function toolBadgeSupport(provider: Provider, model: AIModel, relaySupport: () => boolean): boolean {
  const form = providerFormOf(provider);
  if (form !== 'official' && form !== 'subscription') return relaySupport();
  return connectionToolCallVerdict(provider, model) === true;
}

function isSupported(
  provider: Provider,
  model: AIModel,
  key: 'vision_input' | 'web_search' | 'tool_call' | `reasoning_level/${string}`,
): boolean {
  return resolveModelCapabilityEvidence({ key, provider, model }).support === 'supported';
}
