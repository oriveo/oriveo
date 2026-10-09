import { describe, expect, it } from 'vitest';
import { resolveChatCapabilityOutboundDecision } from './chat-capability-outbound-decision';

describe('ChatCapabilityOutboundDecision', () => {
  const available = { state: 'auto_available' as const, availableIntents: ['off', 'low', 'balanced', 'deep', 'max'] };

  it('reflects the effective outbound capability selection', () => {
    expect(resolveChatCapabilityOutboundDecision({
      webRequested: true,
      webControl: available,
      webDormant: false,
      reasoningModeRequested: 'deep',
      reasoningControl: available,
      reasoningDormant: false,
    })).toMatchObject({
      webSearchEnabled: true,
      reasoningMode: 'deep',
      reasoningIntent: 'deep',
      hasActiveCapabilitySelection: true,
    });
  });

  it('does not highlight stored values suppressed by dormant or allowlist gates', () => {
    expect(resolveChatCapabilityOutboundDecision({
      webRequested: true,
      webControl: available,
      webDormant: true,
      reasoningModeRequested: 'fast',
      reasoningControl: { ...available, availableIntents: ['deep'] },
      reasoningDormant: false,
    })).toMatchObject({
      webSearchEnabled: false,
      reasoningMode: 'automatic',
      hasActiveCapabilitySelection: false,
    });
  });

  it('selected tier rejected by upstream -> falls back to the nearest usable tier; nothing is sent when no tier is left', () => {
    const base = {
      webRequested: false, webControl: available, webDormant: false,
      reasoningModeRequested: 'automatic' as const, reasoningControl: available, reasoningDormant: false,
    };
    expect(resolveChatCapabilityOutboundDecision({
      ...base, reasoningIntentRequested: 'max', reasoningRejectedIntents: ['max'],
    })).toMatchObject({ reasoningIntent: 'deep', reasoningMode: 'deep', hasReasoningSelection: true });
    expect(resolveChatCapabilityOutboundDecision({
      ...base, reasoningIntentRequested: 'balanced', reasoningRejectedIntents: ['max'],
    })).toMatchObject({ reasoningIntent: 'balanced' });
    const none = resolveChatCapabilityOutboundDecision({
      ...base, reasoningIntentRequested: 'deep', reasoningRejectedIntents: ['deep'],
      reasoningControl: { ...available, availableIntents: ['off', 'deep'] },
    });
    expect(none.reasoningIntent).toBeUndefined();
    expect(none.hasReasoningSelection).toBe(false);
  });
});
