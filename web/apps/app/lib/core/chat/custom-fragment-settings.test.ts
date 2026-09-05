import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  customFragmentEntryState,
  customFragmentOwnerFacts,
  customFragmentScope,
  forwardPortCustomFragmentsIfNeeded,
  isCustomFragmentEligible,
  loadCustomFragmentSettings,
  migrateRetiredCustomFragmentDeveloperGate,
  resolveCustomFragments,
  saveCustomFragmentSettings,
} from './custom-fragment-settings';
import { encodeCapabilityTransportIdentity } from './capability-preference-settings';
import {
  capabilityRejectionIsDormant,
  locateCapabilityRecovery,
  recordCapabilityRejection,
} from './capability-recovery-runtime';

const model = {
  id: 'model', name: 'Model', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  capabilityControls: {
    web: { state: 'auto_available', customControlRefs: ['qwen.web.enable_search'] },
    reasoning: { state: 'auto_available', customControlRefs: ['openai.reasoning.effort'] },
    generation: { state: 'auto_available', customControlRefs: ['openai.generation.max_output_tokens'] },
  },
} as AIModel;
const relay = { id: 'connection', kind: 'qwen', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as Provider;
const runtime = vi.hoisted(() => ({
  controlDefinitions: {
    'qwen.web.enable_search': { id: 'qwen.web.enable_search', owner: 'web', targetPointer: '/enable_search', sourceRefs: ['qwen.web_search'] },
    'openai.reasoning.effort': { id: 'openai.reasoning.effort', owner: 'reasoning', targetPointer: '/reasoning/effort', sourceRefs: ['openai.reasoning'] },
    'openai.generation.max_output_tokens': { id: 'openai.generation.max_output_tokens', owner: 'generation', targetPointer: '/max_output_tokens', sourceRefs: ['openai.reasoning'] },
  },
  sourceIndex: { 'qwen.web_search': {}, 'openai.reasoning': {} },
}));

// `customFragmentOwnerFacts` / `customFragmentEntryState` read the global runtime, while the
// outbound gate takes an explicit argument. Both paths must see the same schema, or a false
// state such as "the UI says unused while it is actually being sent" cannot be caught.
vi.mock('../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../metadata/metadata-client')>(),
  getCapabilityRuntime: () => runtime,
}));

describe('owner-scoped custom fragment local boundary', () => {
  beforeEach(() => localStorage.clear());

  it('isolates owner × connection × model × exact transport and Auto never emits raw', () => {
    const web = customFragmentScope(relay, model, 'transport-a', 'web');
    const reasoning = customFragmentScope(relay, model, 'transport-a', 'reasoning');
    saveCustomFragmentSettings(web, { configurationMode: 'custom', raw: '{"enable_search":true}' });
    saveCustomFragmentSettings(reasoning, { configurationMode: 'auto', raw: '{"reasoning":{"effort":"high"}}' });

    expect(loadCustomFragmentSettings(web).raw).toContain('enable_search');
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, 'transport-b', 'web')).raw).toBe('');
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toEqual({ web: { raw: '{"enable_search":true}' } });
  });

  // "Custom selected but empty" fails closed. The editor shows a warning that messages using the
  // control will fail to send, so a silent downgrade would make that a lie, and it would quietly
  // change the user's configuration at the send boundary - a decision they never made.
  it('hands an empty custom selection to the compiler to fail closed without rewriting storage at the send boundary', () => {
    const scope = customFragmentScope(relay, model, 'transport-a', 'generation');
    saveCustomFragmentSettings(scope, { configurationMode: 'custom', raw: '' });
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toEqual({ generation: { raw: '' } });
    expect(loadCustomFragmentSettings(scope).configurationMode).toBe('custom');
  });

  it('drops dangling/cross-owner refs', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, 'transport-a', 'web'), { configurationMode: 'custom', raw: '{"enable_search":true}' });
    const withoutRefs = { ...model, capabilityControls: {} } as AIModel;
    expect(resolveCustomFragments({ provider: relay, model: withoutRefs, transportIdentity: 'transport-a', allow: true, runtime })).toBeUndefined();
    const dangling = { ...model, capabilityControls: { web: { state: 'auto_available', customControlRefs: ['missing'] } } } as AIModel;
    expect(resolveCustomFragments({ provider: relay, model: dangling, transportIdentity: 'transport-a', allow: true, runtime })).toBeUndefined();
    const crossOwner = { ...model, capabilityControls: { web: { state: 'auto_available', customControlRefs: ['openai.reasoning.effort'] } } } as AIModel;
    expect(resolveCustomFragments({ provider: relay, model: crossOwner, transportIdentity: 'transport-a', allow: true, runtime })).toBeUndefined();
    const unsafeRuntime = { ...runtime, controlDefinitions: {
      ...runtime.controlDefinitions,
      'qwen.web.enable_search': { ...runtime.controlDefinitions['qwen.web.enable_search'], targetPointer: '/headers/authorization' },
    } };
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime: unsafeRuntime })).toBeUndefined();
  });

  it('never resolves for excluded request shapes', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, 'transport-a', 'web'), { configurationMode: 'custom', raw: '{}' });
    expect(isCustomFragmentEligible(relay)).toBe(true);
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: false, runtime })).toBeUndefined();
  });

  // --- No global developer gate ------------------------------------------
  //
  // The only condition for going out on the wire is that this configuration itself is set to
  // custom. A single global key cannot govern a pile of settings stored per
  // connection x model x transport: the user could never tell whether a given connection was on.
  it('sends only when the configuration itself is set to custom, with no global switch involved', () => {
    const scope = customFragmentScope(relay, model, 'transport-a', 'web');
    saveCustomFragmentSettings(scope, { configurationMode: 'custom', raw: '{"enable_search":true}' });

    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toEqual({ web: { raw: '{"enable_search":true}' } });
    // The reverse: switching the same configuration back to auto sends nothing at all.
    saveCustomFragmentSettings(scope, { configurationMode: 'auto', raw: '{"enable_search":true}' });
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toBeUndefined();
  });

  // Migration tri-state plus idempotence. The old key appears here only, since nothing reads it.
  const RETIRED_GATE_KEY = 'oriveo.local-custom-fragment-developer-mode.v1';

  it('does nothing and writes no marker key when the old key is absent', () => {
    const scope = customFragmentScope(relay, model, 'transport-a', 'web');
    saveCustomFragmentSettings(scope, { configurationMode: 'custom', raw: '{"enable_search":true}' });

    migrateRetiredCustomFragmentDeveloperGate();

    expect(localStorage.getItem(RETIRED_GATE_KEY)).toBeNull();
    expect(loadCustomFragmentSettings(scope)).toEqual({ configurationMode: 'custom', raw: '{"enable_search":true}' });
  });

  it('only clears the key when the old key is true, leaving the configuration in effect', () => {
    const scope = customFragmentScope(relay, model, 'transport-a', 'web');
    saveCustomFragmentSettings(scope, { configurationMode: 'custom', raw: '{"enable_search":true}' });
    localStorage.setItem(RETIRED_GATE_KEY, 'true');

    migrateRetiredCustomFragmentDeveloperGate();

    expect(localStorage.getItem(RETIRED_GATE_KEY)).toBeNull();
    expect(loadCustomFragmentSettings(scope).configurationMode).toBe('custom');
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toEqual({ web: { raw: '{"enable_search":true}' } });
  });

  it('reverts stored enabled records to auto and keeps raw intact when the old key is false', () => {
    const web = customFragmentScope(relay, model, 'transport-a', 'web');
    const reasoning = customFragmentScope(relay, model, 'transport-a', 'reasoning');
    saveCustomFragmentSettings(web, { configurationMode: 'custom', raw: '{"enable_search":true}' });
    saveCustomFragmentSettings(reasoning, { configurationMode: 'auto', raw: '{"reasoning":{"effort":"high"}}' });
    localStorage.setItem(RETIRED_GATE_KEY, 'false');

    migrateRetiredCustomFragmentDeveloperGate();

    expect(localStorage.getItem(RETIRED_GATE_KEY)).toBeNull();
    expect(loadCustomFragmentSettings(web)).toEqual({ configurationMode: 'auto', raw: '{"enable_search":true}' });
    // A record that was already auto is left untouched.
    expect(loadCustomFragmentSettings(reasoning)).toEqual({ configurationMode: 'auto', raw: '{"reasoning":{"effort":"high"}}' });
    // Key assertion: the moment the gate disappears, these fragments must not suddenly start going out.
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toBeUndefined();
  });

  it('is idempotent: re-enabling after migration survives two more runs unchanged', () => {
    const web = customFragmentScope(relay, model, 'transport-a', 'web');
    saveCustomFragmentSettings(web, { configurationMode: 'custom', raw: '{"enable_search":true}' });
    localStorage.setItem(RETIRED_GATE_KEY, 'false');
    migrateRetiredCustomFragmentDeveloperGate();
    saveCustomFragmentSettings(web, { configurationMode: 'custom', raw: '{"enable_search":true}' });

    migrateRetiredCustomFragmentDeveloperGate();
    migrateRetiredCustomFragmentDeveloperGate();

    expect(loadCustomFragmentSettings(web).configurationMode).toBe('custom');
  });

  // The only objective proof that the gate is fully unwired: the old key and its reader exist in
  // exactly one place, the migration. Leaving an importable reader behind invites the next
  // person to wire it back into some condition.
  it('keeps the old key and its reader confined to the one-time migration', () => {
    const sources = collectSources(repoRoot());
    // Build the name from pieces, or this line itself would be a hit, since this file is scanned too.
    const gateSymbols = new RegExp(['customFragment', 'DeveloperModeEnabled'].join('')
      + '|' + ['CUSTOM_FRAGMENT', 'DEVELOPER_MODE_EVENT'].join('_'));
    const offenders = sources.filter((file) => gateSymbols.test(readFileSync(file, 'utf8')));
    expect(offenders).toEqual([]);

    const keyHolders = sources
      .filter((file) => readFileSync(file, 'utf8').includes('oriveo.local-custom-fragment-developer-mode.v1'))
      .filter((file) => !file.endsWith('.test.ts') && !file.endsWith('.test.tsx'));
    expect(keyHolders.map((file) => file.split('/apps/')[1])).toEqual([
      'app/lib/core/chat/custom-fragment-settings.ts',
    ]);
  });

  // Tri-state of the developer row under advanced settings; it reads the same facts as the outbound gate.
  it('developer entry tri-state: no schema is unsupported, schema present is idle, custom is in use', () => {
    const withoutSchema = { ...model, capabilityControls: {} } as AIModel;
    expect(customFragmentEntryState({ provider: relay, model: withoutSchema, transportIdentity: 'transport-a' }))
      .toBe('unsupported');
    expect(customFragmentEntryState({ provider: relay, model, transportIdentity: 'transport-a' })).toBe('idle');

    saveCustomFragmentSettings(customFragmentScope(relay, model, 'transport-a', 'reasoning'), {
      configurationMode: 'custom', raw: '{"reasoning":{"effort":"high"}}',
    });
    expect(customFragmentEntryState({ provider: relay, model, transportIdentity: 'transport-a' })).toBe('inUse');

    // The entry has to stay reachable after the server withdraws the schema, or the user loses the only way to turn it off.
    expect(customFragmentEntryState({ provider: relay, model: withoutSchema, transportIdentity: 'transport-a' }))
      .toBe('inUse');
    // Do not lie when identity is missing, and do not offer a page that cannot write anything.
    expect(customFragmentEntryState({ provider: relay, model, transportIdentity: undefined })).toBe('unsupported');
  });

  it('keeps a rejected blob dormant across cold reads and scoped explicit edit reconfirms only that custom owner', () => {
    const identity = {
      connectionId: '00000000-0000-4000-8000-000000000001',
      canonicalModelId: 'model',
      finalTransport: 'openai_responses',
      runtimeRevision: 'runtime-r7',
    };
    const baseScope = customFragmentScope(relay, model, 'transport-a', 'generation');
    saveCustomFragmentSettings(baseScope, { configurationMode: 'custom', raw: '{"temperature":0.2}' });
    const customDescriptor = locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { generation: ['/temperature'] },
    }, undefined)!;
    recordCapabilityRejection(identity, customDescriptor);
    recordCapabilityRejection(identity, { ...customDescriptor, owners: ['web'], locatedPointers: ['/enable_search'] });
    recordCapabilityRejection(identity, {
      ...customDescriptor, source: 'provider_recipe', recipeRef: 'fixture.generation.v1', locatedPointers: ['/temperature'],
    });

    expect(loadCustomFragmentSettings(baseScope).raw).toBe('{"temperature":0.2}');
    expect(capabilityRejectionIsDormant(identity, 'generation', 'custom')).toBe(true);

    saveCustomFragmentSettings({ ...baseScope, recoveryIdentity: identity }, {
      configurationMode: 'custom', raw: '{"temperature":0.4}',
    });

    expect(capabilityRejectionIsDormant(identity, 'generation', 'custom')).toBe(false);
    expect(capabilityRejectionIsDormant(identity, 'web', 'custom')).toBe(true);
    expect(capabilityRejectionIsDormant(identity, 'generation', 'provider_recipe')).toBe(true);
    expect(loadCustomFragmentSettings(baseScope).raw).toBe('{"temperature":0.4}');
  });
});

function repoRoot(): string {
  let current = process.cwd();
  while (!existsSync(path.join(current, 'apps/app/lib/core/chat/custom-fragment-settings.ts'))) {
    const next = path.dirname(current);
    if (next === current) throw new Error('web workspace root');
    current = next;
  }
  return current;
}

/** Scan source only: build output directories still hold symbols from an earlier compile, so scanning them scans history. */
function collectSources(directory: string): string[] {
  const skipped = new Set(['node_modules', '.next', '.next-dev', 'dist', 'out', '.turbo']);
  const files: string[] = [];
  const walk = (current: string) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.name.startsWith('.') && entry.name !== '.') continue;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (!skipped.has(entry.name)) walk(full);
      } else if (/\.(ts|tsx)$/.test(entry.name)) {
        files.push(full);
      }
    }
  };
  walk(path.join(directory, 'apps'));
  walk(path.join(directory, 'packages'));
  return files;
}

/**
 * Forward porting of custom fields across recipe versions.
 *
 * Typed preferences are a closed vocabulary and move across as-is; these are hand-written fields
 * that may be invalid under the new recipe, so they are revalidated against it and, when that
 * fails, paused with the draft kept.
 *
 * Custom fields have no conversation scope here - the key is connection x model x transport x
 * owner - so there is only one level to port.
 */
describe('custom field forward porting', () => {
  const older = encodeCapabilityTransportIdentity('openai_chat', 'runtime-r7');
  const current = encodeCapabilityTransportIdentity('openai_chat', 'runtime-r8');
  const otherTransport = encodeCapabilityTransportIdentity('anthropic_messages', 'runtime-r8');
  const port = (transportIdentity: string) => forwardPortCustomFragmentsIfNeeded({
    provider: relay, model, transportIdentity,
  });

  beforeEach(() => localStorage.clear());

  it('carries custom across unchanged when it is still valid under the new recipe', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });

    port(current);

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')))
      .toEqual({ configurationMode: 'custom', raw: '{"enable_search":true}' });
    // Sending resumes with it: a new recipe version must not silently stop a user's custom fields.
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: current, allow: true, runtime }))
      .toEqual({ web: { raw: '{"enable_search":true}' } });
  });

  it('disables but keeps raw intact when the new recipe rejects the draft', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"not_declared_here":true}',
    });

    port(current);

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')))
      .toEqual({ configurationMode: 'auto', raw: '{"not_declared_here":true}' });
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: current, allow: true, runtime }))
      .toBeUndefined();
  });

  it('disables anything whose original mode was not custom while still carrying the draft over', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'reasoning'), {
      configurationMode: 'auto', raw: '{"reasoning":{"effort":"high"}}',
    });

    port(current);

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'reasoning')))
      .toEqual({ configurationMode: 'auto', raw: '{"reasoning":{"effort":"high"}}' });
  });

  it('does not port when the protocol itself changed', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });

    port(otherTransport);

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, otherTransport, 'web')))
      .toEqual({ configurationMode: 'auto', raw: '' });
  });

  it('does not port when the target already has a record, leaving the old record in place', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });
    saveCustomFragmentSettings(customFragmentScope(relay, model, current, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":false}',
    });

    port(current);

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')).raw)
      .toBe('{"enable_search":false}');
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, older, 'web')).raw)
      .toBe('{"enable_search":true}');
  });

  // Change broadcasts go out on a microtask rather than synchronously, so the loop only becomes observable after the microtask queue drains.
  const flushBroadcasts = async () => { for (let round = 0; round < 3; round += 1) await Promise.resolve(); };

  it('is idempotent and reentrant: repeated runs change nothing and do not feed themselves', async () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });
    // Drain the broadcast from the setup write first, so every count below belongs to the forward port under test.
    await flushBroadcasts();
    // A write broadcasts an event and subscribers call back into forward porting when they refresh; this simulates that loop.
    let reentries = 0;
    const listener = () => {
      reentries += 1;
      if (reentries < 5) port(current);
    };
    window.addEventListener('oriveo:custom-fragment-settings', listener);
    try {
      port(current);
      port(current);
      port(current);
      await flushBroadcasts();
    } finally {
      window.removeEventListener('oriveo:custom-fragment-settings', listener);
    }

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')))
      .toEqual({ configurationMode: 'custom', raw: '{"enable_search":true}' });
    // Written only once: the target already having a record short-circuits, so re-entry is blocked; with the async broadcast the guard is forward porting's own idempotent short-circuit.
    expect(reentries).toBe(1);
  });

  it('does not port the default state of disabled with an empty draft', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '',
    });
    let events = 0;
    const listener = () => { events += 1; };
    window.addEventListener('oriveo:custom-fragment-settings', listener);
    try { port(current); } finally { window.removeEventListener('oriveo:custom-fragment-settings', listener); }

    expect(events).toBe(0);
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')))
      .toEqual({ configurationMode: 'auto', raw: '' });
  });

  it('never ports managed connections or invalid identities', () => {
    saveCustomFragmentSettings(customFragmentScope(relay, model, older, 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });

    forwardPortCustomFragmentsIfNeeded({ provider: relay, model, transportIdentity: 'transport-a' });

    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, current, 'web')).raw).toBe('');
    expect(loadCustomFragmentSettings(customFragmentScope(relay, model, 'transport-a', 'web')).raw).toBe('');
  });
});

/**
 * `mode == custom` means enabled, regardless of whether the schema is still alive.
 *
 * With fail-closed behavior this is the only self-consistent condition: when the server
 * withdraws the schema the configuration still takes over the request, and makes it fail, so
 * showing "unused" would be a lie.
 */
describe('custom enabled condition', () => {
  beforeEach(() => localStorage.clear());

  it('treats mode == custom as enabled even after the schema is withdrawn', () => {
    const withoutSchema = { ...model, capabilityControls: {} } as AIModel;
    saveCustomFragmentSettings(customFragmentScope(relay, model, 'transport-a', 'web'), {
      configurationMode: 'custom', raw: '{"enable_search":true}',
    });

    expect(customFragmentEntryState({ provider: relay, model, transportIdentity: 'transport-a' })).toBe('inUse');
    expect(customFragmentEntryState({ provider: relay, model: withoutSchema, transportIdentity: 'transport-a' }))
      .toBe('inUse');
  });

  it('does not require a non-empty draft for isActive: an empty draft takes over the request and fails closed', () => {
    const scope = customFragmentScope(relay, model, 'transport-a', 'web');
    saveCustomFragmentSettings(scope, { configurationMode: 'custom', raw: '' });

    const facts = customFragmentOwnerFacts({ provider: relay, model, transportIdentity: 'transport-a', owner: 'web' });
    expect(facts.isActive).toBe(true);
    // Same set as the outbound gate: this one really did enter the outbound fragments, and the compiler then fails closed.
    expect(resolveCustomFragments({ provider: relay, model, transportIdentity: 'transport-a', allow: true, runtime }))
      .toEqual({ web: { raw: '' } });
  });
});
