'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronLeft } from 'lucide-react';
import { Button, Dialog } from '@oriveo/ui';
import type { McpConfirmationChoice } from '@oriveo/core/mcp/index';
import { resolveMcpConfirmation, useMcpConfirmationStore } from '../../lib/core/mcp/mcp-confirmation';
import {
  mcpConfirmationFullText,
  mcpConfirmationHiddenCount,
  mcpConfirmationRows,
} from '../../lib/core/mcp/mcp-presentation';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { reportMcpConfirmChoice } from '../../lib/core/mcp/mcp-telemetry';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

/**
 * Confirmation before a write. Rendered by the global host `McpGlobalPrompts`: it appears on
 * whichever page the user is on, not only on the chat page that started this answer. Several tools
 * needing confirmation in the same leg appear one at a time, in proposal order (head of the queue).
 *
 * Closing the dialog (Esc / clicking the backdrop) = reject: nothing runs without an explicit allow.
 * **Default focus is on "Reject"**: the dialog is triggered by the model's action and may appear at
 * the very moment the user presses Enter, and Enter must not turn straight into an approval.
 */
export function McpConfirmationDialog() {
  const t = useTranslations('mcp.chat.confirm');
  const pending = useMcpConfirmationStore((state) => state.pending[0] ?? null);
  const iconServer = useMcpStore((state) => (pending ? state.servers.find((server) => server.id === pending.request.serverId) ?? null : null));
  const [showFull, setShowFull] = useState(false);

  const pendingId = pending?.id;
  useEffect(() => setShowFull(false), [pendingId]);

  if (!pending) return null;
  const { request } = pending;
  const rows = mcpConfirmationRows(request.arguments, request.inputSchema);
  const hiddenCount = mcpConfirmationHiddenCount(request.arguments);

  const choose = (choice: McpConfirmationChoice) => {
    reportMcpConfirmChoice(choice);
    resolveMcpConfirmation(pending.id, choice);
  };

  return (
    <Dialog
      open
      size="lg"
      onClose={() => choose('deny')}
      ariaLabelledBy="mcp-confirm-title"
      className={styles.dialog}
      initialFocusSelector="[data-mcp-confirm='deny']"
      lockBodyScroll
    >
      {showFull ? (
        <div data-mcp-confirm-view="full">
          <div className={styles.dialogHead}>
            <button type="button" className={styles.backButton} aria-label={t('back')} onClick={() => setShowFull(false)}>
              <ChevronLeft size={18} aria-hidden="true" />
            </button>
            <div className={styles.dialogHeadText}>
              <h2 id="mcp-confirm-title" className={styles.dialogTitle}>{t('fullTitle')}</h2>
              <p className={styles.dialogSubtitle}>{t('fullHint', { server: request.serverName })}</p>
            </div>
          </div>
          <div className={styles.fullText}>
            {mcpConfirmationFullText(request.arguments).map((entry) => (
              <div key={entry.key} className={styles.codeSection}>
                {/* Parameter names are the server's own text and are not translated. */}
                <div className={styles.codeSectionHead}><span>{entry.key}</span></div>
                <pre className={styles.codeBlock}>{entry.text}</pre>
              </div>
            ))}
          </div>
          <div className={styles.dialogActions}>
            <button type="button" className={styles.quietButton} data-mcp-confirm="deny" onClick={() => choose('deny')}>{t('decline')}</button>
            <Button data-mcp-primary data-mcp-confirm="once" onClick={() => choose('once')}>{t('allowOnce')}</Button>
          </div>
        </div>
      ) : (
        <div data-mcp-confirm-view="summary">
          <div className={styles.dialogHead}>
            <McpServerIcon name={request.serverName} iconURL={iconServer?.iconURL} serverURL={iconServer?.url} size={44} />
            <div className={styles.dialogHeadText}>
              <h2 id="mcp-confirm-title" className={styles.dialogTitle}>
                {t('title', { server: request.serverName, tool: request.toolTitle || request.toolName })}
              </h2>
              <p className={styles.dialogSubtitle}>
                {request.changesData ? t('subtitle', { server: request.serverName }) : t('subtitleReadOnly', { server: request.serverName })}
              </p>
            </div>
          </div>

          <dl className={styles.kvCard}>
            <div className={styles.kvRow}>
              <dt>{t('server')}</dt>
              <dd>
                <strong>{request.serverName}</strong>
                {request.serverHost ? <span className={styles.kvMuted}> · {request.serverHost}</span> : null}
              </dd>
            </div>
            {rows.map((row) => (
              <div key={row.key} className={styles.kvRow}>
                <dt>{row.key}</dt>
                <dd>
                  {row.value !== null ? (
                    <span className={styles.kvClamp}>{row.value}</span>
                  ) : (
                    <>
                      {t('aboutChars', { count: row.length })}
                      <span className={styles.kvMuted}> · </span>
                      <button type="button" className={styles.linkButton} onClick={() => setShowFull(true)}>{t('viewAll')}</button>
                    </>
                  )}
                </dd>
              </div>
            ))}
            {rows.length === 0 ? (
              <div className={styles.kvRow}><dd>{t('noArgs')}</dd></div>
            ) : null}
            {hiddenCount > 0 ? (
              <div className={styles.kvRow}>
                <dt aria-hidden="true" />
                <dd>
                  <button type="button" className={styles.linkButton} onClick={() => setShowFull(true)}>
                    {t('moreArgs', { count: hiddenCount })}
                  </button>
                </dd>
              </div>
            ) : null}
          </dl>

          <div className={styles.confirmActions}>
            <button type="button" className={styles.quietButton} data-mcp-confirm="deny" onClick={() => choose('deny')}>{t('decline')}</button>
            <Button tone="secondary" data-mcp-confirm="conversation" onClick={() => choose('conversation')}>{t('allowConversation')}</Button>
            <Button data-mcp-primary data-mcp-confirm="once" onClick={() => choose('once')}>{t('allowOnce')}</Button>
          </div>
        </div>
      )}
    </Dialog>
  );
}
