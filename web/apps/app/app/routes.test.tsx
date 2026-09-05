import type { ReactNode } from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => {
  const mockReplace = vi.fn();
  const mockResolveEntryRoute = vi.fn(() => '/chat');
  const mockSetActiveConversationId = vi.fn();
  const mockState = {
    hasCompletedOnboarding: true,
    providers: [{ id: 'provider-1' }],
    setActiveConversationId: mockSetActiveConversationId,
  };

  return {
    mockReplace,
    mockResolveEntryRoute,
    mockSetActiveConversationId,
    mockState,
    mockParams: {} as Record<string, string>,
    mockSearchParams: new URLSearchParams(),
  };
});

import RootPage from './page';
import RootLayout from './layout';
import SettingsPage from './settings/page';
import BackupRoute from './settings/backup/page';
import MemoryRoute from './settings/memory/page';
import SkillsRoute from './skills/page';
import SkillEditRoute from './skills/edit/page';
import ProvidersPage from './providers/page';
import ProviderDetailPage from './providers/[providerId]/page';
import NotesPage from './notes/page';
import NoteDetailPage from './notes/[noteId]/page';
import ChatLayout from './chat/layout';
import NewChatPage from './chat/page';
import ConversationPage from './chat/[conversationId]/page';
import FolderDetailPage from './chat/folder/[folderId]/page';
import RelayNewPage from './providers/relay/new/page';

vi.mock('next/font/google', () => ({
  Inter: () => ({ variable: 'font-inter' }),
  JetBrains_Mono: () => ({ variable: 'font-mono' }),
}));

vi.mock('next-intl/server', () => ({
  getLocale: () => Promise.resolve('zh-Hans'),
  getMessages: () => Promise.resolve({}),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    replace: mocks.mockReplace,
  }),
  useParams: () => mocks.mockParams,
  useSearchParams: () => mocks.mockSearchParams,
}));

vi.mock('../providers/StoreProvider', () => ({
  StoreProvider: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  useAppStore: (selector: (state: typeof mocks.mockState) => unknown) => selector(mocks.mockState),
}));

vi.mock('../components/SRLiveRegion', () => ({
  SRLiveRegion: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}));

vi.mock('../components/RouteTitleSync', () => ({
  RouteTitleSync: () => null,
}));

vi.mock('../components/ThemeInitScript', () => ({
  ThemeInitScript: () => null,
}));

vi.mock('../components/PersistentShellLayout', () => ({
  PersistentShellLayout: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}));

vi.mock('../components/chat/ChatRouteShell', () => ({
  ChatRouteShell: ({ children }: { children: ReactNode }) => (
    <div data-testid="chat-route-shell">{children}</div>
  ),
}));

vi.mock('../components/AppShellWrapper', () => ({
  AppShellWrapper: ({ children }: { children: ReactNode }) => (
    <div data-testid="app-shell-wrapper">{children}</div>
  ),
}));

vi.mock('../components/Skeleton', () => ({
  Skeleton: () => <div data-testid="root-skeleton">skeleton</div>,
}));

vi.mock('../lib/utils/entry-route', () => ({
  resolveEntryRoute: mocks.mockResolveEntryRoute,
}));

vi.mock('./settings/Settings', () => ({
  Settings: () => <div>settings-screen</div>,
}));

vi.mock('./settings/backup/BackupPage', () => ({
  BackupPage: () => <div>backup-screen</div>,
}));

vi.mock('./settings/memory/MemoryPage', () => ({
  MemoryPage: () => <div>memory-screen</div>,
}));

vi.mock('./skills/SkillsPage', () => ({
  SkillsPage: () => <div>skills-screen</div>,
}));

vi.mock('./skills/edit/SkillEditPage', () => ({
  SkillEditPage: () => <div>skill-edit-screen</div>,
}));

vi.mock('./providers/ProviderList', () => ({
  ProviderList: () => <div>providers-screen</div>,
}));

vi.mock('./providers/[providerId]/ProviderDetailRouter', () => ({
  ProviderDetailRouter: ({ providerId }: { providerId: string }) => (
    <div>provider-detail-{providerId}</div>
  ),
}));

vi.mock('./notes/NotesPage', () => ({
  NotesPage: () => <div>notes-screen</div>,
}));

vi.mock('../components/notes/NoteDetail', () => ({
  NoteDetail: ({ noteId }: { noteId: string }) => <div>note-detail-{noteId}</div>,
}));

vi.mock('../components/sidebar/FolderDetailView', () => ({
  FolderDetailView: ({ folderId }: { folderId: string }) => <div>folder-detail-{folderId}</div>,
}));

vi.mock('./providers/relay/new/RelaySetup', () => ({
  RelaySetup: () => <div>relay-setup-screen</div>,
}));


describe('app routes', () => {
  beforeEach(() => {
    mocks.mockReplace.mockReset();
    mocks.mockResolveEntryRoute.mockClear();
    mocks.mockResolveEntryRoute.mockReturnValue('/chat');
    mocks.mockSetActiveConversationId.mockReset();
    mocks.mockParams = {};
    mocks.mockSearchParams = new URLSearchParams();
    mocks.mockState.hasCompletedOnboarding = true;
    mocks.mockState.providers = [{ id: 'provider-1' }];
    mocks.mockState.setActiveConversationId = mocks.mockSetActiveConversationId;
  });

  afterEach(() => {
    mocks.mockParams = {};
  });

  it('routes the root page through resolveEntryRoute and redirects with the computed path', async () => {
    render(<RootPage />);

    expect(screen.getByTestId('root-skeleton')).toBeTruthy();
    expect(mocks.mockResolveEntryRoute).toHaveBeenCalledWith({
      hasCompletedOnboarding: true,
      providerCount: 1,
    });
    await waitFor(() => {
      expect(mocks.mockReplace).toHaveBeenCalledWith('/chat');
    });
  });

  it('renders settings, backup, memory, skills, and providers screen content (shell provided by root layout)', () => {
    const cases = [
      { ui: <SettingsPage />, text: 'settings-screen' },
      { ui: <BackupRoute />, text: 'backup-screen' },
      { ui: <MemoryRoute />, text: 'memory-screen' },
      { ui: <SkillsRoute />, text: 'skills-screen' },
      { ui: <ProvidersPage />, text: 'providers-screen' },
      { ui: <NotesPage />, text: 'notes-screen' },
    ];

    for (const testCase of cases) {
      const { unmount } = render(testCase.ui);
      expect(screen.getByText(testCase.text)).toBeTruthy();
      unmount();
    }
  });

  it('renders the skill edit route inside suspense (shell provided by root layout)', () => {
    render(<SkillEditRoute />);

    expect(screen.getByText('skill-edit-screen')).toBeTruthy();
  });

  it('binds the provider detail route param to the router via useParams', () => {
    mocks.mockParams = { providerId: 'provider-42' };

    render(<ProviderDetailPage />);

    expect(screen.getByText('provider-detail-provider-42')).toBeTruthy();
  });

  it('binds the note detail route param to the note detail via useParams', () => {
    mocks.mockParams = { noteId: 'note-42' };

    render(<NoteDetailPage />);

    expect(screen.getByText('note-detail-note-42')).toBeTruthy();
  });

  it('chat layout delegates leaf routes to the persistent chat route shell', () => {
    render(<ChatLayout><div>chat-child</div></ChatLayout>);

    expect(screen.getByTestId('chat-route-shell')).toBeTruthy();
    expect(screen.getByText('chat-child')).toBeTruthy();
  });

  it('keeps the new-chat leaf page presentation-free', () => {
    const view = render(<NewChatPage />);

    expect(view.container.childElementCount).toBe(0);
  });

  it('keeps the conversation leaf page presentation-free', () => {
    const view = render(<ConversationPage />);

    expect(view.container.childElementCount).toBe(0);
  });

  it('binds the folder detail route param to the detail view via useParams', () => {
    mocks.mockParams = { folderId: 'folder-9' };

    render(<FolderDetailPage />);

    expect(screen.getByText('folder-detail-folder-9')).toBeTruthy();
  });

  it('renders the relay setup route', () => {
    render(<RelayNewPage />);
    expect(screen.getByText('relay-setup-screen')).toBeTruthy();
  });

  it('does not register the service worker on LAN development hosts', async () => {
    const ui = await RootLayout({ children: <div>route-child</div> });
    render(ui);

    const scripts = Array.from(document.querySelectorAll('script'))
      .map((script) => script.innerHTML)
      .join('\n');

    expect(scripts).toContain('localhost');
    expect(scripts).toContain('192\\.168\\.');
    expect(scripts).toContain('10\\.');
    expect(scripts).toContain('172\\.');
    expect(scripts).toContain('navigator.serviceWorker.getRegistrations');
    expect(scripts).toContain('caches.keys');
    expect(scripts).toContain('Promise.all');
    expect(scripts).toContain('navigator.serviceWorker.controller');
    expect(scripts).toContain('window.location.reload');
    expect(scripts).toContain('navigator.serviceWorker.register');
    expect(scripts).toContain("navigator.serviceWorker.register('/sw.js').catch(function() {})");
  });
});
