import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// ModelSwitcher rendering-layer tests.
//
// Renders the real <ModelSwitcher /> plus useModelSwitcherData and the whole
// BrowseView/ProviderSectionRow/ModelRowItem chain, and checks that the default browse view
// lists the enabled models of connected providers, that clicking a model row calls
// onSelect(model, provider), that search filters, that an empty state appears when nothing
// matches, and that clicking the overlay calls onClose.
//
// The ModelSwitcher subtree has no store dependencies, and selectResolvedCatalog is a pure
// function (the metadata snapshot is null here, which is safe). next-intl uses the global
// key-passthrough mock from setup.ts.

import { act, fireEvent, render, screen, cleanup } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, ProviderKind } from '@oriveo/shared';
import * as capabilityFacade from '@oriveo/core/providers/capability-evidence-facade';

import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../lib/core/metadata/metadata-client';

import { ModelSwitcher } from './ModelSwitcher';

afterEach(() => {
  cleanup();
  __resetMetadataClientForTest();
  localStorage.clear();
});

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'model',
    name: 'Model',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...overrides,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p1',
    kind: 'openAI' as ProviderKind,
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...',
    ...overrides,
  } as Provider;
}

function renderSwitcher(props: Partial<React.ComponentProps<typeof ModelSwitcher>> = {}) {
  const onSelect = vi.fn();
  const onEnableAndSelect = vi.fn();
  const onAddManualAndSelect = vi.fn();
  const onClose = vi.fn();
  const providers = props.providers ?? [
    makeProvider({
      id: 'p1',
      models: [
        makeModel({ id: 'alpha', name: 'Alpha Model', isDefault: true }),
        makeModel({ id: 'bravo', name: 'Bravo Model' }),
      ],
    }),
  ];
  const view = render(
    <ModelSwitcher
      providers={providers}
      onSelect={onSelect}
      onEnableAndSelect={onEnableAndSelect}
      onAddManualAndSelect={onAddManualAndSelect}
      onClose={onClose}
      {...props}
    />,
  );
  return { view, onSelect, onEnableAndSelect, onAddManualAndSelect, onClose, providers };
}

function modelRows(): HTMLElement[] {
  return Array.from(document.querySelectorAll('[data-model-row="true"]')) as HTMLElement[];
}

describe('ModelSwitcher rendering layer', () => {
  it('does one capability projection per generation across 810 models in list rows and unrelated search re-renders', () => {
    const models = Array.from({ length: 810 }, (_, index) => makeModel({
      id: `model-${index}`,
      name: `Model ${index}`,
      transport: 'openai_chat',
      capabilities: [],
      capabilityEvidenceCandidates: [],
    }));
    const provider = makeProvider({ models });
    const resolveSpy = vi.spyOn(capabilityFacade, 'resolveCapabilityEvidence');

    renderSwitcher({ providers: [provider] });

    // Reasoning and Web now consume the Server recipe/control verdict directly.
    // Only vision and tool calling still require evidence-facade projection.
    expect(resolveSpy).toHaveBeenCalledTimes(810 * 2);
    fireEvent.change(screen.getByPlaceholderText('searchPlaceholder'), { target: { value: 'Model' } });
    expect(resolveSpy).toHaveBeenCalledTimes(810 * 2);
    resolveSpy.mockRestore();
  });

  it('lists enabled models of connected providers in the default browse view', () => {
    renderSwitcher();
    expect(screen.getByText('Alpha Model')).toBeTruthy();
    expect(screen.getByText('Bravo Model')).toBeTruthy();
    expect(modelRows()).toHaveLength(2);
  });

  it('does not show the internal isDefault state as a default model badge', () => {
    renderSwitcher();
    expect(screen.queryByText('defaultShort')).toBeNull();
  });

  it('does not render a hollow recommendation dot for recommended models', () => {
    const { view } = renderSwitcher({
      providers: [
        makeProvider({
          models: [makeModel({ name: 'Recommended Model', isRecommended: true })],
        }),
      ],
    });

    expect(screen.getByText('Recommended Model')).toBeTruthy();
    expect(view.container.querySelector('.recommendedDot')).toBeNull();
  });

  it('calls onSelect(model, provider) when a model row is clicked', () => {
    const { onSelect } = renderSwitcher();
    fireEvent.click(screen.getByText('Alpha Model').closest('[data-model-row="true"]')!);
    expect(onSelect).toHaveBeenCalledTimes(1);
    expect(onSelect).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'alpha' }),
      expect.objectContaining({ id: 'p1' }),
    );
  });

  it('filters by model name as the search box is typed into', () => {
    renderSwitcher();
    fireEvent.change(screen.getByPlaceholderText('searchPlaceholder'), { target: { value: 'bravo' } });
    expect(screen.queryByText('Alpha Model')).toBeNull();
    expect(screen.getByText('Bravo Model')).toBeTruthy();
    expect(modelRows()).toHaveLength(1);
  });

  it('shows the empty state and renders no model rows when the search matches nothing', () => {
    renderSwitcher();
    fireEvent.change(screen.getByPlaceholderText('searchPlaceholder'), { target: { value: 'zzz-nomatch' } });
    expect(modelRows()).toHaveLength(0);
    expect(screen.getByText('noResults')).toBeTruthy();
  });

  it('recomputes the current capability filter when the evidence TTL expires', async () => {
    // Fake only the clock this case actually needs: the capability evidence expiry scheduler uses
    // `window.setTimeout` plus `Date.now()` (`use-capability-evidence-expiry.ts`). The default
    // full useFakeTimers also takes over `setImmediate` and microtasks, and that is exactly what
    // drives fake-indexeddb's event queue. If an IDB operation is in flight inside the fake clock
    // window the queue never advances again and every later test's IDB write hangs forever;
    // switching back to real timers does not recover it.
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    vi.setSystemTime(new Date('2026-08-09T00:00:00Z'));
    const model = makeModel({
      id: 'vision-expiring',
      name: 'Vision Expiring',
      capabilities: [],
      transport: 'openai_chat',
      capabilityEvidenceCandidates: [{
        key: 'vision_input',
        support: 'supported',
        source: 'server_profile',
        grade: 'effect_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'vision-expiring',
        transport: 'openai_chat',
        expiresAt: Date.now() + 1_000,
      }],
    });
    const view = renderSwitcher({ providers: [makeProvider({ models: [model] })] }).view;

    fireEvent.click(screen.getByRole('button', { name: 'image' }));
    expect(screen.getByText('Vision Expiring')).toBeTruthy();

    await act(async () => {
      vi.advanceTimersByTime(1_001);
    });
    expect(screen.queryByText('Vision Expiring')).toBeNull();
    expect(screen.getByText('noEnabledModels')).toBeTruthy();

    view.unmount();
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  // -- Capability visibility in front of the model switcher ---------------------------------
  //
  // In production only about 11% of models are auto_available for reasoning and 47% for web
  // search, so users currently hit the wall only after picking a model. Badges and filters may
  // only reuse the existing verdict function (capabilityAvailableForDisplay); no second rule.
  it('capability filter chips carry real match counts and use the same verdict as the row badges', async () => {
    await __seedMetadataCacheForTest({
      data: {
        version: 1,
        contractVersion: 1,
        updatedAt: '2026-08-15T00:00:00Z',
        profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
        capabilityRuntime: {
          schemaVersion: 2,
          revision: 'switcher-runtime',
          generatedAt: '2026-08-15T00:00:00Z',
          recipes: { 'fixture.web': { id: 'fixture.web' } },
          controlDefinitions: {},
          sourceIndex: {},
        },
        providers: {},
        providerConfigs: [],
      },
      timestamp: Date.now(),
    });
    await initMetadata();
    const withWeb = makeModel({
      id: 'has-web', name: 'Has Web', capabilities: [], transport: 'openai_chat',
      capabilityControls: { web: { state: 'auto_available', recipeRef: 'fixture.web' } },
      capabilityEvidenceCandidates: [{
        key: 'web_search', support: 'supported', source: 'server_profile', grade: 'effect_verified',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'has-web', transport: 'openai_chat',
      }],
    });
    const plain = makeModel({ id: 'plain', name: 'Plain', capabilities: [], transport: 'openai_chat' });
    renderSwitcher({ providers: [makeProvider({ models: [withWeb, plain] })] });

    const webChip = screen.getByRole('button', { name: 'web' });
    // The number must come from real matches rather than "how many models there are", so web=1 and reasoning=0 are asserted together.
    expect(webChip.getAttribute('data-count')).toBe('1');
    expect(screen.getByRole('button', { name: 'reasoning' }).getAttribute('data-count')).toBe('0');
    expect(webChip.textContent).toContain('1');

    // Same source as the row badge: the model left after clicking this chip is exactly the badged one.
    fireEvent.click(webChip);
    expect(screen.getByText('Has Web')).toBeTruthy();
    expect(screen.queryByText('Plain')).toBeNull();
  });

  /**
   * Primary action: arriving here from a "not adjustable" row via "show models supporting this
   * parameter", the switcher lists only the models on which the parameter is really adjustable.
   * The test reuses the existing chain (`modelMatchesFilters` ->
   * `modelSupportsGenerationParameter` -> facade) rather than adding a second one.
   */
  it('requiredGenerationParameterId lists only models on which that parameter is really adjustable', async () => {
    // The profile must come from the production parse chain (metadata snapshot through
    // resolveGenerationProfileRef); hand-writing a profile object would reimplement the very rule
    // under test.
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
      data: {
        version: 1, contractVersion: 1, updatedAt: '2026-08-13T00:00:00Z',
        profiles: {
          reasoning: {}, webSearch: {}, imageGen: {},
          generation: {
            parameters: { top_p: { group: 'sampling', valueSchema: 'number', portability: 'portable' } },
            templates: { switcher_fixture: { transport: 'openai_chat_completions', wire: { top_p: 'top_p' } } },
          },
        },
        providers: {}, providerConfigs: [],
      },
      timestamp: Date.now(),
    });
    await initMetadata();

    const profileOf = (support: string) => ({
      template: 'switcher_fixture',
      parameters: [{ id: 'top_p', support, source: 'authoritative_metadata', valueSchema: 'number' }],
    });
    const supported = makeModel({
      id: 'supports-top-p', name: 'Supports TopP', transport: 'openai_chat',
      generationProfile: profileOf('supported'),
    } as Partial<AIModel>);
    const rejected = makeModel({
      id: 'rejects-top-p', name: 'Rejects TopP', transport: 'openai_chat',
      generationProfile: profileOf('unsupported'),
    } as Partial<AIModel>);

    renderSwitcher({
      providers: [makeProvider({ models: [supported, rejected] })],
      requiredGenerationParameterId: 'top_p',
    });

    expect(screen.getByText('Supports TopP')).toBeTruthy();
    expect(screen.queryByText('Rejects TopP')).toBeNull();

    // Reverse assertion, so "the filter works" cannot be implemented as always true: without a parameter id both models are present.
    cleanup();
    renderSwitcher({ providers: [makeProvider({ models: [supported, rejected] })] });
    expect(screen.getByText('Supports TopP')).toBeTruthy();
    expect(screen.getByText('Rejects TopP')).toBeTruthy();
  });

  it('calls onClose when the overlay is clicked', () => {
    const { onClose, view } = renderSwitcher();
    const overlay = view.container.querySelector('.overlay');
    expect(overlay).toBeTruthy();
    fireEvent.click(overlay!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('leaves providers that are not connected and not currently selected out of the browse list', () => {
    renderSwitcher({
      providers: [
        makeProvider({ id: 'p1', models: [makeModel({ id: 'alpha', name: 'Alpha Model', isDefault: true })] }),
        makeProvider({
          id: 'p2',
          status: { kind: 'issue', message: 'key expired' },
          models: [makeModel({ id: 'gamma', name: 'Gamma Model', isDefault: true })],
        }),
      ],
    });
    expect(screen.getByText('Alpha Model')).toBeTruthy();
    expect(screen.queryByText('Gamma Model')).toBeNull();
  });
});
