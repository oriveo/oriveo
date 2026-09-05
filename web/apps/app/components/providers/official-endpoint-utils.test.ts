import { describe, expect, it } from 'vitest';
import {
  getOfficialEndpointDescriptionTranslationKey,
  getOfficialEndpointOptionTranslationKey,
  resolveOfficialEndpointOptions,
  resolveSelectedOfficialEndpointId,
} from './official-endpoint-utils';

describe('official-endpoint-utils', () => {
  it('offers a fallback list of official endpoints for a region-locked provider', () => {
    expect(resolveOfficialEndpointOptions('miniMax')).toEqual([
      {
        id: 'global',
        label: 'Global (api.minimax.io)',
        baseURL: 'https://api.minimax.io/v1',
      },
      {
        id: 'cn',
        label: 'China Mainland (api.minimaxi.com)',
        baseURL: 'https://api.minimaxi.com/v1',
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
      {
        id: 'intl',
        label: 'International (api.siliconflow.com)',
        baseURL: 'https://api.siliconflow.com/v1',
        apiKeyHelpURL: 'https://cloud.siliconflow.com/account/ak',
      },
    ]);
    expect(resolveOfficialEndpointOptions('zhipu')).toEqual([]);
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
