/**
 * Assembler micro-benchmark (three-platform contract: same dataset, same case names).
 * Web gate: first two cases p95 <= 4 ms; send path (k=3 assembles + one OpenAI Chat projection) p95 <= 15 ms.
 */

import { describe, expect, it } from 'vitest';

import { ContextAssembler, type AssembleInput } from '../assemble';
import { ContextBudget } from '../budget';
import { projectWire } from '../wire-adapter';
import { toContextMessage, type FixtureMessage } from './fixture';

const S0 = '\u4e0a\u4e0b\u6587\u7ba1\u7ebf\u5728\u53d1\u9001\u524d\u7ec4\u88c5\u5386\u53f2\u6d88\u606f，\u5e76\u6309\u9884\u7b97\u88c1\u526a\u6700\u65e9\u7684\u8f6e\u6b21。';
const S1 = 'The assembler trims the oldest turns first and keeps the current user message intact.';
const S2 = 'يقوم المجمّع بقص أقدم الأدوار أولاً ويحافظ على رسالة المستخدم الحالية.';
const S3 = '```swift\nfunc add(_ a: Int, _ b: Int) -> Int { a + b }\n```';
const SEGMENTS = [S0, S1, S2, S3];

const RHO = 0.5;
const HISTORY_COUNT = 500;
const MIN_MESSAGE_TOKENS = 200;
const WARMUP = 30;
const ITERATIONS = 200;
/** Web assembles three times per send: preflight + runChatOutbound dry run + actual send. */
const SEND_PATH_ASSEMBLES = 3;

function bodyFor(index: number): string {
  const segment = SEGMENTS[index % 4];
  let text = segment;
  while (ContextBudget.estimateMessage(text, RHO) < MIN_MESSAGE_TOKENS) {
    text = `${text}\n${segment}`;
  }
  return text;
}

const history: FixtureMessage[] = Array.from({ length: HISTORY_COUNT }, (_, i) => ({
  id: `m${String(i).padStart(3, '0')}`,
  role: i % 2 === 0 ? 'user' : 'assistant',
  text: bodyFor(i),
  state: 'delivered',
}));

function inputFor(W: number): AssembleInput {
  return {
    purpose: 'chat',
    window: { W, windowKind: 'total', maxOutput: { model: 8192 } },
    rhoHi: RHO,
    conversation: { id: 'bench', useMemory: false, skillPrompt: Array.from({ length: 6 }, () => S1).join(' ') },
    history: history.map(toContextMessage),
    current: 'Summarize the discussion above.',
    currentId: 'm500',
  };
}

interface Stats {
  p50: number;
  p95: number;
  n: number;
}

/** Nearest-rank percentile: sorted[ceil(q*n)-1]. */
function percentile(sorted: number[], q: number): number {
  return sorted[Math.ceil(q * sorted.length) - 1];
}

function summarize(samples: number[]): Stats & { max: number } {
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    max: sorted[sorted.length - 1],
    n: sorted.length,
  };
}

function measure(name: string, body: () => void): Stats {
  for (let i = 0; i < WARMUP; i += 1) body();
  const samples: number[] = [];
  for (let i = 0; i < ITERATIONS; i += 1) {
    const started = performance.now();
    body();
    samples.push(performance.now() - started);
  }
  const stats = summarize(samples);
  console.info(
    `ContextAssemblerBenchmark ${name} p50=${stats.p50.toFixed(2)} p95=${stats.p95.toFixed(2)} n=${stats.n}`,
  );
  return stats;
}

describe('ContextAssemblerBenchmark', () => {
  it('dataset totals 100k-120k estimated tokens', () => {
    const total = history.reduce((sum, m) => sum + ContextBudget.estimateMessage(m.text, RHO), 0);
    expect(total).toBeGreaterThanOrEqual(100_000);
    expect(total).toBeLessThanOrEqual(120_000);
  });

  it('assemble_500_messages_100k_tokens_p95', () => {
    const input = inputFor(200_000);
    const plan = ContextAssembler.assemble(input);
    expect(plan.messages?.length).toBe(HISTORY_COUNT + 1);
    const stats = measure('assemble_500_messages_100k_tokens_p95', () => {
      ContextAssembler.assemble(input);
    });
    expect(stats.p95).toBeLessThanOrEqual(4);
  });

  it('assemble_trimmed_window_p95', () => {
    const input = inputFor(64_000);
    const plan = ContextAssembler.assemble(input);
    // The web assembler never deletes messages, it only gives a compaction suggestion; exceeding the window means required.
    expect(plan.compaction).toBe('required');
    const stats = measure('assemble_trimmed_window_p95', () => {
      ContextAssembler.assemble(input);
    });
    expect(stats.p95).toBeLessThanOrEqual(4);
  });

  it('send_path_extra_latency_p95', () => {
    const input = inputFor(200_000);
    const body = projectWire(ContextAssembler.assemble(input), 'openai_chat');
    expect(body).toBeTruthy();
    // Long-tail localization: time k assemblies and one wire projection in segments, kept as an extra printed line.
    const assembleSamples: number[] = [];
    const projectSamples: number[] = [];
    const runOnce = (record: boolean) => {
      const t0 = performance.now();
      let plan = ContextAssembler.assemble(input);
      for (let i = 1; i < SEND_PATH_ASSEMBLES; i += 1) plan = ContextAssembler.assemble(input);
      const t1 = performance.now();
      projectWire(plan, 'openai_chat');
      const t2 = performance.now();
      if (record) {
        assembleSamples.push(t1 - t0);
        projectSamples.push(t2 - t1);
      }
    };
    let warmed = 0;
    const stats = measure('send_path_extra_latency_p95', () => {
      runOnce(warmed >= WARMUP);
      warmed += 1;
    });
    for (const [label, samples] of [
      ['assemble_x3', assembleSamples],
      ['project_wire', projectSamples],
    ] as const) {
      const s = summarize(samples);
      console.info(
        `ContextAssemblerBenchmark send_path.${label} p50=${s.p50.toFixed(2)} p95=${s.p95.toFixed(2)} max=${s.max.toFixed(2)} n=${s.n}`,
      );
    }
    expect(stats.p95).toBeLessThanOrEqual(15);
  });
});
