import type {
  RelayAuthMode,
  RelayKeyValue,
  RelayReasoningEffort,
  RelayTransport,
  RelayWebSearchToolName,
} from '@oriveo/shared/pure-types';
import type { ChatRequestMessage } from './chat';

export interface RelayForwardOptions {
  reasoningEffort?: RelayReasoningEffort;
  serviceTier?: string;
  stream?: boolean;
  disableResponseStorage?: boolean;
  webSearchToolName?: RelayWebSearchToolName;
}

export interface RelayForwardRequest {
  baseURL: string;
  transport: Exclude<RelayTransport, 'auto'>;
  authMode: Exclude<RelayAuthMode, 'auto'>;
  apiKeyRef: string;
  modelID: string;
  messages: ChatRequestMessage[];
  headers?: RelayKeyValue[];
  queryParams?: RelayKeyValue[];
  options?: RelayForwardOptions;
}
