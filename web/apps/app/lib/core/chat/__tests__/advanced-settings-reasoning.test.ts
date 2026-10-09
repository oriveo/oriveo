/**
 * When a reasoning-group parameter has no write path in this profile's wire table: it is not editable, the row says thinking is set in the model options, and no link out is offered.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { resolveGenerationProfile, type RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import { localEngineGenerationProfile } from '../local-engine-profiles';
import { reasoningRowWithoutWritePath } from '../advanced-settings-reasoning';

function contractMetadata(): RuntimeMetadataResponse {
  let dir = process.cwd();
  while (!existsSync(path.join(dir, 'shared/model-contracts/request_shape_contract.v1.json'))) dir = path.dirname(dir);
  return JSON.parse(readFileSync(path.join(dir, 'shared/model-contracts/request_shape_contract.v1.json'), 'utf8')).metadata;
}

describe('reasoningRowWithoutWritePath', () => {
  it('official Anthropic (profile resolved from metadata): the three reasoning-group items have no write path -> not editable, set by the thinking setting, no link out', () => {
    const profile = resolveGenerationProfile(contractMetadata(), {
      template: 'anthropic_messages',
      parameters: ['max_output_tokens', 'temperature', 'reasoning_effort', 'reasoning_budget', 'reasoning_mode']
        .map((id) => ({ id, support: 'supported', source: 'official_docs' })),
    } as never)!;
    expect(profile.wire.reasoning_effort).toBeUndefined();
    for (const id of ['reasoning_effort', 'reasoning_budget', 'reasoning_mode']) {
      const parameter = profile.parameters.find((item) => item.id === id)!;
      expect(parameter.group, id).toBe('reasoning');
      expect(reasoningRowWithoutWritePath(parameter, profile), id).toEqual({
        editable: false, statusNote: 'reasoningSetByThinking', offersSupportedModels: false,
      });
    }
    // Parameters outside the reasoning group are not handled here.
    expect(reasoningRowWithoutWritePath(profile.parameters.find((item) => item.id === 'temperature')!, profile)).toBeUndefined();
  });

  it('reasoning-group parameters with a write path are unaffected (Ollama reasoning_effort); an empty-string wire counts as no write path', () => {
    const ollama = localEngineGenerationProfile('ollama', undefined)!;
    const effort = ollama.parameters.find((item) => item.id === 'reasoning_effort')!;
    expect(reasoningRowWithoutWritePath(effort, ollama)).toBeUndefined();
    expect(reasoningRowWithoutWritePath(effort, { ...ollama, wire: { ...ollama.wire, reasoning_effort: '' } })?.statusNote).toBe('reasoningSetByThinking');
  });
});
