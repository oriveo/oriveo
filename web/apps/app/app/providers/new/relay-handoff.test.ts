import { beforeEach, describe, expect, it } from 'vitest';
import { consumeRelayHandoff, markRelayHandoff } from './relay-handoff';

describe('relay onboarding handoff analytics', () => {
  beforeEach(() => {
    window.sessionStorage.clear();
  });

  it('after the parent page jumps to relay, the relay page reads the handoff marker (no duplicate started)', () => {
    markRelayHandoff({ entryPoint: 'skill_edit', isFirstProvider: false });
    expect(consumeRelayHandoff()).toEqual({ entryPoint: 'skill_edit', isFirstProvider: false });
  });

  it('the marker is one-shot: cleared once read, so returning to onboarding and entering relay again is not misread', () => {
    markRelayHandoff({ entryPoint: 'providers', isFirstProvider: false });
    consumeRelayHandoff();
    expect(consumeRelayHandoff()).toBeNull();
  });

  it('opening the relay page by direct link leaves no marker -> the relay page emits started itself', () => {
    expect(consumeRelayHandoff()).toBeNull();
  });
});
