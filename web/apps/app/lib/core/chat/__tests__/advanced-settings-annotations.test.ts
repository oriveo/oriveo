import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Page-level tone and inline annotations for "unverified". The criteria come only from showsUnverifiedBadge, the presentation-class table, and showsUnverifiedGroupNote.
 */
import { describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { resolveGenerationParameterEvidence } from '../capability-evidence';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { buildProviderStreamOptions, relayGenerationProfile } from '../stream-options';
import { advancedRowAnnotationInput, resolveRowAnnotations, type AdvancedRowAnnotationInput } from '../advanced-settings-annotations';

const unverified = (id: string, presentationClass: AdvancedRowAnnotationInput['presentationClass'] = 'unverified') =>
  ({ id, presentationClass, isUnverified: true });
const plain = (id: string, presentationClass: AdvancedRowAnnotationInput['presentationClass'] = 'silent') =>
  ({ id, presentationClass, isUnverified: false });

describe('resolveRowAnnotations', () => {
  it('more than half unverified -> say it once in the header; unverified rows of the same tone class are no longer annotated inline', () => {
    expect(resolveRowAnnotations([unverified('a'), unverified('b'), plain('c', 'not_adjustable')])).toEqual({
      showsPageNote: true, inlineIds: ['c'],
    });
  });

  it('exactly half does not set the tone: every row keeps its own inline annotation', () => {
    expect(resolveRowAnnotations([unverified('a'), unverified('b'), plain('c'), plain('d', 'no_data')])).toEqual({
      showsPageNote: false, inlineIds: ['a', 'b', 'd'],
    });
  });

  it('under a page tone, unverified rows whose presentation class differs from the tone class are still annotated inline; ties pick the class name that sorts last', () => {
    const rows = [unverified('a'), unverified('b'), unverified('c', 'no_data'), unverified('d', 'no_data'), plain('e')];
    expect(resolveRowAnnotations(rows)).toEqual({ showsPageNote: true, inlineIds: ['c', 'd'] });
  });

  it('the header note must also satisfy showsUnverifiedGroupNote', () => {
    const rows = [unverified('a'), unverified('b')];
    expect(resolveRowAnnotations(rows, [{ source: 'server_profile', grade: 'declared' }]).showsPageNote).toBe(false);
  });

  it('production profile of a local engine connection with a real evidence projection: the page tone holds and there are no inline annotations', () => {
    const provider = {
      id: 'provider-relay-annotations', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
      apiKey: 'fixture-only', apiKeyPreview: '', baseURLText: 'https://relay.example/v1',
      relayResolvedBaseURLText: 'https://relay.example/v1', relayResolvedTransport: 'openai_chat_completions',
      relayRequested: { transport: 'openai_chat_completions', engineProfile: 'llamacpp' },
    } as unknown as Provider;
    const profile = relayGenerationProfile(provider)!;
    const model = {
      id: 'local-model', name: 'local-model', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: false, priceTier: '', transport: 'openai_chat',
    } as unknown as AIModel;
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const streamOptions = buildProviderStreamOptions(provider, undefined, model);
    const evidence = profile.parameters.map((parameter) => resolveGenerationParameterEvidence({
      provider, model, profile, parameterId: parameter.id, hasExplicitValue: false, streamOptions,
    }));
    const rows = profile.parameters.map((parameter, index) => advancedRowAnnotationInput(parameter.id, parameter.support, evidence[index]));
    expect(rows.length).toBeGreaterThan(8);
    expect(rows.every((row) => row.isUnverified)).toBe(true);
    expect(resolveRowAnnotations(rows, evidence)).toEqual({ showsPageNote: true, inlineIds: [] });
  });
});
