/**
 * BYOK round scheduler: drives submit / finish / cancel / response through
 * byokQueueReduce, runs at most maxConcurrentRounds rounds per device, and
 * drops late responses of cancelled rounds.
 */
import {
  BYOK_EMPTY_QUEUE,
  byokQueueReduce,
  type ByokQueueEffect,
  type ByokQueueEvent,
  type ByokQueueState,
} from './byok-tasks';

export type StudioByokQueueUpdate<R> =
  | { type: 'queued' }
  | { type: 'started' }
  | { type: 'result'; result: R }
  | { type: 'failed'; error: unknown }
  | { type: 'cancelled'; mayBeBilled: boolean };

export interface StudioByokQueueOptions<R> {
  /** Expected not to throw (errors belong in R); a throw is reported as `failed` and frees the slot. */
  run: (id: string, signal: AbortSignal) => Promise<R>;
  onUpdate: (id: string, update: StudioByokQueueUpdate<R>) => void;
}

export interface StudioByokQueue {
  submit(id: string): void;
  cancel(id: string): void;
  snapshot(): { running: string[]; queued: string[] };
}

export function createStudioByokQueue<R>(options: StudioByokQueueOptions<R>): StudioByokQueue {
  const { run, onUpdate } = options;
  let state: ByokQueueState = BYOK_EMPTY_QUEUE;
  const controllers = new Map<string, AbortController>();

  function reduce(event: ByokQueueEvent): ByokQueueEffect[] {
    const next = byokQueueReduce(state, event);
    state = next.state;
    return next.effects;
  }

  function settle(
    id: string,
    controller: AbortController,
    outcome: { ok: true; value: R } | { ok: false; error: unknown },
  ): void {
    // A controller that is no longer current belongs to a round that was cancelled
    // (and maybe resubmitted under the same id); it must not touch the newer round.
    const current = controllers.get(id) === controller;
    const accepted = reduce({ type: 'response', id }).some((effect) => effect.type === 'accept');
    if (!current) return;
    controllers.delete(id);
    if (accepted) {
      onUpdate(id, outcome.ok ? { type: 'result', result: outcome.value } : { type: 'failed', error: outcome.error });
    }
    apply(reduce({ type: 'finish', id }));
  }

  function start(id: string): void {
    const controller = new AbortController();
    controllers.set(id, controller);
    onUpdate(id, { type: 'started' });
    let pending: Promise<R>;
    try {
      pending = run(id, controller.signal);
    } catch (error) {
      pending = Promise.reject(error);
    }
    pending.then(
      (value) => settle(id, controller, { ok: true, value }),
      (error: unknown) => settle(id, controller, { ok: false, error }),
    );
  }

  function apply(effects: readonly ByokQueueEffect[]): void {
    for (const effect of effects) {
      switch (effect.type) {
        case 'start':
          start(effect.id);
          break;
        case 'cancelled': {
          const controller = controllers.get(effect.id);
          controllers.delete(effect.id);
          controller?.abort();
          onUpdate(effect.id, { type: 'cancelled', mayBeBilled: effect.mayBeBilled });
          break;
        }
        case 'accept':
        case 'drop':
          break;
      }
    }
  }

  return {
    submit(id) {
      const effects = reduce({ type: 'submit', id });
      if (state.queued.includes(id)) onUpdate(id, { type: 'queued' });
      apply(effects);
    },
    cancel(id) {
      apply(reduce({ type: 'cancel', id }));
    },
    snapshot() {
      return { running: [...state.running], queued: [...state.queued] };
    },
  };
}
