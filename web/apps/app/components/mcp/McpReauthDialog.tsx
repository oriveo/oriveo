'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Lock, LoaderCircle } from 'lucide-react';
import { Button, Dialog } from '@oriveo/ui';
import type { McpServerRecord } from '@oriveo/core/mcp/index';
import { createPreopenedMcpAuthorization, type McpPreopenedAuthorization } from '../../lib/core/mcp/browser-mcp-runtime';
import {
  completeMcpReauthorization,
  prepareMcpReauthorization,
  submitMcpAccessToken,
  type McpReauthPreparation,
} from '../../lib/core/mcp/mcp-server-actions';
import { reportMcpAuthResult, type McpAuthTrigger } from '../../lib/core/mcp/mcp-telemetry';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

type Phase =
  | { kind: 'checking' }
  | { kind: 'prompt'; preparation: Extract<McpReauthPreparation, { kind: 'ready' }> }
  | { kind: 'browser' }
  | { kind: 'token'; rejected: boolean; busy: boolean }
  | { kind: 'failed' }
  | { kind: 'unreachable' };

/**
 * Re-authorization: read the metadata only at first and show the pre-sign-in notice (which must
 * display the hostname of the sign-in page); the window opens only after the user presses continue.
 * A server that uses an access token shows the token input instead.
 */
export function McpReauthDialog({
  server,
  trigger,
  onClose,
  onAuthorized,
  preopened,
}: {
  server: McpServerRecord | null;
  /** Analytics field `mcp_auth_result.trigger`: `reauth` when entered from the management page / tools panel, `mid_loop` from a step block. */
  trigger: McpAuthTrigger;
  onClose: () => void;
  onAuthorized?: (serverId: string) => void;
  /** Injected by tests. */
  preopened?: McpPreopenedAuthorization;
}) {
  const t = useTranslations('mcp');
  const [phase, setPhase] = useState<Phase>({ kind: 'checking' });
  const [token, setToken] = useState('');
  const [popupBlocked, setPopupBlocked] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const windowRef = useRef<McpPreopenedAuthorization | null>(null);
  const serverId = server?.id ?? null;

  const finish = useCallback((id: string) => {
    onAuthorized?.(id);
    onClose();
  }, [onAuthorized, onClose]);

  const prepare = useCallback(async (id: string) => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setPhase({ kind: 'checking' });
    setPopupBlocked(false);
    const preparation = await prepareMcpReauthorization(id, { signal: controller.signal });
    if (controller.signal.aborted) return;
    switch (preparation.kind) {
      case 'ready':
        setPhase({ kind: 'prompt', preparation });
        break;
      case 'needsToken':
        setPhase({ kind: 'token', rejected: false, busy: false });
        break;
      case 'connected':
        finish(id);
        break;
      case 'unreachable':
        setPhase({ kind: 'unreachable' });
        break;
      case 'gone':
        onClose();
        break;
    }
  }, [finish, onClose]);

  useEffect(() => {
    if (!serverId) return;
    setToken('');
    void prepare(serverId);
    return () => {
      abortRef.current?.abort();
      windowRef.current?.discard();
    };
  }, [prepare, serverId]);

  if (!server) return null;

  const continueSignIn = (preparation: Extract<McpReauthPreparation, { kind: 'ready' }>) => {
    // The window must be opened synchronously within this click: registering the client needs the
    // network afterwards, and opening only once the authorization address is known would be blocked.
    const authorization = preopened ?? createPreopenedMcpAuthorization();
    windowRef.current = authorization;
    if (!authorization.preopen()) {
      // Stopped by a popup blocker: stay on the pre-sign-in notice and explain why; no client is
      // registered yet, so the user can allow popups and press again.
      setPopupBlocked(true);
      return;
    }
    setPopupBlocked(false);
    const controller = new AbortController();
    abortRef.current = controller;
    setPhase({ kind: 'browser' });
    void completeMcpReauthorization(server.id, preparation.plan, authorization.launcher, { signal: controller.signal }).then((outcome) => {
      authorization.discard();
      reportMcpAuthResult({ outcome, registration: preparation.plan.registrationKind, trigger });
      if (controller.signal.aborted) return;
      if (outcome === 'connected') finish(server.id);
      else if (outcome === 'gone') onClose();
      else setPhase({ kind: outcome === 'unreachable' ? 'unreachable' : 'failed' });
    });
  };

  const submitToken = async () => {
    setPhase({ kind: 'token', rejected: false, busy: true });
    const outcome = await submitMcpAccessToken(server.id, token);
    reportMcpAuthResult({ outcome: outcome === 'rejected' ? 'failed' : outcome, registration: 'none', trigger });
    if (outcome === 'connected') finish(server.id);
    else if (outcome === 'gone') onClose();
    else if (outcome === 'rejected') setPhase({ kind: 'token', rejected: true, busy: false });
    else setPhase({ kind: 'unreachable' });
  };

  const cancel = () => {
    abortRef.current?.abort();
    windowRef.current?.discard();
    onClose();
  };

  return (
    <Dialog open onClose={cancel} ariaLabelledBy="mcp-reauth-title" className={styles.dialog} lockBodyScroll>
      <div className={styles.dialogHead}>
        <McpServerIcon name={server.name} iconURL={server.iconURL} size={44} />
        <div className={styles.dialogHeadText}>
          <h2 id="mcp-reauth-title" className={styles.dialogTitle}>
            {phase.kind === 'token'
              ? t('reauth.tokenTitle')
              : phase.kind === 'failed'
                ? t('reauth.failedTitle')
                : phase.kind === 'unreachable'
                  ? t('reauth.unreachableTitle')
                  : phase.kind === 'browser'
                    ? t('addServer.browserTitle')
                    : t('addServer.promptTitle', { name: server.name })}
          </h2>
          <p className={styles.dialogSubtitle}>
            {phase.kind === 'checking' && t('reauth.checking')}
            {phase.kind === 'prompt' && t('addServer.promptBody', { name: server.name })}
            {phase.kind === 'browser' && t('addServer.browserBody')}
            {phase.kind === 'token' && t('reauth.tokenBody')}
            {phase.kind === 'failed' && t('reauth.failedBody')}
            {phase.kind === 'unreachable' && t('reauth.unreachableBody')}
          </p>
        </div>
      </div>

      {phase.kind === 'checking' || phase.kind === 'browser' ? (
        <div className={styles.busyRow} role="status">
          <LoaderCircle size={18} className={styles.spinner} aria-hidden="true" />
        </div>
      ) : null}

      {phase.kind === 'prompt' ? (
        <>
          <dl className={styles.kvCard}>
            <div className={styles.kvRow}>
              <dt>{t('addServer.promptSignInPage')}</dt>
              <dd data-testid="mcp-auth-host">
                <Lock size={13} className={styles.lockIcon} aria-hidden="true" />
                {phase.preparation.authorizationHost}
              </dd>
            </div>
            <div className={styles.kvRow}>
              <dt>{t('addServer.promptConnectsTo')}</dt>
              <dd>{phase.preparation.serverHost}</dd>
            </div>
          </dl>
          <p className={styles.footnote}>{t('addServer.promptHint')}</p>
          {popupBlocked ? (
            <p className={styles.fieldError} role="alert" data-mcp-state="popup-blocked">{t('addServer.popupBlocked')}</p>
          ) : null}
        </>
      ) : null}

      {phase.kind === 'token' ? (
        <label className={styles.field}>
          <span className={styles.fieldLabel}>{t('addServer.token')}</span>
          <input
            className={styles.input}
            data-invalid={phase.rejected || undefined}
            type="password"
            autoComplete="off"
            spellCheck={false}
            placeholder={t('addServer.tokenPlaceholder')}
            value={token}
            onChange={(event) => setToken(event.target.value)}
          />
          <span className={phase.rejected ? styles.fieldError : styles.fieldHint} role={phase.rejected ? 'alert' : undefined}>
            {phase.rejected ? t('addServer.tokenRejected') : t('addServer.tokenNote')}
          </span>
        </label>
      ) : null}

      <div className={styles.dialogActions}>
        <button type="button" className={styles.quietButton} onClick={cancel}>
          {t('addServer.cancel')}
        </button>
        {phase.kind === 'prompt' ? (
          <Button data-mcp-primary onClick={() => continueSignIn(phase.preparation)}>{t('addServer.continue')}</Button>
        ) : null}
        {phase.kind === 'token' ? (
          <Button data-mcp-primary disabled={!token.trim() || phase.busy} onClick={() => void submitToken()}>{t('reauth.save')}</Button>
        ) : null}
        {phase.kind === 'failed' || phase.kind === 'unreachable' ? (
          <Button data-mcp-primary onClick={() => void prepare(server.id)}>{t('addServer.retry')}</Button>
        ) : null}
      </div>
    </Dialog>
  );
}
