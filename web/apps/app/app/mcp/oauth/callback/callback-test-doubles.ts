import type { OauthCallbackChannel, OauthCallbackMessageTarget } from './callback-handoff';

/**
 * Test double: the delivery semantics between BroadcastChannels of the same name (jsdom does not
 * implement it). Three points match the browser: no delivery to the sender itself; delivery is
 * asynchronous; a channel already closed at delivery time receives nothing.
 */
export class FakeChannelHub {
  readonly channels = new Set<FakeChannel>();

  open = (): FakeChannel => {
    const channel = new FakeChannel(this);
    this.channels.add(channel);
    return channel;
  };
}

export class FakeChannel implements OauthCallbackChannel {
  readonly posted: unknown[] = [];
  closed = false;
  private readonly listeners = new Set<(event: MessageEvent) => void>();

  constructor(private readonly hub: FakeChannelHub) {}

  postMessage(message: unknown): void {
    if (this.closed) throw new Error('InvalidStateError: channel is closed');
    this.posted.push(message);
    for (const other of this.hub.channels) {
      if (other === this) continue;
      queueMicrotask(() => {
        if (other.closed) return;
        for (const listener of [...other.listeners]) listener({ data: message } as MessageEvent);
      });
    }
  }

  addEventListener(_type: 'message', listener: (event: MessageEvent) => void): void {
    this.listeners.add(listener);
  }

  removeEventListener(_type: 'message', listener: (event: MessageEvent) => void): void {
    this.listeners.delete(listener);
  }

  close(): void {
    this.closed = true;
    this.hub.channels.delete(this);
  }

  get listenerCount(): number {
    return this.listeners.size;
  }
}

/** A fake window that only receives `message` events, with a `postMessage` that delivers to it asynchronously. */
export class FakeWindow implements OauthCallbackMessageTarget {
  closed = false;
  readonly received: Array<{ data: unknown; targetOrigin: string }> = [];
  private readonly listeners = new Set<(event: MessageEvent) => void>();

  constructor(readonly origin: string) {}

  addEventListener(_type: 'message', listener: (event: MessageEvent) => void): void {
    this.listeners.add(listener);
  }

  removeEventListener(_type: 'message', listener: (event: MessageEvent) => void): void {
    this.listeners.delete(listener);
  }

  get listenerCount(): number {
    return this.listeners.size;
  }

  /** Builds "me as another window sees me": a postMessage to it fires a message event here. */
  asSeenBy(sender: FakeWindow): Window {
    const self = this;
    return {
      get closed() {
        return self.closed;
      },
      postMessage(data: unknown, targetOrigin: string) {
        self.received.push({ data, targetOrigin });
        // Same as the browser: a message whose targetOrigin does not match the receiver's origin is dropped.
        if (targetOrigin !== self.origin) return;
        queueMicrotask(() => {
          const event = { data, origin: sender.origin, source: sender.asSeenBy(self) } as unknown as MessageEvent;
          for (const listener of [...self.listeners]) listener(event);
        });
      },
    } as unknown as Window;
  }
}
