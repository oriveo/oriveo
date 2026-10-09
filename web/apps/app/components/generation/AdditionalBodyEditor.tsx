'use client';

import { useEffect, useMemo, useState } from 'react';
import { useTranslations } from 'next-intl';
import type { AIModel, Provider } from '@oriveo/shared';
import type { AdditionalBodyRejection } from '@oriveo/core/providers/request-builders/additional-body';
import {
  additionalBodyScope,
  resolveEffectiveAdditionalBody,
  saveAdditionalBody,
} from '../../lib/core/chat/additional-body-settings';
import {
  additionalBodyPreview,
  tidyAdditionalBody,
  type AdditionalBodyPreviewRow,
  type AdditionalBodyProtectedReason,
} from '../../lib/core/chat/additional-body-preview';
import { McpSwitch } from '../mcp/McpSwitch';
import styles from './AdditionalBodyEditor.module.css';

type Translate = (key: string, values?: Record<string, string | number>) => string;

/**
 * Additional request body editor.
 *
 * Scope: with a conversationId (the chat page; a new conversation uses the draft conversation id) it edits this conversation's copy -- shown on top of whatever is effective right now,
 * and the conversation layer is written only on the first change; without one (provider detail page) it edits the model default. The content and "send with request" are stored independently, and whatever is written is stored as is.
 */
export function AdditionalBodyEditor({ provider, model, conversationId }: {
  provider: Provider;
  model: AIModel;
  conversationId?: string;
}) {
  const tc = useTranslations('common') as Translate;
  const te = useTranslations('errors') as Translate;
  const scope = useMemo(
    () => additionalBodyScope(provider, model, conversationId),
    [conversationId, model, provider],
  );
  const [record, setRecord] = useState(() => readRecord(scope));
  const [tidyFailed, setTidyFailed] = useState(false);
  const [confirmingPaste, setConfirmingPaste] = useState(false);
  const [canPaste, setCanPaste] = useState(false);
  useEffect(() => {
    setRecord(readRecord(scope));
    setTidyFailed(false);
    setConfirmingPaste(false);
  }, [scope]);
  useEffect(() => {
    setCanPaste(typeof navigator !== 'undefined' && typeof navigator.clipboard?.readText === 'function');
  }, []);

  const preview = useMemo(() => additionalBodyPreview(record.raw), [record.raw]);

  const persist = (next: { raw: string; enabled: boolean }) => {
    setRecord(next);
    saveAdditionalBody(scope, next);
  };
  const setRaw = (raw: string) => {
    setTidyFailed(false);
    persist({ raw, enabled: record.enabled });
  };
  const paste = async () => {
    setConfirmingPaste(false);
    try {
      const text = await navigator.clipboard.readText();
      setRaw(text);
    } catch {
      // The browser refused to read the clipboard: change nothing
    }
  };
  const tidy = () => {
    const tidied = tidyAdditionalBody(record.raw);
    if (tidied === null) {
      setTidyFailed(true);
      return;
    }
    setRaw(tidied);
  };

  const lineCount = Math.max(record.raw.split('\n').length, 6);
  const errorLine = preview.rejection?.line;
  const errorText = preview.rejection ? rejectionText(preview.rejection, preview.rows, tc, te) : null;
  const engine = LOCAL_ENGINE_DOCS[provider.kind === 'relay' ? provider.relayRequested?.engineProfile ?? '' : ''];
  const inputID = `additional-body-${model.id}`;

  return (
    <div className={styles.editor} data-testid="additional-body-editor">
      <div className={styles.card}>
        <div className={styles.switchRow}>
          <div className={styles.switchText}>
            <span className={styles.title}>{tc('additionalBodySendToggle')}</span>
            <span className={styles.note}>{tc('additionalBodySendToggleNote')}</span>
          </div>
          <McpSwitch
            checked={record.enabled}
            label={tc('additionalBodySendToggle')}
            onChange={(enabled) => persist({ raw: record.raw, enabled })}
          />
        </div>
      </div>

      <div className={styles.code}>
        <div className={styles.codeScroll}>
          <div className={styles.gutter} aria-hidden="true">
            {Array.from({ length: lineCount }, (_, index) => (
              <span key={index} data-error-line={errorLine === index + 1 ? 'true' : undefined}>{index + 1}</span>
            ))}
          </div>
          <div className={styles.textWrap}>
            {errorLine && (
              <span className={styles.errorBand} aria-hidden="true" style={{ top: `calc(${errorLine - 1} * var(--ab-line))` }} />
            )}
            <textarea
              id={inputID}
              className={styles.textarea}
              dir="ltr"
              wrap="off"
              spellCheck={false}
              rows={lineCount}
              value={record.raw}
              aria-label={tc('additionalBodyTitle')}
              aria-invalid={Boolean(preview.rejection)}
              aria-describedby={errorText ? `${inputID}-error` : undefined}
              onChange={(event) => setRaw(event.target.value)}
            />
          </div>
        </div>
        <div className={styles.codeBar}>
          <span className={styles.deviceOnly}>{tc('additionalBodyDeviceOnly')}</span>
          {canPaste && (
            <button
              type="button"
              className={styles.barButton}
              onClick={() => (record.raw.trim() ? setConfirmingPaste(true) : void paste())}
            >{tc('additionalBodyPaste')}</button>
          )}
          <button type="button" className={styles.barButton} onClick={tidy}>{tc('additionalBodyTidy')}</button>
        </div>
      </div>

      {confirmingPaste && (
        <div className={styles.confirm} role="group" aria-label={tc('additionalBodyPasteReplaceTitle')}>
          <strong>{tc('additionalBodyPasteReplaceTitle')}</strong>
          <p className={styles.note}>{tc('additionalBodyPasteReplaceBody')}</p>
          <div className={styles.confirmActions}>
            <button type="button" className={styles.barButton} onClick={() => setConfirmingPaste(false)}>{tc('cancel')}</button>
            <button type="button" className={styles.barButton} data-testid="additional-body-paste-confirm" onClick={() => void paste()}>
              {tc('additionalBodyPaste')}
            </button>
          </div>
        </div>
      )}
      {errorText && <p id={`${inputID}-error`} className={styles.error} data-testid="additional-body-error">{errorText}</p>}
      {tidyFailed && <p className={styles.error} role="status">{tc('additionalBodyTidyInvalid')}</p>}

      {preview.rows.length > 0 && (
        <section className={styles.listSection}>
          <h4 className={styles.sectionTitle}>{tc('additionalBodyWhenSending')}</h4>
          <div className={styles.card}>
            {preview.rows.map((row) => (
              <div key={row.path} className={styles.listRow} data-additional-body-row={row.path} data-status={row.status}>
                <div className={styles.listText}>
                  <span className={styles.path} dir="ltr">{row.path}</span>
                  {row.status !== 'included' && <span className={styles.note}>{rowReason(row, tc)}</span>}
                </div>
                <span className={row.status === 'included' ? styles.included : styles.blocked}>
                  {tc(row.status === 'included' ? 'additionalBodyIncluded' : 'additionalBodyCannotChange')}
                </span>
              </div>
            ))}
          </div>
        </section>
      )}

      <p className={styles.note}>{tc('additionalBodyFooter')}</p>
      {engine && (
        <p className={styles.note}>
          <a href={engine.url} target="_blank" rel="noreferrer">{tc('additionalBodyDocsLink', { provider: engine.name })}</a>
        </p>
      )}
    </div>
  );
}

function readRecord(scope: ReturnType<typeof additionalBodyScope>): { raw: string; enabled: boolean } {
  const effective = resolveEffectiveAdditionalBody(scope);
  // With no copy at all the switch defaults to off; written content does not turn it on automatically, and afterwards the user's choice is stored.
  return effective ? { raw: effective.raw, enabled: effective.enabled } : { raw: '', enabled: false };
}

const PROTECTED_REASON_KEYS: Record<AdditionalBodyProtectedReason, string> = {
  conversation: 'additionalBodyConversationFilled',
  attachments: 'additionalBodyAttachmentsFilled',
  systemPrompt: 'additionalBodySystemPromptFilled',
  tools: 'additionalBodyToolsManaged',
  model: 'additionalBodyModelChosen',
  streaming: 'additionalBodyStreamingByOriveo',
  other: 'additionalBodyFieldFilled',
};

function rowReason(row: AdditionalBodyPreviewRow, tc: Translate): string {
  const reason = row.status === 'protected' ? tc(PROTECTED_REASON_KEYS[row.protectedReason]) : tc('additionalBodyFieldNameInvalid');
  return tc('additionalBodyRemoveLine', { reason, line: row.line });
}

function rejectionText(
  rejection: AdditionalBodyRejection,
  rows: readonly AdditionalBodyPreviewRow[],
  tc: Translate,
  te: Translate,
): string {
  if (rejection.reason === 'protected_field' || rejection.reason === 'blocked_segment') {
    const culprit = rows.find((row) => row.line === rejection.line && row.status !== 'included');
    if (culprit) return rowReason(culprit, tc);
  }
  const reason = te(`additionalBodyRejected.${REJECTION_REASON_KEYS[rejection.reason]}`, rejection.field ? { field: rejection.field } : undefined);
  return rejection.reason === 'invalid_json' && rejection.line
    ? te('additionalBodyRejected.line', { line: rejection.line, reason })
    : reason;
}

const REJECTION_REASON_KEYS: Record<AdditionalBodyRejection['reason'], string> = {
  invalid_json: 'reasonInvalidJson',
  not_object: 'reasonNotObject',
  protected_field: 'reasonProtectedField',
  blocked_segment: 'reasonBlockedSegment',
  too_large: 'reasonTooLarge',
  too_deep: 'reasonTooDeep',
};

/** Request parameter docs of local engines (proper nouns are not translated). Other connections have no unified field list, so no link is given. */
const LOCAL_ENGINE_DOCS: Readonly<Record<string, { name: string; url: string } | undefined>> = {
  llamacpp: { name: 'llama.cpp', url: 'https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md' },
  ollama: { name: 'Ollama', url: 'https://github.com/ollama/ollama/blob/main/docs/api.md' },
  lmstudio: { name: 'LM Studio', url: 'https://lmstudio.ai/docs/developer/openai-compat' },
  vllm: { name: 'vLLM', url: 'https://docs.vllm.ai/en/latest/serving/openai_compatible_server/' },
};
