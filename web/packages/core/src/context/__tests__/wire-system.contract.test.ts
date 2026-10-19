import { describe, expect, it } from 'vitest';

import type { ContextBlock } from '../plan';
import { projectWire, WIRE_FAMILIES, type WireBody, type WireFamily, type WirePlan, type WireToolLeg } from '../wire-adapter';
import { ContextContractFixture } from './fixture';

interface FixturePlan {
  system: string | null;
  messages: Array<{ role: 'user' | 'assistant'; blocks: ContextBlock[] }>;
}

interface PlanCase {
  id: string;
  plan: FixturePlan;
  expected: Record<WireFamily, WireBody>;
}

interface TurnsCase {
  id: string;
  turns: FixturePlan[];
  expected: Record<WireFamily, WireBody[]>;
  assert: string;
}

interface LegsCase {
  id: string;
  legs: string;
  expected: { all: { systemEqualsFirstLeg: boolean; noSystemRoleMessagesAdded: boolean } } & Record<
    WireFamily,
    { noticePlacement: string }
  >;
}

interface LegBodiesCase {
  id: string;
  plan: FixturePlan;
  toolLeg: WireToolLeg;
  expected: Record<WireFamily, WireBody | { throws: true }>;
}

interface WireSystemContract {
  families: Record<WireFamily, string>;
  cases: Array<{ id: string } & Record<string, unknown>>;
}

const contract = ContextContractFixture.load<WireSystemContract>('wire-system.v1.json');
const caseById = (id: string) => contract.cases.find((c) => c.id === id) as unknown;

/** The family's system carrier, or undefined when absent. */
function systemOf(body: WireBody, family: WireFamily): unknown {
  switch (family) {
    case 'openai_responses':
      return body.instructions;
    case 'anthropic':
      return body.system;
    case 'gemini':
      return body.systemInstruction;
    default:
      return (body.messages as Array<{ role: string }>).find((m) => m.role === 'system');
  }
}

/** Conversation items without any system carrier. */
function itemsOf(body: WireBody, family: WireFamily): Array<Record<string, unknown>> {
  switch (family) {
    case 'openai_responses':
      return body.input as Array<Record<string, unknown>>;
    case 'gemini':
      return body.contents as Array<Record<string, unknown>>;
    case 'anthropic':
      return body.messages as Array<Record<string, unknown>>;
    default:
      return (body.messages as Array<Record<string, unknown>>).filter((m) => m.role !== 'system');
  }
}

function withoutCacheControl(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value, (key, v: unknown) => (key === 'cache_control' ? undefined : v)));
}

function systemRoleCount(body: WireBody): number {
  const list = (body.messages ?? body.input ?? body.contents) as Array<{ role?: string }>;
  return list.filter((m) => m.role === 'system').length;
}

describe('ContextContractWireSystem', () => {
  it('fixture lists exactly the adapter families and seven cases', () => {
    expect(Object.keys(contract.families).sort()).toStrictEqual([...WIRE_FAMILIES].sort());
    expect(contract.cases.map((c) => c.id)).toStrictEqual([
      'system_history_and_dynamic_block',
      'no_system_field_when_plan_has_none',
      'two_turn_prefix_is_stable',
      'checkpoint_merges_with_first_tail_user',
      'host_loop_notice_after_tool_results',
      'host_loop_leg_bodies',
      'host_loop_leg_bodies_with_dynamic',
    ]);
  });

  it.each(['system_history_and_dynamic_block', 'no_system_field_when_plan_has_none', 'checkpoint_merges_with_first_tail_user'])(
    'wire_%s',
    (id) => {
      const c = caseById(id) as PlanCase;
      for (const family of WIRE_FAMILIES) {
        expect(projectWire(c.plan, family), `${id}.${family}`).toStrictEqual(c.expected[family]);
      }
    },
  );

  it('wire_two_turn_prefix_is_stable', () => {
    const c = caseById('two_turn_prefix_is_stable') as TurnsCase;
    const [turn1, turn2] = c.turns as [FixturePlan, FixturePlan];
    const k = turn1.messages.map((m) => m.role).lastIndexOf('user');
    const turn1WithoutDynamic: WirePlan = {
      system: turn1.system,
      messages: turn1.messages.map((m, i) => (i === k ? { ...m, blocks: m.blocks.filter((b) => b.kind !== 'dynamic') } : m)),
    };
    for (const family of WIRE_FAMILIES) {
      const bodies = c.turns.map((t) => projectWire(t, family));
      expect(bodies, `${family}.expected`).toStrictEqual(c.expected[family]);
      const [one, two] = bodies as [WireBody, WireBody];
      expect(systemOf(two, family), `${family}.system`).toStrictEqual(systemOf(one, family));
      const items1 = withoutCacheControl(itemsOf(one, family)) as unknown[];
      const items2 = withoutCacheControl(itemsOf(two, family)) as unknown[];
      expect(items2.slice(0, k), `${family}.prefix`).toStrictEqual(items1.slice(0, k));
      const stripped = withoutCacheControl(itemsOf(projectWire(turn1WithoutDynamic, family), family)) as unknown[];
      expect(items2[k], `${family}.message k`).toStrictEqual(stripped[k]);
    }
  });

  it('wire_host_loop_notice_after_tool_results', () => {
    const c = caseById('host_loop_notice_after_tool_results') as LegsCase;
    const s = 'You are a meticulous editor.';
    const plan: WirePlan = { system: s, messages: [{ role: 'user', blocks: [{ kind: 'text', text: 'What is the weather in Oslo?' }] }] };
    const notice = 'Step limit reached. Answer in text now without calling tools.';
    const leg = {
      calls: [{ id: 'call_1', name: 'weather', arguments: '{"city":"Oslo"}' }],
      results: [{ callId: 'call_1', name: 'weather', output: '4°C, rain' }],
      notice,
    };
    const placement: Record<WireFamily, (body: WireBody) => void> = {
      openai_chat: chatPlacement,
      openai_chat_string_only: chatPlacement,
      managed: chatPlacement,
      llamacpp: chatPlacement,
      free: () => undefined,
      openai_responses: (body) => {
        const input = body.input as Array<Record<string, unknown>>;
        const last = input.map((i) => i.type).lastIndexOf('function_call_output');
        expect(last).toBe(input.length - 2);
        expect(input[last + 1]).toStrictEqual({ role: 'user', content: notice });
      },
      anthropic: (body) => {
        const messages = body.messages as Array<{ role: string; content: Array<Record<string, unknown>> }>;
        const turn = messages[messages.length - 1]!;
        expect(turn.role).toBe('user');
        expect(turn.content.map((b) => b.type)).toStrictEqual(['tool_result', 'text']);
        expect(turn.content[1]!.text).toBe(notice);
      },
      gemini: (body) => {
        const contents = body.contents as Array<{ role: string; parts: Array<Record<string, unknown>> }>;
        const turn = contents[contents.length - 1]!;
        expect(turn.role).toBe('user');
        expect(turn.parts[0]!.functionResponse).toBeDefined();
        expect(turn.parts[1]).toStrictEqual({ text: notice });
      },
    };
    function chatPlacement(body: WireBody): void {
      const messages = body.messages as Array<Record<string, unknown>>;
      const last = messages.map((m) => m.role).lastIndexOf('tool');
      expect(last).toBe(messages.length - 2);
      expect(messages[last + 1]).toStrictEqual({ role: 'user', content: notice });
    }

    expect(c.expected.all).toStrictEqual({ systemEqualsFirstLeg: true, noSystemRoleMessagesAdded: true });
    expect(c.expected.free.noticePlacement.startsWith('n/a')).toBe(true);
    for (const family of WIRE_FAMILIES) {
      const leg1 = projectWire(plan, family);
      if (family === 'free') {
        expect(() => projectWire(plan, family, leg)).toThrow();
        continue;
      }
      const leg2 = projectWire(plan, family, leg);
      expect(systemOf(leg2, family), `${family}.system`).toStrictEqual(systemOf(leg1, family));
      expect(systemRoleCount(leg2), `${family}.system roles`).toBe(systemRoleCount(leg1));
      placement[family](leg2);
    }
  });

  it.each(['host_loop_leg_bodies', 'host_loop_leg_bodies_with_dynamic'])('wire_%s', (id) => {
    const c = caseById(id) as LegBodiesCase | undefined;
    expect(c, `${id} case`).toBeDefined();
    for (const family of WIRE_FAMILIES) {
      const expected = c!.expected[family];
      if ('throws' in expected) {
        expect(() => projectWire(c!.plan, family, c!.toolLeg), `${id}.${family}`).toThrow();
        continue;
      }
      expect(projectWire(c!.plan, family, c!.toolLeg), `${id}.${family}`).toStrictEqual(expected);
    }
  });
});
