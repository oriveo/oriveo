import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { compileOwnedPatches } from '../owned-patch-compiler';

const base = { tools: [{ type: 'function', name: 'weather' }] };
const overlay = { channel: 'body_fragment', metrics: { bytes: 10, depth: 1, nodes: 1 }, declaredOwners: { '/temperature': 'generation' as const }, operations: [{ owner: 'generation' as const, op: 'set', pointer: '/temperature', value: 0 }] };

describe('owned patch compiler', () => {
  it('composes a delta and redacted preview without erasing builder tools', () => {
    expect(compileOwnedPatches(overlay, [], base, [{ owner: 'web', target: 'tools', operation: 'append_owned', identity: 'web_search', value: { type: 'web_search' } }])).toEqual({ accepted: true, delta: { temperature: 0, tools: [{ type: 'function', name: 'weather' }, { type: 'web_search' }] }, preview: { temperature: 0, tools: [{ type: 'function', name: 'weather' }, { type: 'web_search' }] } });
  });
  it('fails cross-owner writes before producing a delta', () => {
    expect(compileOwnedPatches({ ...overlay, operations: [{ owner: 'web', op: 'set', pointer: '/temperature', value: 0 }] }, [], base, [])).toEqual({ accepted: false, reason: 'cross_owner' });
  });
  it('fails closed when an untyped contribution omits its required operation', () => {
    const contribution = { owner: 'web', target: 'tools', identity: 'web_search', value: { type: 'web_search' } };
    expect(compileOwnedPatches(overlay, [], base, [contribution as never])).toEqual({ accepted: false, reason: 'non_append_operation' });
  });
  it('consumes the shared compiler fixture: nested pointer, stable duplicate identity, and preview redaction', () => {
    const fixture = JSON.parse(readFileSync(resolve(process.cwd(), '../../../shared/model-contracts/owned_patch_compiler.v1.json'), 'utf8'));
    const canonical = JSON.parse(readFileSync(resolve(process.cwd(), '../../../shared/model-contracts/request_preference_contract.v2.json'), 'utf8'));
    expect(fixture.contractId).toBe('owned_patch_compiler.v1');
    expect(fixture.mustExclude).toEqual(canonical.redactedPreview.mustExclude);
    for (const item of fixture.cases) {
      const result = compileOwnedPatches({ channel: 'body_fragment', metrics: { bytes: 32, depth: 2, nodes: 2 }, declaredOwners: item.declaredOwners, operations: item.operations }, item.declaredConflicts ?? [], item.base, item.contributions);
      expect(result).toMatchObject(item.expect);
    }
  });
});
