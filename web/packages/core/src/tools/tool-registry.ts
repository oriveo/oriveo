import type { ProxyToolDefinition } from '../providers/request-builders/runtime';
import type { ToolRegistryEntry } from './tool-loop-contracts';

/**
 * Tool registry: the single allowlist of the generic loop.
 *
 * An unregistered tool name always takes the "no executor" path (the loop's `onUnhandledToolCalls`),
 * never silently and never as a no-op. For duplicate names only the first registration is kept (first
 * come, first served); registration order is the order of the tools sent to the model.
 */
export class ToolRegistry {
  private readonly entries = new Map<string, ToolRegistryEntry>();
  private readonly orderedNames: string[] = [];

  constructor(entries: readonly ToolRegistryEntry[] = []) {
    for (const entry of entries) {
      if (this.entries.has(entry.name)) continue;
      this.entries.set(entry.name, entry);
      this.orderedNames.push(entry.name);
    }
  }

  static readonly empty = new ToolRegistry();

  entry(named: string): ToolRegistryEntry | undefined {
    return this.entries.get(named);
  }

  has(named: string): boolean {
    return this.entries.has(named);
  }

  get isEmpty(): boolean {
    return this.entries.size === 0;
  }

  get names(): readonly string[] {
    return this.orderedNames;
  }

  /** Tool definitions sent to the model (in registration order, skipping entries without a definition). */
  get definitions(): ProxyToolDefinition[] {
    return this.orderedNames.flatMap((name) => {
      const definition = this.entries.get(name)?.definition;
      return definition ? [definition] : [];
    });
  }
}
