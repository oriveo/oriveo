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
});
