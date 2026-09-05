import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import type { Skill, SkillCategory, SkillUsage } from '@oriveo/shared';
import { SkillsPage } from './SkillsPage';

type MockSkillsState = {
  catalogSkills: Skill[];
  userSkills: Skill[];
  skillCategories: SkillCategory[];
};

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  getCatalogByCategory: vi.fn(),
  deleteSkillOp: vi.fn(),
  forkSkillOp: vi.fn(),
  updateSkillOp: vi.fn(),
  togglePinOp: vi.fn(),
  startConversationWithSkill: vi.fn(),
  hasAuthenticatedUser: vi.fn(),
  showToast: vi.fn(),
  setActiveConversationId: vi.fn(),
  setLastUsedModelRef: vi.fn(),
  getState: vi.fn(),
}));

let mockState: MockSkillsState = {
  catalogSkills: [],
  userSkills: [],
  skillCategories: [],
};

let mockSkillUsage: SkillUsage = {
  count: 0,
  limit: 5,
};

function makeSkill(overrides: Partial<Skill> = {}): Skill {
  return {
    id: overrides.id ?? 'skill-1',
    key: overrides.key,
    name: overrides.name ?? 'Skill',
    description: overrides.description ?? '',
    icon: overrides.icon ?? '✨',
    color: overrides.color ?? '#4A90D9',
    systemPrompt: overrides.systemPrompt ?? 'Prompt',
    suggestedProviderId: overrides.suggestedProviderId,
    suggestedModelId: overrides.suggestedModelId,
    modelCapabilityHint: overrides.modelCapabilityHint ?? 'any',
    temperature: overrides.temperature,
    reasoningLevel: overrides.reasoningLevel,
    webSearchEnabled: overrides.webSearchEnabled,
    starterMessages: overrides.starterMessages ?? [],
    knowledgeFiles: overrides.knowledgeFiles ?? [],
    knowledgeBase: overrides.knowledgeBase ?? null,
    useMemory: overrides.useMemory ?? true,
    isPinned: overrides.isPinned ?? false,
    pinOrder: overrides.pinOrder ?? 0,
    source: overrides.source ?? 'user',
    forkedFromId: overrides.forkedFromId,
    category: overrides.category,
    sortOrder: overrides.sortOrder ?? 0,
    usageCount: overrides.usageCount ?? 0,
    lastUsedAt: overrides.lastUsedAt,
    createdAt: overrides.createdAt ?? '2026-04-01T00:00:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-04-01T00:00:00.000Z',
  };
}

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.routerPush,
  }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('@oriveo/ui', () => ({
  Dialog: ({ open, children }: { open: boolean; children: ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
  Button: ({ children, onClick }: { children: ReactNode; onClick?: () => void }) => (
    <button type="button" onClick={onClick}>{children}</button>
  ),
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockSkillsState) => unknown) => selector(mockState),
  getVanillaStore: () => ({
    getState: mocks.getState,
  }),
}));

vi.mock('../../lib/core/skills/ops', () => ({
  getCatalogByCategory: (...args: unknown[]) => mocks.getCatalogByCategory(...args),
  deleteSkillOp: (...args: unknown[]) => mocks.deleteSkillOp(...args),
  forkSkillOp: (...args: unknown[]) => mocks.forkSkillOp(...args),
  updateSkillOp: (...args: unknown[]) => mocks.updateSkillOp(...args),
  togglePinOp: (...args: unknown[]) => mocks.togglePinOp(...args),
}));

vi.mock('../../lib/core/skills/start-conversation', () => ({
  startConversationWithSkill: (...args: unknown[]) => mocks.startConversationWithSkill(...args),
}));

vi.mock('../../lib/hooks/useSkillL10n', () => ({
  useSkillL10n: () => ({
    localizedName: (skill: Skill) => skill.name,
    localizedDescription: (skill: Skill) => skill.description,
    localizedCategoryName: (category: SkillCategory) => category.name,
  }),
}));

vi.mock('../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

describe('SkillsPage', () => {
  beforeEach(() => {
    mockState = {
      catalogSkills: [],
      userSkills: [],
      skillCategories: [],
    };
    mockSkillUsage = {
      count: 0,
      limit: 5,
        };

    mocks.routerPush.mockReset();
    mocks.getCatalogByCategory.mockReset();
    mocks.deleteSkillOp.mockReset();
    mocks.forkSkillOp.mockReset();
    mocks.updateSkillOp.mockReset();
    mocks.togglePinOp.mockReset();
    mocks.startConversationWithSkill.mockReset();
    mocks.hasAuthenticatedUser.mockReset();
    mocks.showToast.mockReset();
    mocks.setActiveConversationId.mockReset();
    mocks.setLastUsedModelRef.mockReset();
    mocks.getState.mockReset();

    mocks.getCatalogByCategory.mockImplementation(() => new Map([
      ['general', mockState.catalogSkills],
    ]));
    mocks.startConversationWithSkill.mockReturnValue({ kind: 'ok', conversationId: 'new-conv' });
    mocks.hasAuthenticatedUser.mockReturnValue(true);
    mocks.getState.mockImplementation(() => ({
      catalogSkills: mockState.catalogSkills,
      skillUsage: mockSkillUsage,
      setActiveConversationId: mocks.setActiveConversationId,
      setLastUsedModelRef: mocks.setLastUsedModelRef,
    }));
  });

  it('opens the skill editor when creating a new skill', () => {
    render(<SkillsPage />);

    fireEvent.click(screen.getByRole('button', { name: /newSkill/ }));

    expect(mocks.routerPush).toHaveBeenCalledWith('/skills/edit');
  });

  it('opens an in-app provider prompt instead of routing immediately when no model can be resolved for a skill', async () => {
    mockState.userSkills = [makeSkill({ id: 'skill-a', name: 'Draft Skill' })];
    mocks.startConversationWithSkill.mockReturnValue({ kind: 'no-provider' });

    render(<SkillsPage />);

    fireEvent.click(screen.getByRole('button', { name: 'useSkill' }));

    await waitFor(() => {
      expect(mocks.showToast).toHaveBeenCalledWith('needProvider');
    });
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(screen.getByText('providerRequiredTitle')).toBeTruthy();
    expect(mocks.routerPush).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'providerRequiredAction' }));

    expect(mocks.routerPush).toHaveBeenCalledWith('/providers/new');
  });

  it('starts a draft conversation and navigates to it when use is clicked', async () => {
    mockState.userSkills = [makeSkill({ id: 'skill-use-1', name: 'Use Skill' })];
    mocks.startConversationWithSkill.mockReturnValue({ kind: 'ok', conversationId: 'conv-id-99' });

    render(<SkillsPage />);

    fireEvent.click(screen.getByRole('button', { name: 'useSkill' }));

    await waitFor(() => {
      expect(mocks.startConversationWithSkill).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ id: 'skill-use-1' }),
        expect.objectContaining({ title: 'Use Skill' }),
      );
    });
    expect(mocks.routerPush).toHaveBeenCalledWith('/chat/conv-id-99');
  });

  it('pins a skill without a local cap', async () => {
    mockState.catalogSkills = [
      makeSkill({ id: 'builtin-1', source: 'builtin', isPinned: true }),
      makeSkill({ id: 'builtin-2', source: 'builtin', isPinned: true }),
      makeSkill({ id: 'builtin-3', source: 'builtin', isPinned: true }),
    ];
    mockState.userSkills = [
      makeSkill({ id: 'user-1', name: 'My Skill', isPinned: false }),
    ];

    render(<SkillsPage />);

    fireEvent.click(screen.getByTitle('pinToHome'));

    await waitFor(() => {
      expect(mocks.togglePinOp).toHaveBeenCalled();
    });
  });

  it('passes knowledge cleanup credentials when deleting a skill with a remote knowledge base', async () => {
    mockState.userSkills = [
      makeSkill({
        id: 'skill-delete-1',
        name: 'Knowledge Skill',
        knowledgeBase: {
          provider: 'openai',
          retrievalModel: 'gpt-5.4-mini',
          vectorStoreId: 'vs_123',
          expiresAfterDays: 90,
          files: [
            {
              id: 'kb-1',
              name: 'guide.txt',
              mimeType: 'text/plain',
              sizeBytes: 42,
              ingestionMode: 'native_file',
              openAIFileId: 'file-openai-1',
              status: 'ready',
              createdAt: '2026-04-01T00:00:00.000Z',
              updatedAt: '2026-04-01T00:00:00.000Z',
            },
          ],
          updatedAt: '2026-04-01T00:00:00.000Z',
        },
      }),
    ];
    mocks.getState.mockImplementation(() => ({
      catalogSkills: mockState.catalogSkills,
      skillUsage: mockSkillUsage,
      providers: [
        {
          id: 'openai-1',
          kind: 'openAI',
          apiKey: 'sk-openai',
          apiKeyPreview: '••••openai',
          baseURLText: 'https://api.openai.com/v1',
          models: [{ id: 'gpt-5.4-mini' }],
        },
      ],
      setActiveConversationId: mocks.setActiveConversationId,
      setLastUsedModelRef: mocks.setLastUsedModelRef,
    }));

    render(<SkillsPage />);

    fireEvent.click(screen.getByTitle('deleteSkill'));
    fireEvent.click(screen.getByRole('button', { name: 'deleteSkill' }));

    await waitFor(() => {
      expect(mocks.deleteSkillOp).toHaveBeenCalledWith(
        expect.anything(),
        'skill-delete-1',
        {
          apiKey: 'sk-openai',
          baseURL: 'https://api.openai.com/v1',
        },
      );
    });
  });
});
