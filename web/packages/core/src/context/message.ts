/** Context pipeline message model, independent of the app's ChatMessage. */

import type { Attachment, ChatMessageState } from '@oriveo/shared/pure-types';

export type ContextRole = 'user' | 'assistant';

export interface ContextMessage {
  id: string;
  role: ContextRole;
  text: string;
  state: ChatMessageState;
  attachments: Attachment[];
}
