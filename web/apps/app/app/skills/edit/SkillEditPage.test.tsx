import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Skill } from '@oriveo/shared';
import { SkillEditPage } from './SkillEditPage';

type MockSearchParams = {
  get: (key: string) => string | null;
};

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  searchParamGet: vi.fn<(key: string) => string | null>(),
  getSkillById: vi.fn(),
  createSkillOp: vi.fn(),
  updateSkillOp: vi.fn(),
  showToast: vi.fn(),
  vanillaStore: {
    getState: vi.fn(),
    // SkillEditPage subscribes to store changes in a useEffect (the capability key is recomputed when
    // providers change), so the test mock must provide subscribe and return a callable unsubscribe
    subscribe: vi.fn(() => () => {}),
  },
}));

function makeSkill(overrides: Partial<Skill> = {}): Skill {
  return {
    id: overrides.id ?? 'skill-1',
    key: overrides.key,
    name: overrides.name ?? 'Assistant',
    description: overrides.description ?? 'Description',
    icon: overrides.icon ?? '✨',
    color: overrides.color ?? '#8B5CF6',
    systemPrompt: overrides.systemPrompt ?? 'You are helpful.',
    suggestedProviderId: overrides.suggestedProviderId,
    suggestedModelId: overrides.suggestedModelId,
    modelCapabilityHint: overrides.modelCapabilityHint ?? 'any',
    temperature: overrides.temperature,
    reasoningLevel: overrides.reasoningLevel,
    webSearchEnabled: overrides.webSearchEnabled,
    starterMessages: overrides.starterMessages ?? ['Hello'],
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
  useSearchParams: (): MockSearchParams => ({
    get: mocks.searchParamGet,
  }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../../providers/StoreProvider', () => ({
  getVanillaStore: () => mocks.vanillaStore,
}));

vi.mock('../../../lib/core/skills/ops', () => ({
  getSkillById: (...args: unknown[]) => mocks.getSkillById(...args),
  createSkillOp: (...args: unknown[]) => mocks.createSkillOp(...args),
  updateSkillOp: (...args: unknown[]) => mocks.updateSkillOp(...args),
}));

vi.mock('../../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

describe('SkillEditPage', () => {
  beforeEach(() => {
    mocks.routerPush.mockReset();
    mocks.searchParamGet.mockReset();
    mocks.getSkillById.mockReset();
    mocks.createSkillOp.mockReset();
    mocks.updateSkillOp.mockReset();
    mocks.showToast.mockReset();
    mocks.vanillaStore.getState.mockReset();

    mocks.searchParamGet.mockReturnValue(null);
    mocks.createSkillOp.mockResolvedValue(undefined);
    mocks.updateSkillOp.mockResolvedValue(undefined);
    mocks.vanillaStore.getState.mockReturnValue({
      providers: [
        {
          id: 'openai-1',
          kind: 'openAI',
          apiKey: 'sk-openai',
          apiKeyPreview: '••••openai',
          baseURLText: 'https://api.openai.com/v1',
          models: [{ id: 'gpt-5.4-mini', name: 'GPT-5.4 mini' }],
          catalogModels: [],
          status: { kind: 'connected' },
        },
      ],
      userSkills: [],
    });
  });

  it('loads an existing skill and saves updates in edit mode', async () => {
    const existing = makeSkill({
      id: 'skill-edit-1',
      name: 'Writing Coach',
      description: 'Helps improve writing',
      systemPrompt: 'Provide concise writing feedback.',
      starterMessages: ['Polish this paragraph'],
      knowledgeBase: {
        provider: 'openai',
        retrievalModel: 'gpt-5.4-mini',
        vectorStoreId: 'vs_123',
        expiresAfterDays: 90,
        files: [],
        updatedAt: '2026-04-01T00:00:00.000Z',
      },
    });
    mocks.searchParamGet.mockImplementation((key: string) => (key === 'id' ? 'skill-edit-1' : null));
    mocks.getSkillById.mockReturnValue(existing);

    render(<SkillEditPage />);

    await waitFor(() => {
      expect((screen.getByPlaceholderText('namePlaceholder') as HTMLInputElement).value).toBe('Writing Coach');
    });

    fireEvent.click(screen.getByRole('button', { name: 'save' }));

    await waitFor(() => {
        expect(mocks.updateSkillOp).toHaveBeenCalledWith(
          mocks.vanillaStore,
          'skill-edit-1',
          expect.objectContaining({
            name: 'Writing Coach',
            description: 'Helps improve writing',
            systemPrompt: 'Provide concise writing feedback.',
            starterMessages: [],
            knowledgeBase: expect.objectContaining({
              provider: 'openai',
              retrievalModel: 'gpt-5.4-mini',
              vectorStoreId: 'vs_123',
            }),
          }),
        );
    });
    expect(mocks.routerPush).toHaveBeenCalledWith('/skills');
  });

  it('creates a new skill when required fields are filled', async () => {
    render(<SkillEditPage />);

    fireEvent.change(screen.getByPlaceholderText('namePlaceholder'), {
      target: { value: 'Research Copilot' },
    });
    fireEvent.change(screen.getByPlaceholderText('instructionsPlaceholder'), {
      target: { value: 'Answer with references and concise bullets.' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'save' }));

    await waitFor(() => {
      expect(mocks.createSkillOp).toHaveBeenCalledWith(
        mocks.vanillaStore,
        expect.objectContaining({
          name: 'Research Copilot',
          systemPrompt: 'Answer with references and concise bullets.',
        }),
      );
    });
    expect(mocks.routerPush).toHaveBeenCalledWith('/skills');
  });

  it('persists uploaded reference files with the new knowledge file metadata', async () => {
    const randomUUIDSpy = vi.spyOn(globalThis.crypto, 'randomUUID').mockReturnValue('file-1');

    render(<SkillEditPage />);

    fireEvent.change(screen.getByPlaceholderText('namePlaceholder'), {
      target: { value: 'Research Copilot' },
    });
    fireEvent.change(screen.getByPlaceholderText('instructionsPlaceholder'), {
      target: { value: 'Answer with references and concise bullets.' },
    });

    const file = new File(['Alpha'], 'notes.txt', { type: 'text/plain' });
    Object.defineProperty(file, 'text', {
      value: vi.fn().mockResolvedValue('Alpha'),
    });

    const fileInput = document.querySelector('input[type="file"]');
    expect(fileInput).not.toBeNull();

    fireEvent.change(fileInput as HTMLInputElement, {
      target: { files: [file] },
    });

    await waitFor(() => {
      expect(screen.getByText('notes.txt')).toBeTruthy();
    });

    fireEvent.click(screen.getByRole('button', { name: 'save' }));

    await waitFor(() => {
      expect(mocks.createSkillOp).toHaveBeenCalledWith(
        mocks.vanillaStore,
        expect.objectContaining({
          knowledgeFiles: expect.arrayContaining([
            expect.objectContaining({
              id: 'file-1',
              name: 'notes.txt',
              mimeType: 'text/plain',
              sourceType: 'text',
              content: 'Alpha',
              charCount: 5,
              createdAt: expect.any(String),
              updatedAt: expect.any(String),
            }),
          ]),
        }),
      );
    });

    randomUUIDSpy.mockRestore();
  });

  it('guards back navigation when there are unsaved changes', async () => {
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);

    render(<SkillEditPage />);

    fireEvent.change(screen.getByPlaceholderText('namePlaceholder'), {
      target: { value: 'Unsaved name' },
    });
    fireEvent.click(screen.getByRole('button', { name: /title/ }));

    expect(confirmSpy).toHaveBeenCalledWith('discardChangesMessage');
    expect(mocks.routerPush).not.toHaveBeenCalled();

    confirmSpy.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: /title/ }));

    await waitFor(() => {
      expect(mocks.routerPush).toHaveBeenCalledWith('/skills');
    });
    confirmSpy.mockRestore();
  });

});
