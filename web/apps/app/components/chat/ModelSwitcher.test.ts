import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AIModel, Provider, ProviderKind } from '@oriveo/shared';
import {
  getDefaultExpandedModelSwitcherProviderIds,
  sortModelSwitcherProviders,
} from './model-switcher-sorting';
import { sortProviderModels } from './ModelSwitcher/model-switcher-data';

describe('ModelSwitcher styles', () => {
  it('keeps scroll-list children from shrinking', () => {
    const css = readFileSync(resolve(process.cwd(), 'components/chat/ModelSwitcher.module.css'), 'utf8');

    expect(css).toMatch(/\.list\s*>\s*\*\s*\{[^}]*flex-shrink:\s*0;/s);
  });

  it('centers the desktop dialog within the chat overlay layer, not the viewport', () => {
    const css = readFileSync(resolve(process.cwd(), 'components/chat/ModelSwitcher.module.css'), 'utf8');

    expect(css).toMatch(/\.overlay\s*\{[^}]*position:\s*absolute;[^}]*pointer-events:\s*auto;/s);
    expect(css).toMatch(/\.dropdown\s*\{[^}]*position:\s*absolute;[^}]*width:\s*min\(640px,\s*calc\(100% - 40px\)\);[^}]*height:\s*min\(720px,\s*calc\(100% - 56px\)\);/s);
    expect(css).not.toMatch(/\.dropdown\s*\{[^}]*position:\s*fixed;/s);
  });
});

describe('ModelSwitcher provider sorting', () => {
  it('keeps the selected user provider first', () => {
    const providers = [
      makeProvider('openrouter', 'openRouter', [makeModel('gpt-5')]),
      makeProvider('relay-empty', 'relay', [], 'yls'),
    ];

    expect(sortModelSwitcherProviders(providers, 'relay-empty').map((provider) => provider.id)).toEqual([
      'relay-empty',
      'openrouter',
    ]);
  });

  it('defaults expansion to the first sorted provider only', () => {
    const providers = [
      makeProvider('relay-empty', 'relay', [], 'yls'),
      makeProvider('openrouter', 'openRouter', [makeModel('gpt-5')]),
    ];

    const sorted = sortModelSwitcherProviders(providers);

    expect([...getDefaultExpandedModelSwitcherProviderIds(sorted)]).toEqual(['openrouter']);
  });

  it('defaults expansion to the selected provider when provided', () => {
    const providers = [
      makeProvider('openrouter', 'openRouter', [makeModel('gpt-5')]),
      makeProvider('relay-empty', 'relay', [], 'yls'),
    ];

    expect([...getDefaultExpandedModelSwitcherProviderIds(providers, 'relay-empty')]).toEqual(['relay-empty']);
  });

  it('falls back to first provider when selected id is not in the list', () => {
    const providers = [
      makeProvider('openrouter', 'openRouter', [makeModel('gpt-5')]),
      makeProvider('relay-empty', 'relay', [], 'yls'),
    ];

    expect([...getDefaultExpandedModelSwitcherProviderIds(providers, 'unknown')]).toEqual([
      'openrouter',
    ]);
  });
});

describe('ModelSwitcher model sorting', () => {
  const groupedModel = (id: string, name: string, groupKey: string): AIModel => ({
    id,
    name,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    groupKey,
    groupName: groupKey,
  });

  // Regression: ProviderSectionRow builds vendor groups in order of first appearance, so the order of
  // the model list is the group order. Reordering locally by isRecommended or name would make a group.sort_order change in the admin console wait for a release to take effect.
  it('still sorts BYOK provider models by default then recommended then name', () => {
    const models = [
      { ...groupedModel('zeta', 'Zeta', 'vendor'), isRecommended: false },
      { ...groupedModel('alpha', 'Alpha', 'vendor'), isRecommended: false },
      { ...groupedModel('beta', 'Beta', 'vendor'), isRecommended: true },
      { ...groupedModel('omega', 'Omega', 'vendor'), isDefault: true },
    ];

    expect(sortProviderModels(models, 'openRouter').map((model) => model.id)).toEqual([
      'omega',
      'beta',
      'alpha',
      'zeta',
    ]);
  });

  it('sorts when no provider kind is supplied', () => {
    const models = [groupedModel('zeta', 'Zeta', 'vendor'), groupedModel('alpha', 'Alpha', 'vendor')];

    expect(sortProviderModels(models).map((model) => model.id)).toEqual(['alpha', 'zeta']);
  });
});

function makeProvider(
  id: string,
  kind: ProviderKind,
  models: AIModel[],
  customName?: string,
): Provider {
  return {
    id,
    kind,
    status: { kind: 'connected' },
    models,
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...',
    customName,
  };
}

function makeModel(id: string): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '',
  };
}
