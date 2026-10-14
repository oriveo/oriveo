import { describe, expect, it } from 'vitest';
import {
  getOfficialEndpointDescriptionTranslationKey,
  getOfficialEndpointOptionTranslationKey,
  resolveOfficialEndpointOptions,
  resolveSelectedOfficialEndpointId,
} from './official-endpoint-utils';

describe('official-endpoint-utils', () => {
  it('offers a fallback list of official endpoints for a region-locked provider (without a trusted table only options in the built-in fallback domains remain)', () => {
    expect(resolveOfficialEndpointOptions('miniMax')).toEqual([
      {
        id: 'global',
        label: 'Global (api.minimax.io)',
        baseURL: 'https://api.minimax.io/v1',
      },
    ]);

    expect(resolveOfficialEndpointOptions('qwen')[0]?.id).toBe('sg');
    expect(resolveOfficialEndpointOptions('siliconFlow')).toEqual([
      {
        id: 'cn',
        label: 'China Mainland (api.siliconflow.cn)',
        baseURL: 'https://api.siliconflow.cn/v1',
        apiKeyHelpURL: 'https://cloud.siliconflow.cn/account/ak',
      },
    ]);
    expect(resolveOfficialEndpointOptions('moonshot').map((option) => option.id)).toEqual(['intl']);
    expect(resolveOfficialEndpointOptions('zhipu')).toEqual([]);
  });

  it('runs the hard-coded fallback options through the delivered trusted table too: when filtering leaves nothing, no host outside the trusted table appears', () => {
    // Every delivered region is filtered out -> fall back to the hard-coded table, keeping only hosts inside the trusted table.
    const config = { kind: 'miniMax', displayName: 'MiniMax', defaultBaseURL: '', regionOptions: [], trustedHosts: ['minimaxi.com'] };
    expect(resolveOfficialEndpointOptions('miniMax', config).map((option) => option.baseURL))
      .toEqual(['https://api.minimaxi.com/v1']);
    const both = { ...config, trustedHosts: ['minimax.io', 'minimaxi.com'] };
    expect(resolveOfficialEndpointOptions('miniMax', both).map((option) => option.id)).toEqual(['global', 'cn']);
    const foreign = { ...config, trustedHosts: ['example.com'] };
    expect(resolveOfficialEndpointOptions('miniMax', foreign)).toEqual([]);
  });

  it('prefers the endpoint configuration returned in metadata', () => {
    expect(resolveOfficialEndpointOptions('qwen', {
      kind: 'qwen',
      displayName: 'Qwen',
      defaultBaseURL: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
      regionOptions: [
        {
          id: 'eu',
          label: 'Frankfurt',
          baseURL: 'https://dashscope-eu.aliyuncs.com/compatible-mode/v1',
        },
      ],
    })).toEqual([
      {
        id: 'eu',
        label: 'Frankfurt',
        baseURL: 'https://dashscope-eu.aliyuncs.com/compatible-mode/v1',
      },
    ]);
  });

  it('derives the currently selected endpoint from an existing baseURL', () => {
    const options = resolveOfficialEndpointOptions('qwen');

    expect(resolveSelectedOfficialEndpointId(
      options,
      'https://dashscope.aliyuncs.com/compatible-mode/v1/',
    )).toBe('bj');

    expect(resolveSelectedOfficialEndpointId(options, undefined)).toBe('sg');
  });

  it('exposes stable translation keys', () => {
    expect(getOfficialEndpointOptionTranslationKey('miniMax', 'global')).toBe(
      'endpointOptions.miniMax.global',
    );
    expect(getOfficialEndpointOptionTranslationKey('qwen', 'hk')).toBe(
      'endpointOptions.qwen.hk',
    );
    expect(getOfficialEndpointOptionTranslationKey('qwen', 'unknown')).toBeNull();
    expect(getOfficialEndpointOptionTranslationKey('siliconFlow', 'intl')).toBe(
      'endpointOptions.siliconFlow.intl',
    );
    expect(getOfficialEndpointDescriptionTranslationKey('miniMax')).toBe(
      'officialEndpointDescriptionMiniMax',
    );
    expect(getOfficialEndpointDescriptionTranslationKey('qwen')).toBe(
      'officialEndpointDescriptionQwen',
    );
    expect(getOfficialEndpointDescriptionTranslationKey('siliconFlow')).toBe(
      'officialEndpointDescriptionSiliconFlow',
    );
  });
});
