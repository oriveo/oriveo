'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog } from '@oriveo/ui';
import {
  enableMcpConfirmationUi,
  markMcpChatVisible,
  resolveMcpReauthorization,
  useMcpReauthorizationStore,
  useMcpVisibleChatStore,
} from '../../lib/core/mcp/mcp-confirmation';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { McpConfirmationDialog } from './McpConfirmationDialog';
import { McpReauthDialog } from './McpReauthDialog';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

/**
 * The global prompt host for MCP, mounted in the root layout. Only while it is present does the
 * confirmation gate hand requests to the UI; when it is absent (unmounted) everything is rejected
 * again. While an answer using MCP tools keeps running in the background, the user can go to
 * settings or to another conversation: the dialog follows the person and leaving the chat page is
 * not treated as a "reject".
 */
export function McpGlobalPrompts() {
  useEffect(() => enableMcpConfirmationUi(), []);
  return (
    <>
      <McpConfirmationDialog />
      <McpDetachedReauthPrompt />
    </>
  );
}

/**
 * The chat page uses it to register "this conversation is on screen": the step block carries its own
 * re-authorization buttons, so the global host does not need to prompt a second time.
 */
export function McpChatPresence({ conversationId }: { conversationId: string | undefined }) {
  useEffect(() => (conversationId ? markMcpChatVisible(conversationId) : undefined), [conversationId]);
  return null;
}

/**
 * The prompt for an "authorization expired" pause that occurs in a conversation not on screen: the
 * same pair of choices as the two buttons under the step block. Closing it does not decide for the
 * user; that step keeps waiting, and the choice can still be made on the step block after returning
 * to that conversation.
 */
function McpDetachedReauthPrompt() {
  const t = useTranslations('mcp.chat.steps');
  const pending = useMcpReauthorizationStore((state) => state.pending);
  const visible = useMcpVisibleChatStore((state) => state.visible);
  const [dismissed, setDismissed] = useState<readonly string[]>([]);
  const [signingIn, setSigningIn] = useState<string | null>(null);
  const current = pending.find((item) => !visible[item.request.conversationId] && !dismissed.includes(item.id)) ?? null;
  // The entry being signed in to again: while the sign-in dialog is open it is not withdrawn, even
  // if the user returns to that conversation in the meantime.
  const active = pending.find((item) => item.id === signingIn) ?? current;
  const server = useMcpStore((state) => (active ? state.servers.find((item) => item.id === active.request.serverId) ?? null : null));

  if (!active) return null;
  if (signingIn === active.id) {
    return (
      <McpReauthDialog
        server={server}
        trigger="mid_loop"
        onClose={() => setSigningIn(null)}
        onAuthorized={() => resolveMcpReauthorization(active.id, 'reauthorized')}
      />
    );
  }
  return (
    <Dialog
      open
      onClose={() => setDismissed((ids) => [...ids, active.id])}
      ariaLabelledBy="mcp-detached-reauth-title"
      className={styles.dialog}
      lockBodyScroll
    >
      <div className={styles.dialogHead} data-mcp-detached-reauth>
        <McpServerIcon name={active.request.serverName} iconURL={server?.iconURL ?? null} size={44} />
        <div className={styles.dialogHeadText}>
          {/* The server name is third-party text and is not translated. */}
          <h2 id="mcp-detached-reauth-title" className={styles.dialogTitle}>{t('stepAuthExpired', { server: active.request.serverName })}</h2>
          <p className={styles.dialogSubtitle}>{t('reauthHint')}</p>
        </div>
      </div>
      <div className={styles.dialogActions}>
        <button type="button" className={styles.quietButton} onClick={() => resolveMcpReauthorization(active.id, 'skip')}>
          {t('skip')}
        </button>
        {/* When the server is no longer on this device (removed in another tab) re-sign-in is impossible, so only "Skip" remains. */}
        {server ? (
          <Button data-mcp-primary onClick={() => setSigningIn(active.id)}>{t('reauthorize')}</Button>
        ) : null}
      </div>
    </Dialog>
  );
}
