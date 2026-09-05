import type {
  ProviderErrorKind,
  ProviderErrorNextAction,
  ProviderErrorSeverity,
  ProviderErrorSource,
  StreamEvent,
} from '@oriveo/core';
import type { SkillKnowledgeErrorCode } from '@oriveo/shared/pure-types';
import type { IpcErrorCode, IpcQuotaSource } from './error-codes';

export interface IpcRequest<P = unknown> {
  requestId: string;
  payload: P;
}

export type IpcResponse<R = unknown> =
  | { ok: true; data: R }
  | { ok: false; error: IpcError };

export interface IpcError {
  code: IpcErrorCode;
  message: string;
  i18nKey?: string;
  errorKind?: ProviderErrorKind | 'ssrf' | 'mainCrash';
  knowledgeCode?: SkillKnowledgeErrorCode;
  detail?: string;
  retryable: boolean;
  nextAction?: ProviderErrorNextAction;
  source?: ProviderErrorSource;
  severity?: ProviderErrorSeverity;
  status?: number;
  upstreamURL?: string;
  quotaSource?: IpcQuotaSource;
}

export type IpcStreamEvent = StreamEvent;
