import { render } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useFocusMessage } from '../useFocusMessage';

const { mockWarmConversationAnchorInStore } = vi.hoisted(() => ({
  mockWarmConversationAnchorInStore: vi.fn(),
}));

vi.mock('../../core/chat/conversation-bootstrap', () => ({
  warmConversationAnchorInStore: (...args: unknown[]) => mockWarmConversationAnchorInStore(...args),
}));

function FocusHarness({
  messageId,
  conversationId,
  domMessageId = 'present-message',
}: {
  messageId?: string | null;
  conversationId?: string | null;
  domMessageId?: string;
}) {
  useFocusMessage(messageId, { conversationId });
  return (
    <div>
      <input data-testid="composer-input" />
      <div data-message-id={domMessageId}>target</div>
    </div>
  );
}

describe('useFocusMessage note source anchor behavior', () => {
  const scrollIntoView = vi.fn();

  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    Element.prototype.scrollIntoView = scrollIntoView;
    mockWarmConversationAnchorInStore.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('asks the sync layer for a missing source anchor once instead of treating it as deleted', async () => {
    render(
      <FocusHarness
        messageId="aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
        conversationId="bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb"
      />,
    );

    await vi.advanceTimersByTimeAsync(450);

    expect(mockWarmConversationAnchorInStore).toHaveBeenCalledTimes(1);
    expect(mockWarmConversationAnchorInStore).toHaveBeenCalledWith(
      'BBBBBBBB-BBBB-4BBB-ABBB-BBBBBBBBBBBB',
      'AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA',
    );

    await vi.advanceTimersByTimeAsync(2500);
    expect(mockWarmConversationAnchorInStore).toHaveBeenCalledTimes(1);
  });

  it('scrolls and highlights a found source message without focusing the composer', async () => {
    render(<FocusHarness messageId="present-message" conversationId="conversation-1" />);
    const input = document.querySelector('[data-testid="composer-input"]') as HTMLInputElement;
    const focusSpy = vi.spyOn(input, 'focus');

    await vi.advanceTimersByTimeAsync(100);

    const target = document.querySelector('[data-message-id="present-message"]') as HTMLElement;
    expect(scrollIntoView).toHaveBeenCalledWith({ block: 'start', behavior: 'smooth' });
    expect(target.classList.contains('o-focus-message')).toBe(true);
    expect(focusSpy).not.toHaveBeenCalled();
    expect(document.activeElement).not.toBe(input);
    expect(mockWarmConversationAnchorInStore).not.toHaveBeenCalled();
  });

  it('matches lowercase source message ids against canonical DOM ids', async () => {
    render(
      <FocusHarness
        messageId="aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
        conversationId="bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb"
        domMessageId="AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA"
      />,
    );

    await vi.advanceTimersByTimeAsync(100);

    expect(scrollIntoView).toHaveBeenCalledWith({ block: 'start', behavior: 'smooth' });
    expect(mockWarmConversationAnchorInStore).not.toHaveBeenCalled();
  });
});
