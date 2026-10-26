import type { AIModel } from '@oriveo/shared';

/**
 * Image generation dispatch decision: the Relay image generation override takes priority - true counts as if the model
 * capabilities include image generation, false never takes the image generation path;
 * with no override, the capabilities must include imageGeneration and an imageGen profile must exist. An override only exists on Relay models.
 * Kept in its own file with no dependency on other business modules: the first-send protocol (relay-first-send-transport) decides image generation through it,
 * while the attachment envelope (relay-runtime-support) in turn reads the first-send protocol, so putting it in stream-options would create a cycle.
 */
export function dispatchesImageGeneration(
  model: Pick<AIModel, 'capabilities' | 'imageGenProfile' | 'relayCapabilityOverrides'>,
): boolean {
  const override = model.relayCapabilityOverrides?.imageGeneration?.value;
  if (typeof override === 'boolean') return override;
  return model.capabilities.includes('imageGeneration') && Boolean(model.imageGenProfile);
}
