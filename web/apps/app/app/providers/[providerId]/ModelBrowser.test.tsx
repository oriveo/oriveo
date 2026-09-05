import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import * as capabilityFacade from '@oriveo/core/providers/capability-evidence-facade';
import { getVendorBadgePresentation, ModelBrowser } from './ModelBrowser';

function makeModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: overrides.name ?? id,
    capabilities: overrides.capabilities ?? [],
    reasoningModeAvailable: overrides.reasoningModeAvailable ?? false,
    isAvailable: overrides.isAvailable ?? true,
    isDefault: overrides.isDefault ?? false,
    priceTier: overrides.priceTier ?? '',
    summary: overrides.summary,
    groupKey: overrides.groupKey,
    groupName: overrides.groupName,
    sortRank: overrides.sortRank,
    createdAt: overrides.createdAt,
    promptPrice: overrides.promptPrice,
    completionPrice: overrides.completionPrice,
    contextLength: overrides.contextLength,
    maxOutputTokens: overrides.maxOutputTokens,
    cacheReadInputPerMToken: overrides.cacheReadInputPerMToken,
    cacheCreationInputPerMToken: overrides.cacheCreationInputPerMToken,
    cacheWrite5mPerMToken: overrides.cacheWrite5mPerMToken,
    cacheWrite1hPerMToken: overrides.cacheWrite1hPerMToken,
    transport: overrides.transport,
    toolCall: overrides.toolCall,
    capabilityEvidenceCandidates: overrides.capabilityEvidenceCandidates,
  };
}

function makeProvider(models: AIModel[]): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'local-test-key',
    apiKeyPreview: 'local-test-preview',
  } as Provider;
}

describe('ModelBrowser', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('renders shortcut suppliers first and keeps groups collapsed by default', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('openai/gpt-4.1', { name: 'GPT-4.1', groupKey: 'openai', groupName: 'OpenAI' }),
          makeModel('anthropic/claude-3.7-sonnet', {
            name: 'Claude 3.7 Sonnet',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
        ]}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.getByTestId('shortcut-openai')).toBeTruthy();
    expect(screen.getByTestId('shortcut-anthropic')).toBeTruthy();
    // Collapsed groups render no modelRow
    expect(screen.queryByRole('button', { name: /addModel: GPT-4\.1/i })).toBeNull();
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeNull();
  });

  it('renders managed catalog group logos through the shared vendor identity', () => {
    const managedGroups = [
      ['google-gemini', 'Google Gemini', '/plogos/light/gemini.png'],
      ['xai-grok', 'xAI Grok', '/plogos/light/grok.png'],
      ['kimi', 'Kimi', '/plogos/light/kimi.png'],
      ['zhipu-glm', 'Z.ai GLM', '/plogos/light/zai.png'],
    ] as const;

    render(
      <ModelBrowser
        catalogModels={managedGroups.map(([groupKey, groupName]) => makeModel(`${groupKey}-model`, {
          groupKey,
          groupName,
        }))}
        providerKind="openAI"
        providerLabel="a user-owned provider"
        preserveCatalogOrder
        onToggleModel={vi.fn()}
      />,
    );

    for (const [groupKey, , expectedSrc] of managedGroups) {
      const logo = screen.getByTestId(`group-${groupKey}`).querySelector('img');
      const renderedSrc = logo?.getAttribute('src') ?? '';
      const originalSrc = renderedSrc.startsWith('/_next/image?')
        ? new URL(renderedSrc, 'https://oriveo.local').searchParams.get('url')
        : renderedSrc;
      expect(originalSrc).toBe(expectedSrc);
    }
  });

  it('expands a supplier group when its shortcut is clicked', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('openai/gpt-4.1', { name: 'GPT-4.1', groupKey: 'openai', groupName: 'OpenAI' }),
          makeModel('anthropic/claude-3.7-sonnet', {
            name: 'Claude 3.7 Sonnet',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
        ]}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByTestId('shortcut-anthropic'));

    const anthropicGroup = screen.getByTestId('group-anthropic');
    expect(within(anthropicGroup).getByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeTruthy();
    // The unexpanded openai group is still visible as a collapsed header, but its model rows are not rendered
    expect(screen.getByTestId('group-openai')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /addModel: GPT-4\.1/i })).toBeNull();
  });

  it('toggles back to collapsed when shortcut clicked again or All clicked', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('openai/gpt-4.1', { name: 'GPT-4.1', groupKey: 'openai', groupName: 'OpenAI' }),
          makeModel('anthropic/claude-3.7-sonnet', {
            name: 'Claude 3.7 Sonnet',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
        ]}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByTestId('shortcut-anthropic'));
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeTruthy();

    // Clicking the anthropic shortcut again collapses it
    fireEvent.click(screen.getByTestId('shortcut-anthropic'));
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeNull();

    // Once expanded, clicking "All" collapses everything as well
    fireEvent.click(screen.getByTestId('shortcut-anthropic'));
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeTruthy();
    const allBtn = screen.getByRole('button', { name: /allSuppliers/i });
    fireEvent.click(allBtn);
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeNull();
  });

  it('remembers the expanded supplier group locally', () => {
    const models = [
      makeModel('openai/gpt-4.1', { name: 'GPT-4.1', groupKey: 'openai', groupName: 'OpenAI' }),
      makeModel('anthropic/claude-3.7-sonnet', {
        name: 'Claude 3.7 Sonnet',
        groupKey: 'anthropic',
        groupName: 'Anthropic',
      }),
    ];
    const { unmount } = render(
      <ModelBrowser
        catalogModels={models}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByTestId('shortcut-anthropic'));
    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeTruthy();

    unmount();
    render(
      <ModelBrowser
        catalogModels={models}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.queryByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /addModel: GPT-4\.1/i })).toBeNull();
  });

  it('flattens to search-results mode when query matches a supplier', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('anthropic/claude-3.7-sonnet', {
            name: 'Claude 3.7 Sonnet',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
          makeModel('anthropic/claude-3.5-haiku', {
            name: 'Claude 3.5 Haiku',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
          makeModel('openai/gpt-4.1', {
            name: 'GPT-4.1',
            groupKey: 'openai',
            groupName: 'OpenAI',
          }),
        ]}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByPlaceholderText('searchModels'), {
      target: { value: 'anthropic' },
    });

    expect(screen.getByText('Claude 3.7 Sonnet')).toBeTruthy();
    expect(screen.getByText('Claude 3.5 Haiku')).toBeTruthy();
    expect(screen.queryByText('GPT-4.1')).toBeNull();
  });

  it('adds a model from model search results', () => {
    const onToggleModel = vi.fn();
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('anthropic/claude-3.7-sonnet', {
            name: 'Claude 3.7 Sonnet',
            groupKey: 'anthropic',
            groupName: 'Anthropic',
          }),
        ]}
        providerKind="openRouter"
        providerLabel="OpenRouter"
        onToggleModel={onToggleModel}
      />,
    );

    fireEvent.change(screen.getByPlaceholderText('searchModels'), {
      target: { value: 'claude' },
    });
    fireEvent.click(screen.getByRole('button', { name: /addModel: Claude 3\.7 Sonnet/i }));

    expect(onToggleModel).toHaveBeenCalledTimes(1);
    expect(onToggleModel).toHaveBeenCalledWith(expect.objectContaining({
      id: 'anthropic/claude-3.7-sonnet',
    }));
  });

  it('uses the custom sort menu to change catalog ordering', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('alpha-model', {
            name: 'Alpha Model',
            promptPrice: 0.8,
            completionPrice: 0.8,
          }),
          makeModel('zeta-model', {
            name: 'Zeta Model',
            promptPrice: 0.1,
            completionPrice: 0.1,
          }),
        ]}
        providerKind="openAI"
        providerLabel="OpenAI"
        onToggleModel={vi.fn()}
      />,
    );

    // A direct provider is a flat list by default (no search needed first), so both rows are visible
    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe('addModel: Alpha Model');

    fireEvent.click(screen.getByRole('button', { name: 'sortBy' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: /sortPrice/ }));

    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe('addModel: Zeta Model');
  });

  it('preserves server catalog order when requested', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('zeta-managed', {
            name: 'Zeta Managed',
            groupKey: 'managed-low',
            groupName: 'Managed Low',
            sortRank: 1,
          }),
          makeModel('alpha-managed', {
            name: 'Alpha Managed',
            groupKey: 'managed-low',
            groupName: 'Managed Low',
            sortRank: 1,
          }),
          makeModel('beta-managed', {
            name: 'Beta Managed',
            groupKey: 'managed-high',
            groupName: 'Managed High',
            sortRank: 100,
          }),
        ]}
        providerKind="openAI"
        providerLabel="a user-owned provider"
        preserveCatalogOrder
        onToggleModel={vi.fn()}
      />,
    );

    const shortcuts = screen
      .getAllByRole('button')
      .filter((button) => button.getAttribute('data-testid')?.startsWith('shortcut-'));
    expect(shortcuts[0]?.getAttribute('data-testid')).toBe('shortcut-managed-low');

    fireEvent.click(screen.getByTestId('shortcut-managed-low'));

    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe(
      'addModel: Zeta Managed',
    );
  });

  it('renders context and complete token pricing metadata in model rows', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('managed-model', {
            name: 'Managed Model',
            contextLength: 128_000,
            promptPrice: 0.00000125,
            completionPrice: 0.00000375,
            cacheReadInputPerMToken: 0.125,
            cacheCreationInputPerMToken: 1.5,
          }),
        ]}
        providerKind="openAI"
        providerLabel="a user-owned provider"
        preserveCatalogOrder
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.getByText('contextLength 128K')).toBeTruthy();
    expect(screen.getByText('input')).toBeTruthy();
    expect(screen.getByText('output')).toBeTruthy();
    expect(screen.getByText('cacheRead')).toBeTruthy();
    expect(screen.getByText('cacheWrite')).toBeTruthy();
  });

  it('omits cache price metadata when the catalog does not provide a cache price', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('sparse-model', {
            name: 'Sparse Model',
            promptPrice: 0.00000125,
            completionPrice: 0.00000375,
          }),
        ]}
        providerKind="openAI"
        providerLabel="a user-owned provider"
        preserveCatalogOrder
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.getByText('input')).toBeTruthy();
    expect(screen.getByText('output')).toBeTruthy();
    expect(screen.queryByText('cacheRead')).toBeNull();
    expect(screen.queryByText('cacheWrite')).toBeNull();
  });

  it('can reset back to the recommended order after choosing another sort', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('older-model', {
            name: 'Older Model',
            createdAt: 100,
            promptPrice: 0.1,
            completionPrice: 0.1,
          }),
          makeModel('newer-model', {
            name: 'Newer Model',
            createdAt: 200,
            promptPrice: 0.9,
            completionPrice: 0.9,
          }),
        ]}
        providerKind="openAI"
        providerLabel="OpenAI"
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe('addModel: Newer Model');

    fireEvent.click(screen.getByRole('button', { name: 'sortBy' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: /sortPrice/ }));
    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe('addModel: Older Model');

    fireEvent.click(screen.getByRole('button', { name: 'sortBy' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: /sortRecommended/ }));
    expect(screen.getAllByRole('button', { name: /addModel:/i })[0]?.getAttribute('aria-label')).toBe('addModel: Newer Model');
  });

  it('shows unavailable models as disabled instead of allowing them to be added', () => {
    render(
      <ModelBrowser
        catalogModels={[
          makeModel('legacy-model', {
            name: 'Legacy Model',
            isAvailable: false,
            summary: 'Deprecated model',
          }),
        ]}
        providerKind="openAI"
        providerLabel="OpenAI"
        onToggleModel={vi.fn()}
      />,
    );

    expect(screen.getByText('unavailable')).toBeTruthy();
    expect((screen.getByRole('button', { name: /addModel/i }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('recomputes an evidence-backed capability filter when its TTL expires', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-08-09T00:00:00Z'));
    const expiresAt = Date.now() + 1_000;
    const model = makeModel('evidence-model', {
      name: 'Evidence Model',
      transport: 'openai_chat',
      capabilityEvidenceCandidates: [{
        key: 'vision_input',
        support: 'supported',
        source: 'server_profile',
        grade: 'effect_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'evidence-model',
        transport: 'openai_chat',
        expiresAt,
      }],
    });
    const provider = makeProvider([model]);
    const view = render(
      <ModelBrowser
        catalogModels={[model]}
        providerKind="openAI"
        providerLabel="OpenAI"
        provider={provider}
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'image' }));
    expect(screen.getByText('Evidence Model')).toBeTruthy();

    await act(async () => {
      vi.advanceTimersByTime(1_001);
    });
    expect(screen.queryByText('Evidence Model')).toBeNull();
    expect(screen.getByText('noModelsFound')).toBeTruthy();

    view.unmount();
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  it('offers a Tool filter and keeps only models approved by the central tool_call verdict', () => {
    const supported = makeModel('tool-model', {
      name: 'Tool Model',
      transport: 'openai_chat',
      toolCall: true,
    });
    const unsupported = makeModel('plain-model', {
      name: 'Plain Model',
      transport: 'openai_chat',
      toolCall: false,
    });
    const provider = makeProvider([supported, unsupported]);

    render(
      <ModelBrowser
        catalogModels={[supported, unsupported]}
        providerKind="openAI"
        providerLabel="OpenAI"
        provider={provider}
        onToggleModel={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'toolCall' }));
    expect(screen.getByText('Tool Model')).toBeTruthy();
    expect(screen.queryByText('Plain Model')).toBeNull();
  });

  it('projects an 810-model catalog once across grouping, sorting, rows, and unrelated search renders', () => {
    const models = Array.from({ length: 810 }, (_, index) => makeModel(`model-${index}`, {
      name: `Model ${index}`,
      groupKey: `group-${index % 10}`,
      groupName: `Group ${index % 10}`,
      transport: 'openai_chat',
      capabilityEvidenceCandidates: [],
    }));
    const provider = makeProvider(models);
    const resolveSpy = vi.spyOn(capabilityFacade, 'resolveCapabilityEvidence');

    render(
      <ModelBrowser
        catalogModels={models}
        providerKind="openAI"
        providerLabel="OpenAI"
        provider={provider}
        onToggleModel={vi.fn()}
      />,
    );

    // The number of times each model is projected is deliberately not pinned. It used to be
    // `810 * 7`, and converging capability badges and chat controls onto the same verdict moved
    // web and reasoning off the evidence facade onto the same verdict the composer uses, leaving
    // only vision_input and tool_call on the facade, which made it 810 x 2 in practice. That was
    // an intentional convergence, but it left this test red for three days with nobody noticing,
    // because ModelBrowser is not in WEB_TEST_PATHS. The magic 7 is not a contract, only an
    // implementation detail of the time; pinning it means every legitimate optimization has to
    // edit the test, and every such edit dilutes what the case is really guarding.
    //
    // The two real invariants:
    const afterInitialRender = resolveSpy.mock.calls.length;

    // 1. Projection is a constant number of times per model and does not grow non-linearly with
    //    catalog size. The bound is 810 x 7, the historical high-water mark, which a real
    //    regression into reprojecting every row on every render would blow far past.
    expect(afterInitialRender).toBeGreaterThan(0);
    expect(afterInitialRender).toBeLessThanOrEqual(810 * 7);
    expect(afterInitialRender % 810).toBe(0);

    // 2. An unrelated render (typing in the search box) must not trigger a single reprojection, which is what "once" in the case title means.
    fireEvent.change(screen.getByLabelText('searchModels'), { target: { value: 'Model' } });
    expect(resolveSpy).toHaveBeenCalledTimes(afterInitialRender);
    resolveSpy.mockRestore();
  });

  it('keeps dark theme vendor badges readable for logos without dark variants', () => {
    const presentation = getVendorBadgePresentation('aws', true);

    expect(presentation.darkBackground).toBe('#f7f8fa');
    expect(presentation.darkForeground).toBe('#0f172a');
  });
});
