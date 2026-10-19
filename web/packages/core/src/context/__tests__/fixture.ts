import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import type { Attachment, AttachmentKind, ChatMessageState } from '@oriveo/shared/pure-types';

import type { ContextMessage } from '../message';

/** Locates and parses shared context contract fixtures (shared/context-contracts). */
export const ContextContractFixture = {
  path(name: string): string {
    let current = process.cwd();
    while (true) {
      const candidate = path.join(current, 'shared', 'context-contracts', name);
      if (existsSync(candidate)) return candidate;
      const parent = path.dirname(current);
      if (parent === current) {
        throw new Error(`${name} not found`);
      }
      current = parent;
    }
  },

  load<T>(name: string): T {
    return JSON.parse(readFileSync(ContextContractFixture.path(name), 'utf8')) as T;
  },
};

/** Absolute tolerance for rho / rhoHi comparisons. */
export const RHO_TOLERANCE = 1e-12;

export interface FixtureMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  state: ChatMessageState;
  attachments?: Array<{ id: string; kind: AttachmentKind }>;
}

/** Builds the module's own attachment objects from fixture {id, kind}. */
export function toContextMessage(m: FixtureMessage): ContextMessage {
  const attachments: Attachment[] = (m.attachments ?? []).map((a) => ({
    id: a.id,
    kind: a.kind,
    fileName: a.id,
    mimeType: 'application/octet-stream',
  }));
  return { id: m.id, role: m.role, text: m.text, state: m.state, attachments };
}
