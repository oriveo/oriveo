/**
 * Selection for automatic triggering of relay web probes.
 * Source of truth: `shared/test-fixtures/relay/web-probe.v1.json` triggers / triggerCases; the clock is always injected.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { RelayWebFragment, RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash } from '../relay-web-probe';
import {
  RELAY_WEB_PROBE_PER_CONNECTION_PER_WINDOW,
  RELAY_WEB_PROBE_PER_SAVE,
  RELAY_WEB_PROBE_WINDOW_MS,
  pruneRelayWebProbeAutoHistory,
  selectRelayWebProbes,
  type RelayWebProbeAutoHistoryEntry,
  type RelayWebProbeCandidate,
  type RelayWebProbeForm,
  type RelayWebProbeTriggerEvent,
} from '../relay-web-probe-trigger';

// __tests__ -> providers -> src -> core -> packages -> web -> <repo root>
const FIXTURE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../shared/test-fixtures/relay/web-probe.v1.json',
);

interface FixtureEvent {
  type: string;
  transport?: RelayWebTransport;
  fragment?: RelayWebFragment;
  modelId?: string;
  lazyVerify?: 'passed' | 'failed';
}
interface TriggerCase {
  caseId: string;
  now: string;
  form: RelayWebProbeForm;
  connectionId: string;
  event: FixtureEvent;
  enabledOnTransport?: string[];
  fragments?: Partial<Record<RelayWebTransport, RelayWebFragment>>;
  autoHistory: RelayWebProbeAutoHistoryEntry[];
  expect: { probe: string[]; untested: string[]; countsTowardCap?: boolean };
}
interface Fixture {
  triggers: { perSave: number; perConnectionPerWindow: number; windowSeconds: number };
  triggerCases: TriggerCase[];
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as Fixture;

function toEvent(event: FixtureEvent): RelayWebProbeTriggerEvent {
  switch (event.type) {
    case 'saveFragment': return { type: 'saveFragment' };
    case 'enableModel': return { type: 'enableModel', lazyVerify: event.lazyVerify ?? 'notRun' };
    case 'manualTest': return { type: 'manualTest' };
    case 'retest': return { type: 'retest' };
    case 'redetect': return { type: 'redetect' };
    case 'addConnection': return { type: 'addConnection' };
    default: throw new Error(`unknown trigger event in fixture: ${event.type}`);
  }
}

/** Candidates are the caller's responsibility (enable order + first-choice protocol has a snippet); an event without a model yields candidates for all snippets, and selection must reject by event on its own. */
function toCandidates(c: TriggerCase): RelayWebProbeCandidate[] {
  const { event } = c;
  if (event.type === 'saveFragment') {
    const fragmentHash = relayWebFragmentHash(event.fragment!);
    return (c.enabledOnTransport ?? []).map((modelId) => ({ modelId, transport: event.transport!, fragmentHash }));
  }
  const fragments = c.fragments ?? {};
  if (event.modelId) {
    const fragment = event.transport ? fragments[event.transport] : undefined;
    return fragment ? [{ modelId: event.modelId, transport: event.transport!, fragmentHash: relayWebFragmentHash(fragment) }] : [];
  }
  return (Object.entries(fragments) as Array<[RelayWebTransport, RelayWebFragment]>)
    .map(([transport, fragment]) => ({ modelId: 'm1', transport, fragmentHash: relayWebFragmentHash(fragment) }));
}

describe('relay web probe automatic trigger selection', () => {
  it('RL2-WEBPROBE-TRIG limits follow the fixture', () => {
    expect(RELAY_WEB_PROBE_PER_SAVE).toBe(fixture.triggers.perSave);
    expect(RELAY_WEB_PROBE_PER_CONNECTION_PER_WINDOW).toBe(fixture.triggers.perConnectionPerWindow);
    expect(RELAY_WEB_PROBE_WINDOW_MS).toBe(fixture.triggers.windowSeconds * 1000);
  });

  for (const c of fixture.triggerCases) {
    it(`RL2-WEBPROBE-TRIG-${c.caseId}`, () => {
      const selection = selectRelayWebProbes({
        form: c.form,
        event: toEvent(c.event),
        connectionId: c.connectionId,
        candidates: toCandidates(c),
        history: c.autoHistory,
        now: Date.parse(c.now),
      });
      expect(selection.probe.map((item) => item.modelId)).toEqual(c.expect.probe);
      expect(selection.untested.map((item) => item.modelId)).toEqual(c.expect.untested);
      if (c.expect.countsTowardCap !== undefined) expect(selection.countsTowardCap).toBe(c.expect.countsTowardCap);
    });
  }

  it('RL2-WEBPROBE-TRIG prune drops only stale entries of this connection whose fragment is no longer current', () => {
    const now = Date.parse('2026-10-13T12:00:00Z');
    const old = '2026-10-01T00:00:00Z';
    const recent = '2026-10-13T11:00:00Z';
    const history: RelayWebProbeAutoHistoryEntry[] = [
      { connectionId: 'conn-1', modelId: 'a', transport: 'anthropic_messages', fragmentHash: 'cur', sentAt: old },
      { connectionId: 'conn-1', modelId: 'b', transport: 'anthropic_messages', fragmentHash: 'stale', sentAt: old },
      { connectionId: 'conn-1', modelId: 'c', transport: 'anthropic_messages', fragmentHash: 'stale', sentAt: recent },
      { connectionId: 'conn-2', modelId: 'd', transport: 'anthropic_messages', fragmentHash: 'stale', sentAt: old },
    ];
    const kept = pruneRelayWebProbeAutoHistory(history, {
      connectionId: 'conn-1',
      now,
      currentHashes: { anthropic_messages: 'cur' },
    });
    expect(kept.map((item) => item.modelId)).toEqual(['a', 'c', 'd']);
  });
});
