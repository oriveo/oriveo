import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChatRouteShell } from './ChatRouteShell';
import {
  markNewConversationRoutePromotion,
  resetNewConversationRoutePromotionForTests,
} from '../../lib/core/chat/route-transition';

const mocks = vi.hoisted(() => ({
  pathname: '/chat',
  params: {} as Record<string, string>,
  searchParams: new URLSearchParams(),
  setActiveConversationId: vi.fn(),
  chatMounts: 0,
  chatUnmounts: 0,
}));

vi.mock('next/navigation', () => ({
  usePathname: () => mocks.pathname,
  useParams: () => mocks.params,
  useSearchParams: () => mocks.searchParams,
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: { setActiveConversationId: typeof mocks.setActiveConversationId }) => unknown) =>
    selector({ setActiveConversationId: mocks.setActiveConversationId }),
}));

vi.mock('../mobile/MobileHomeView', () => ({
  MobileHomeView: () => <div data-testid="mobile-home">mobile home</div>,
}));

vi.mock('./ChatView', async () => {
  const React = await import('react');
  return {
    ChatView: ({ conversationId, searchQuery }: { conversationId?: string; searchQuery?: string }) => {
      const [draft, setDraft] = React.useState('');
      React.useEffect(() => {
        mocks.chatMounts += 1;
        return () => {
          mocks.chatUnmounts += 1;
        };
      }, []);
      return (
        <input
          aria-label="chat draft"
          data-conversation-id={conversationId ?? ''}
          data-search-query={searchQuery ?? ''}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
      );
    },
  };
});

describe('ChatRouteShell', () => {
  beforeEach(() => {
    mocks.pathname = '/chat';
    mocks.params = {};
    mocks.searchParams = new URLSearchParams();
    mocks.setActiveConversationId.mockReset();
    mocks.chatMounts = 0;
    mocks.chatUnmounts = 0;
    resetNewConversationRoutePromotionForTests();
  });

  it('keeps the same ChatView instance when the first message assigns a conversation route', async () => {
    const view = render(
      <ChatRouteShell><div>leaf route</div></ChatRouteShell>,
    );
    const draft = screen.getByRole('textbox', { name: 'chat draft' });
    fireEvent.change(draft, { target: { value: 'preserved draft' } });

    await waitFor(() => expect(mocks.chatMounts).toBe(1));
    expect(screen.getByTestId('mobile-home')).toBeTruthy();

    markNewConversationRoutePromotion('conversation-7');
    mocks.pathname = '/chat/conversation-7';
    mocks.params = { conversationId: 'conversation-7' };
    mocks.searchParams = new URLSearchParams('q=needle');
    view.rerender(
      <ChatRouteShell><div>conversation leaf</div></ChatRouteShell>,
    );

    const routedDraft = screen.getByRole('textbox', { name: 'chat draft' });
    expect(routedDraft).toBe(draft);
    expect((routedDraft as HTMLInputElement).value).toBe('preserved draft');
    expect(routedDraft.getAttribute('data-conversation-id')).toBe('conversation-7');
    expect(routedDraft.getAttribute('data-search-query')).toBe('needle');
    expect(screen.queryByTestId('mobile-home')).toBeNull();
    expect(mocks.chatMounts).toBe(1);
    expect(mocks.chatUnmounts).toBe(0);
    await waitFor(() => {
      expect(mocks.setActiveConversationId).toHaveBeenLastCalledWith('conversation-7');
    });

    mocks.pathname = '/chat/conversation-8';
    mocks.params = { conversationId: 'conversation-8' };
    mocks.searchParams = new URLSearchParams();
    view.rerender(
      <ChatRouteShell><div>another conversation leaf</div></ChatRouteShell>,
    );

    const nextConversationDraft = screen.getByRole('textbox', { name: 'chat draft' });
    expect(nextConversationDraft).not.toBe(routedDraft);
    expect((nextConversationDraft as HTMLInputElement).value).toBe('');
    expect(mocks.chatMounts).toBe(2);
    expect(mocks.chatUnmounts).toBe(1);

    view.unmount();
    expect(mocks.chatUnmounts).toBe(2);
    expect(mocks.setActiveConversationId).toHaveBeenLastCalledWith(null);
  });

  it('renders nested chat tools through the leaf route instead of mounting ChatView', async () => {
    mocks.pathname = '/chat/usage';

    render(
      <ChatRouteShell><div>usage route</div></ChatRouteShell>,
    );

    expect(screen.getByText('usage route')).toBeTruthy();
    expect(screen.queryByRole('textbox', { name: 'chat draft' })).toBeNull();
    expect(mocks.chatMounts).toBe(0);
    await waitFor(() => {
      expect(mocks.setActiveConversationId).toHaveBeenCalledWith(null);
    });
  });
});
