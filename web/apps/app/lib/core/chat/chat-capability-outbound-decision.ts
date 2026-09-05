import type { ReasoningMode } from '@oriveo/shared';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';
import type { CapabilityControlPresentation } from './capability-control-presentation';
import { modelControlWebReachesTheWire, resolveModelControlStatus } from './model-control-capability-layout';

export interface ChatCapabilityOutboundDecision {
  webSearchEnabled: boolean;
  reasoningMode: ReasoningMode;
  reasoningIntent?: ReasoningIntent;
  hasWebSelection: boolean;
  hasReasoningSelection: boolean;
  hasActiveCapabilitySelection: boolean;
}

interface Input {
  webRequested: boolean;
  webControl: Pick<CapabilityControlPresentation, 'state'> & { reasonCode?: string };
  webDormant: boolean;
  /**
   * Whether custom web request fields really take over this request for this connection,
   * model and transport.
   *
   * The chip's globe only asks whether the preference can reach the wire (liveness), and a
   * custom takeover is the only path other than official automatic configuration that gets
   * it there. Missing it leaves the composer globe dark even though the user enabled web
   * access through custom JSON.
   */
  webCustomIsActive?: boolean;
  reasoningModeRequested: ReasoningMode;
  reasoningIntentRequested?: ReasoningIntent;
  reasoningControl: Pick<CapabilityControlPresentation, 'state' | 'availableIntents'>;
  reasoningDormant: boolean;
}

/** Equivalent of iOS ChatCapabilityOutboundDecision: UI reads the effective outbound request. */
export function resolveChatCapabilityOutboundDecision(input: Input): ChatCapabilityOutboundDecision {
  const requestedIntent = input.reasoningIntentRequested ?? intentForMode(input.reasoningModeRequested);
  const reasoningPermitted = !input.reasoningDormant
    && input.reasoningControl.state === 'auto_available'
    && requestedIntent !== undefined
    && input.reasoningControl.availableIntents.includes(requestedIntent);
  const reasoningIntent = reasoningPermitted ? requestedIntent : undefined;
  const reasoningMode = reasoningPermitted ? modeForIntent(reasoningIntent) : 'automatic';
  const webSearchEnabled = input.webRequested
    && !input.webDormant
    && input.webControl.state === 'auto_available';
  // The chip's globe asks about liveness (can this preference reach the wire right now),
  // which recognizes one more case than `webSearchEnabled` (should the official automatic
  // configuration be sent this time): a custom takeover. The two are deliberately different
  // values - counting a custom takeover as `webSearchEnabled` would make the outbound side
  // compile an official web recipe that does not exist.
  const hasWebSelection = input.webRequested && !input.webDormant && modelControlWebReachesTheWire({
    status: resolveModelControlStatus(input.webControl),
    customIsActive: input.webCustomIsActive ?? false,
  });
  const hasReasoningSelection = reasoningIntent !== undefined || reasoningMode !== 'automatic';
  return {
    webSearchEnabled,
    reasoningMode,
    ...(reasoningIntent ? { reasoningIntent } : {}),
    hasWebSelection,
    hasReasoningSelection,
    hasActiveCapabilitySelection: hasWebSelection || hasReasoningSelection,
  };
}

function intentForMode(mode: ReasoningMode): ReasoningIntent | undefined {
  if (mode === 'fast') return 'low';
  if (mode === 'balanced' || mode === 'deep' || mode === 'max') return mode;
  return undefined;
}

function modeForIntent(intent: ReasoningIntent | undefined): ReasoningMode {
  if (intent === 'low') return 'fast';
  if (intent === 'balanced' || intent === 'deep' || intent === 'max') return intent;
  return 'automatic';
}
