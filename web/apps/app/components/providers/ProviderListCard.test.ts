import { render, screen } from '@testing-library/react';
import { createElement } from 'react';
import { describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  ProviderListCard,
  resolveProviderListTrailingAmount,
  shouldShowProviderListErrorCopy,
} from './ProviderListCard';

/**
 * ProviderListCard unit tests: kindCaption, enabledModelsText and the list-level error body policy.
 */

// Pure logic lifted out of the component so it can be tested directly
function resolveKindCaption(
  displayName: string,
  kindDisplayName: string,
): string | null {
  return displayName !== kindDisplayName ? kindDisplayName : null;
}

function resolveAddedModelsText(
  isRelay: boolean,
  enabledCount: number,
  availableCount: number,
): string | null {
  if (isRelay) return null;
  if (enabledCount === availableCount) return null;
  return `${enabledCount} added`;
}

describe('ProviderListCard logic', () => {
  describe('resolveKindCaption', () => {
    it('returns null when displayName matches kind name', () => {
      expect(resolveKindCaption('OpenAI', 'OpenAI')).toBeNull();
    });

    it('returns kind name when displayName differs', () => {
      expect(resolveKindCaption('Custom Name', 'OpenAI')).toBe('OpenAI');
    });

    it('returns kind name for renamed relay providers to match iOS', () => {
      expect(resolveKindCaption('My Relay', 'Relay')).toBe('Relay');
    });
  });

  describe('resolveAddedModelsText', () => {
    it('returns null for relay', () => {
      expect(resolveAddedModelsText(true, 5, 10)).toBeNull();
    });

    it('returns null when enabled equals available', () => {
      expect(resolveAddedModelsText(false, 10, 10)).toBeNull();
    });

    it('returns added text when enabled differs from available', () => {
      expect(resolveAddedModelsText(false, 3, 10)).toBe('3 added');
    });
  });

  describe('error banner visibility', () => {
    it('hides list-level error copy when status is issue with lastError', () => {
      expect(shouldShowProviderListErrorCopy({
        status: { kind: 'issue', message: 'invalid_key' },
        lastError: 'API key invalid',
      })).toBe(false);
    });

    it('hides error when connected', () => {
      expect(shouldShowProviderListErrorCopy({
        status: { kind: 'connected' },
        lastError: undefined,
      })).toBe(false);
    });

    it('hides error when issue but no lastError', () => {
      expect(shouldShowProviderListErrorCopy({
        status: { kind: 'issue', message: 'invalid_key' },
        lastError: undefined,
      })).toBe(false);
    });
  });
});

vi.mock('next-intl', () => ({
  useLocale: () => 'en-US',
  useTranslations: () => (key: string, params?: Record<string, unknown>) => {
    if (key === 'metricsModels') return `${params?.count} models`;
    if (key === 'metricsAddedModels') return `${params?.count} added models`;
    if (key === 'metricsThisMonth') return 'This Month';
    if (key === 'neverSynced') return 'Never';
    if (key === 'lastSynced') return String(params?.time ?? '');
    if (key === 'connected') return 'connected';
    if (key === 'syncing') return 'syncing';
    if (key === 'issue') return 'issue';
    return key;
  },
}));

vi.mock('../../lib/core/store/selectors', () => ({
  selectResolvedCatalog: (provider: Provider) => ({
    availableModelCount: provider.catalogModels.length || provider.models.length,
    enabledModels: provider.models,
  }),
}));

describe('ProviderListCard rendering', () => {
  it('uses provider balance for capable BYOK kinds and never falls back to consumption', () => {
    expect(resolveProviderListTrailingAmount('siliconFlow', 42, {
      currency: 'CNY',
      total: 88.88,
      fetchedAt: new Date(),
    }, 'en-US')).toEqual({
      label: 'balanceLabel',
      text: '¥88.88',
      isZero: false,
    });
    expect(resolveProviderListTrailingAmount('deepseek', 42, null, 'en-US')).toEqual({
      label: 'balanceLabel',
      text: '--',
      isZero: false,
    });
  });

  it('labels non-capable BYOK amounts as usage', () => {
    expect(resolveProviderListTrailingAmount('openAI', 2.5, null, 'en-US')).toEqual({
      label: 'usageLabel',
      text: '$2.50',
      isZero: false,
    });
  });

  // Per-provider spend is local estimatedCost; it is not a hosted usage report.
  it('shows local per-provider spend', () => {
    expect(resolveProviderListTrailingAmount('openAI', 31.2, null, 'en-US')).toEqual({
      label: 'usageLabel',
      text: '$31.20',
      isZero: false,
    });
    expect(resolveProviderListTrailingAmount('anthropic', 0, null, 'en-US')).toEqual({
      label: 'usageLabel',
      text: '$0',
      isZero: true,
    });
  });

  it('renders inline issue status after the provider name (aligned with iOS nameRow)', () => {
    const provider: Provider = {
      id: 'openrouter-1',
      kind: 'openRouter',
      status: { kind: 'issue', message: 'invalid_key' },
      models: [
        {
          id: 'openrouter/auto',
          name: 'OpenRouter Auto',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
      ],
      catalogModels: [],
      apiKey: 'sk-test',
      apiKeyPreview: 'sk-t',
    };

    render(createElement(ProviderListCard, { provider, monthlyCost: 0, onClick: () => {} }));

    const rowText = screen.getByRole('button').textContent ?? '';
    // The name comes first and the inline status after it
    expect(rowText.indexOf('OpenRouter')).toBeGreaterThanOrEqual(0);
    expect(rowText.indexOf('issue')).toBeGreaterThan(rowText.indexOf('OpenRouter'));
  });

  it('renders renamed relay with customName only, no kind caption (aligned with iOS Hero/List)', () => {
    const provider: Provider = {
      id: 'relay-1',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [
        {
          id: 'gpt-4o',
          name: 'gpt-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
      ],
      catalogModels: [],
      apiKey: 'sk-test',
      apiKeyPreview: 'sk-t',
      baseURLText: 'https://relay.example.com/v1',
      customName: 'Work Relay',
    };

    render(createElement(ProviderListCard, { provider, monthlyCost: 0, onClick: () => {} }));

    expect(screen.getByText('Work Relay')).toBeTruthy();
    // The sub row carries only "models - sync time", with no kind caption label
    expect(screen.queryByText('Relay')).toBeNull();
    expect(screen.getByText('Never')).toBeTruthy();
    expect(screen.queryByText('https://relay.example.com/v1')).toBeNull();
  });
});
