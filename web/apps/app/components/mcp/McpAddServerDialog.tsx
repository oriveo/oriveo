'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Check, LoaderCircle, Lock } from 'lucide-react';
import { Button, Dialog } from '@oriveo/ui';
import {
  checkMcpEndpoint,
  type McpAddState,
  type McpAuthKind,
  type McpAuthPrompt,
  type McpToolPermission,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import { createPreopenedMcpAuthorization, type McpPreopenedAuthorization } from '../../lib/core/mcp/browser-mcp-runtime';
import { mcpInvalidUrlMessageKey } from '../../lib/core/mcp/mcp-add-copy';
import { mcpHostname } from '../../lib/core/mcp/mcp-presentation';
import { acceptMcpAddedTools } from '../../lib/core/mcp/mcp-server-actions';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { reportMcpAuthResult, reportMcpServerAddResult } from '../../lib/core/mcp/mcp-telemetry';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

type View =
  | { kind: 'form' }
  | { kind: 'progress'; state: Extract<McpAddState, { kind: 'connecting' | 'authPrompt' | 'browser' | 'finishing' }> }
  | { kind: 'result'; state: McpAddState };

interface AuthGate {
  prompt: McpAuthPrompt;
  resolve: (approved: boolean) => void;
}

const PERMISSIONS: McpToolPermission[] = ['auto', 'ask', 'off'];
const PERMISSION_KEYS: Record<McpToolPermission, 'permission.auto' | 'permission.ask' | 'permission.off'> = {
  auto: 'permission.auto',
  ask: 'permission.ask',
  off: 'permission.off',
};

/**
 * Adding a server. One dialog covers the whole flow: enter the address → connecting → (pre-sign-in
 * notice → sign in in a new window) → confirm default permissions; every failure stays in the same
 * dialog and offers a next step.
 *
 * - The pre-sign-in notice is a gate: until the user presses "Continue" no client is registered and
 *   no window is opened; the window is opened synchronously within that click.
 * - On the confirm-permissions step, only pressing "Done" accepts this set of tools; closing the
 *   dialog without it means abandoning the add, and the record that was just stored is removed
 *   (going back from "confirm permissions" is the same as abandoning the add).
 * - The dialog being unmounted or closed from outside (page change, parent collapsing) performs the
 *   same cleanup as the user pressing "Cancel": an add in progress is cancelled, and a record parked
 *   at confirm-permissions is removed. When even the cleanup cannot run (tab closed, refresh), the
 *   store clears the half-finished record on its next hydration.
 * - The form has only an address and a name. The sign-in method is decided by probing: a server that
 *   needs an access token shows the token input on the "access token required" step.
 */
export function McpAddServerDialog({
  open,
  onClose,
  onAdded,
  preopened,
}: {
  open: boolean;
  onClose: () => void;
  onAdded?: (serverId: string) => void;
  /** Injected by tests. */
  preopened?: McpPreopenedAuthorization;
}) {
  const t = useTranslations('mcp');
  const addServer = useMcpStore((state) => state.addServer);
  const removeServer = useMcpStore((state) => state.removeServer);

  const [url, setUrl] = useState('');
  const [name, setName] = useState('');
  const [authKind, setAuthKind] = useState<McpAuthKind>('auto');
  const [token, setToken] = useState('');
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [tokenError, setTokenError] = useState(false);
  const [popupBlocked, setPopupBlocked] = useState(false);
  const [view, setView] = useState<View>({ kind: 'form' });
  const [gate, setGate] = useState<AuthGate | null>(null);
  const [signedIn, setSignedIn] = useState(false);
  const [groupPermissions, setGroupPermissions] = useState<{ readOnly: McpToolPermission; changes: McpToolPermission }>({ readOnly: 'auto', changes: 'ask' });
  const [finishing, setFinishing] = useState(false);

  const abortRef = useRef<AbortController | null>(null);
  const windowRef = useRef<McpPreopenedAuthorization | null>(null);
  const gateRef = useRef<AuthGate | null>(null);
  const runRef = useRef(0);
  /** The server that has been stored but not yet confirmed with "Done". */
  const reviewRef = useRef<string | null>(null);

  const reset = useCallback(() => {
    runRef.current += 1;
    setUrl('');
    setName('');
    setAuthKind('auto');
    setToken('');
    setFieldError(null);
    setTokenError(false);
    setPopupBlocked(false);
    setView({ kind: 'form' });
    setGate(null);
    gateRef.current = null;
    setSignedIn(false);
    setGroupPermissions({ readOnly: 'auto', changes: 'ask' });
    setFinishing(false);
  }, []);

  /** Abandons the current add: in progress = cancel; stored but unconfirmed = remove. Safe to call repeatedly. */
  const teardown = useCallback(() => {
    runRef.current += 1;
    abortRef.current?.abort();
    abortRef.current = null;
    gateRef.current?.resolve(false);
    gateRef.current = null;
    windowRef.current?.discard();
    windowRef.current = null;
    const pendingReview = reviewRef.current;
    reviewRef.current = null;
    if (pendingReview) void removeServer(pendingReview).catch(() => {});
  }, [removeServer]);

  useEffect(() => {
    if (!open) return;
    reset();
    // When the dialog is collapsed or unmounted (not necessarily via the "Cancel" button), do the
    // same cleanup as a cancel.
    return teardown;
  }, [open, reset, teardown]);

  const run = useCallback(async (input: { authKind: McpAuthKind; token: string }) => {
    const checked = checkMcpEndpoint(url);
    if (!checked.ok) {
      // Stay on the form and show the error under the field. No request is sent.
      setFieldError(t(mcpInvalidUrlMessageKey(checked.reason)));
      setView({ kind: 'form' });
      reportMcpServerAddResult({ kind: 'invalidURL', reason: checked.reason }, input.authKind);
      return;
    }
    const runId = ++runRef.current;
    const controller = new AbortController();
    abortRef.current = controller;
    const authorization = preopened ?? createPreopenedMcpAuthorization();
    windowRef.current = authorization;
    setFieldError(null);
    setTokenError(false);
    setPopupBlocked(false);
    setSignedIn(false);
    setView({ kind: 'progress', state: { kind: 'connecting' } });
    let usedBrowser = false;
    let registration: 'cimd' | 'dcr' | 'none' = 'none';

    const state = await addServer({
      url,
      name,
      authKind: input.authKind,
      token: input.authKind === 'token' ? input.token.trim() : null,
      signal: controller.signal,
      launcher: authorization.launcher,
      confirmAuthorization: (prompt) =>
        new Promise<boolean>((resolve) => {
          registration = prompt.registrationKind;
          const next: AuthGate = { prompt, resolve };
          gateRef.current = next;
          setGate(next);
        }),
      progress: (progress) => {
        if (runRef.current !== runId) return;
        if (progress.kind === 'browser') usedBrowser = true;
        if (progress.kind === 'finishing' && usedBrowser) setSignedIn(true);
        if (progress.kind === 'connecting' || progress.kind === 'authPrompt' || progress.kind === 'browser' || progress.kind === 'finishing') {
          setView({ kind: 'progress', state: progress });
        }
      },
    });
    authorization.discard();
    reportMcpServerAddResult(state, input.authKind);
    if (usedBrowser) {
      reportMcpAuthResult({
        outcome: state.kind === 'review' ? 'connected' : state.kind === 'authCancelled' || state.kind === 'cancelled' ? 'cancelled' : state.kind === 'unreachable' ? 'unreachable' : 'failed',
        registration,
        trigger: 'add',
      });
    }
    if (runRef.current !== runId) {
      // The dialog was already closed / restarted: even if this add succeeded it must not quietly
      // leave a server behind.
      if (state.kind === 'review') void removeServer(state.review.serverId).catch(() => {});
      return;
    }
    gateRef.current = null;
    setGate(null);
    if (state.kind === 'cancelled') {
      onClose();
      return;
    }
    if (state.kind === 'invalidURL') {
      setFieldError(t(mcpInvalidUrlMessageKey(state.reason)));
      setView({ kind: 'form' });
      return;
    }
    if (state.kind === 'tokenRejected') {
      // The token input lives on the "access token required" step: go back there and show the error
      // under the field.
      setAuthKind('token');
      setTokenError(true);
      setView({ kind: 'result', state: { kind: 'needsToken' } });
      return;
    }
    if (state.kind === 'review') reviewRef.current = state.review.serverId;
    setView({ kind: 'result', state });
  }, [addServer, name, onClose, preopened, removeServer, t, url]);

  if (!open) return null;

  const displayName = name.trim() || mcpHostname(url.trim()) || t('settings.title');
  const normalized = checkMcpEndpoint(url);
  const reviewState = view.kind === 'result' && view.state.kind === 'review' ? view.state.review : null;

  /** Closes the dialog. In progress = cancel; parked at confirm-permissions = abandon the add. */
  const dismiss = () => {
    teardown();
    onClose();
  };

  const continueSignIn = () => {
    const current = gateRef.current;
    if (!current) return;
    // The window must be opened synchronously within this click: registering the client needs the
    // network afterwards, and opening only once the authorization address is known would be blocked.
    if (windowRef.current?.preopen() === false) {
      // Stopped by a popup blocker: stay on this step and explain why. The gate has not been passed
      // and no client is registered, so the user can allow popups and press again.
      setPopupBlocked(true);
      return;
    }
    setPopupBlocked(false);
    gateRef.current = null;
    setGate(null);
    current.resolve(true);
  };

  const finish = async () => {
    if (!reviewState) return;
    // The user has decided: from here on, collapsing or unmounting the dialog no longer removes this
    // server as a half-finished record.
    reviewRef.current = null;
    setFinishing(true);
    const permissions: Record<string, McpToolPermission> = {};
    for (const tool of reviewState.tools) permissions[tool.toolName] = tool.readOnly ? groupPermissions.readOnly : groupPermissions.changes;
    try {
      await acceptMcpAddedTools(reviewState.serverId, permissions);
    } catch {
      // The permissions were not written: the tools stay quarantined and the user will later see
      // "tools updated" in the detail view and confirm once more; the server is not lost.
    }
    runRef.current += 1;
    onAdded?.(reviewState.serverId);
    onClose();
  };

  const groupSummary = (tools: McpToolSnapshot[]) =>
    tools.length > 0
      ? t('addServer.groupSummary', { names: tools.slice(0, 3).map((tool) => tool.title).join(' · '), count: tools.length })
      : t('addServer.groupCount', { count: 0 });

  const tokenField = (
    <label className={styles.field}>
      <span className={styles.fieldLabel}>{t('addServer.token')}</span>
      <input
        className={styles.input}
        data-invalid={tokenError || undefined}
        type="password"
        autoComplete="off"
        spellCheck={false}
        placeholder={t('addServer.tokenPlaceholder')}
        value={token}
        onChange={(event) => {
          setToken(event.target.value);
          setTokenError(false);
        }}
      />
      <span className={tokenError ? styles.fieldError : styles.fieldHint} role={tokenError ? 'alert' : undefined}>
        {tokenError ? t('addServer.tokenRejected') : t('addServer.tokenNote')}
      </span>
    </label>
  );

  const hero = (status: { label: string; tone: 'success' | 'warning' | 'danger' | 'neutral' } | null, meta?: string) => (
    <div className={styles.heroRow}>
      <McpServerIcon name={displayName} serverURL={url} size={52} />
      <div className={styles.heroText}>
        <span className={styles.heroName}>{reviewState ? reviewState.session.serverName || displayName : displayName}</span>
        <span className={styles.heroMeta}>
          {status ? <span className={styles.statusPill} data-tone={status.tone}>{status.label}</span> : null}
          {meta ? <span>{meta}</span> : null}
        </span>
      </div>
    </div>
  );

  let body: React.ReactNode = null;

  if (view.kind === 'form') {
    const canConnect = url.trim().length > 0;
    body = (
      <form
        data-mcp-add="form"
        onSubmit={(event) => {
          event.preventDefault();
          // Starting from the form always tries auto-detection first; a server that needs a token
          // stops at "access token required".
          if (canConnect) void run({ authKind: 'auto', token: '' });
        }}
      >
        <div className={styles.dialogHeadText} style={{ marginBlockEnd: 18 }}>
          <h2 id="mcp-add-title" className={styles.dialogTitle}>{t('addServer.title')}</h2>
          <p className={styles.dialogSubtitle}>{t('addServer.subtitle')}</p>
        </div>
        <label className={styles.field}>
          <span className={styles.fieldLabel}>{t('addServer.address')}</span>
          <input
            className={styles.input}
            data-mono
            data-invalid={fieldError ? true : undefined}
            data-mcp-field="url"
            // Not type="url": the browser's built-in format validation would show its own message
            // before ours, and the user would never see the "https required" one.
            type="text"
            inputMode="url"
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            placeholder={t('addServer.addressPlaceholder')}
            value={url}
            aria-invalid={fieldError ? true : undefined}
            onChange={(event) => {
              setUrl(event.target.value);
              setFieldError(null);
            }}
          />
          {fieldError ? (
            <span className={styles.fieldError} role="alert">{fieldError}</span>
          ) : (
            <span className={styles.fieldHint}>{t('addServer.addressHint')}</span>
          )}
        </label>
        <label className={styles.field}>
          <span className={styles.fieldLabel}>{t('addServer.name')}</span>
          <input
            className={styles.input}
            type="text"
            autoComplete="off"
            maxLength={64}
            placeholder={t('addServer.namePlaceholder')}
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
        </label>
        <p className={styles.footnote}>{t('addServer.signInNote')}</p>
        <div className={styles.dialogActions}>
          <button type="button" className={styles.quietButton} onClick={dismiss}>{t('addServer.cancel')}</button>
          <Button type="submit" data-mcp-primary disabled={!canConnect}>{t('addServer.connect')}</Button>
        </div>
      </form>
    );
  } else if (view.kind === 'progress') {
    const state = view.state;
    const prompting = state.kind === 'authPrompt' && gate;
    const checklist: Array<{ key: string; label: string; state: 'done' | 'active' | 'waiting' }> = [
      { key: 'found', label: t('addServer.stepFound'), state: state.kind === 'connecting' ? 'active' : 'done' },
      {
        key: 'signIn',
        label:
          state.kind === 'authPrompt' || state.kind === 'browser'
            ? t('addServer.stepSignInNeeded', { name: displayName })
            : signedIn
              ? t('addServer.stepSignedIn', { name: displayName })
              : t('addServer.stepCheckingSignIn'),
        state: state.kind === 'connecting' ? 'waiting' : state.kind === 'finishing' ? 'done' : 'active',
      },
      { key: 'tools', label: t('addServer.stepReadingTools'), state: state.kind === 'finishing' ? 'active' : 'waiting' },
    ];
    body = (
      <div data-mcp-add={state.kind}>
        <h2 id="mcp-add-title" className={styles.dialogTitle} style={{ marginBlockEnd: 16 }}>
          {prompting ? t('addServer.promptTitle', { name: displayName }) : state.kind === 'browser' ? t('addServer.browserTitle') : t('addServer.title')}
        </h2>
        {hero(
          null,
          state.kind === 'connecting'
            ? t('addServer.connecting')
            : state.kind === 'finishing'
              ? t('addServer.finishing')
              : t('addServer.needsSignIn'),
        )}
        <ol className={styles.checklist}>
          {checklist.map((item) => (
            <li key={item.key} data-state={item.state}>
              <span className={styles.checkIcon} aria-hidden="true">
                {item.state === 'done' ? <Check size={12} strokeWidth={3} /> : item.state === 'active' ? <LoaderCircle size={18} className={styles.spinner} /> : null}
              </span>
              {item.label}
            </li>
          ))}
        </ol>
        {prompting ? (
          <>
            <p className={styles.dialogSubtitle} style={{ margin: '16px 0 12px' }}>{t('addServer.promptBody', { name: displayName })}</p>
            <dl className={styles.kvCard}>
              <div className={styles.kvRow}>
                <dt>{t('addServer.promptSignInPage')}</dt>
                <dd data-testid="mcp-auth-host">
                  <Lock size={13} className={styles.lockIcon} aria-hidden="true" />
                  {gate.prompt.authorizationHost}
                </dd>
              </div>
              <div className={styles.kvRow}>
                <dt>{t('addServer.promptConnectsTo')}</dt>
                <dd>{mcpHostname(url.trim())}</dd>
              </div>
            </dl>
            <p className={styles.footnote} style={{ marginBlockStart: 10 }}>{t('addServer.promptHint')}</p>
            {popupBlocked ? (
              <p className={styles.fieldError} style={{ marginBlockStart: 10 }} role="alert" data-mcp-state="popup-blocked">{t('addServer.popupBlocked')}</p>
            ) : null}
          </>
        ) : null}
        {state.kind === 'browser' ? <p className={styles.footnote} style={{ marginBlockStart: 12 }}>{t('addServer.browserBody')}</p> : null}
        <div className={styles.dialogActions}>
          <button type="button" className={styles.quietButton} onClick={dismiss}>{t('addServer.cancel')}</button>
          {prompting ? <Button data-mcp-primary onClick={continueSignIn}>{t('addServer.continue')}</Button> : null}
        </div>
      </div>
    );
  } else {
    const state = view.state;
    const backToForm = () => setView({ kind: 'form' });
    if (state.kind === 'review' && reviewState) {
      const readOnly = reviewState.tools.filter((tool) => tool.readOnly);
      const changes = reviewState.tools.filter((tool) => !tool.readOnly);
      const select = (group: 'readOnly' | 'changes', label: string) => (
        <select
          className={styles.select}
          aria-label={label}
          value={groupPermissions[group]}
          onChange={(event) => setGroupPermissions((current) => ({ ...current, [group]: event.target.value as McpToolPermission }))}
        >
          {PERMISSIONS.map((permission) => (
            <option key={permission} value={permission}>{t(PERMISSION_KEYS[permission])}</option>
          ))}
        </select>
      );
      body = (
        <div data-mcp-add="review">
          <h2 id="mcp-add-title" className={styles.dialogTitle} style={{ marginBlockEnd: 16 }}>{t('addServer.title')}</h2>
          {hero({ label: t('addServer.connected'), tone: 'success' }, t('addServer.toolCount', { count: reviewState.tools.length }))}
          {reviewState.tools.length === 0 ? (
            <p className={styles.noticeBlock} data-tone="neutral">{t('addServer.noTools')}</p>
          ) : (
            <>
              <h3 className={styles.sectionTitle}>{t('addServer.defaultPermissions')}</h3>
              <div className={styles.groupCard}>
                {readOnly.length > 0 ? (
                  <div className={styles.groupRow}>
                    <span className={styles.groupRowText}>
                      <strong>{t('addServer.readOnly')}</strong>
                      <span>{groupSummary(readOnly)}</span>
                    </span>
                    {select('readOnly', t('addServer.readOnly'))}
                  </div>
                ) : null}
                {changes.length > 0 ? (
                  <div className={styles.groupRow}>
                    <span className={styles.groupRowText}>
                      <strong>{t('addServer.changesData')}</strong>
                      <span>{groupSummary(changes)}</span>
                    </span>
                    {select('changes', t('addServer.changesData'))}
                  </div>
                ) : null}
              </div>
              <p className={styles.footnote}>{t('addServer.reviewNote')}</p>
            </>
          )}
          <div className={styles.dialogActions}>
            <button type="button" className={styles.quietButton} onClick={dismiss} disabled={finishing}>{t('addServer.cancel')}</button>
            <Button data-mcp-primary disabled={finishing} onClick={() => void finish()}>{t('addServer.done')}</Button>
          </div>
        </div>
      );
    } else {
      type Failure = { status: string | null; tone: 'warning' | 'danger' | 'neutral'; title: string; body: string };
      const failure: Failure =
        state.kind === 'unreachable'
          ? { status: t('addServer.unreachableStatus'), tone: 'danger', title: t('addServer.unreachableTitle'), body: t('addServer.unreachableBody') }
          : state.kind === 'notMcp'
            ? { status: t('addServer.notMcpStatus'), tone: 'warning', title: t('addServer.notMcpTitle'), body: t('addServer.notMcpBody') }
            : state.kind === 'needsToken'
              ? { status: t('addServer.needsTokenStatus'), tone: 'warning', title: t('addServer.needsTokenTitle'), body: t('addServer.needsTokenBody') }
              : state.kind === 'authCancelled'
                ? { status: t('addServer.authCancelledStatus'), tone: 'warning', title: t('addServer.authCancelledTitle'), body: t('addServer.authCancelledBody') }
                : state.kind === 'limitReached'
                  ? { status: null, tone: 'warning', title: t('addServer.limitTitle'), body: t('addServer.limitBody', { max: state.max }) }
                  : { status: null, tone: 'danger', title: t('addServer.saveFailedTitle'), body: t('addServer.saveFailedBody') };
      body = (
        <div data-mcp-add={state.kind}>
          <h2 id="mcp-add-title" className={styles.dialogTitle} style={{ marginBlockEnd: 16 }}>{t('addServer.title')}</h2>
          {hero(failure.status ? { label: failure.status, tone: failure.tone } : null)}
          <div className={styles.noticeBlock} data-tone={failure.tone} role={state.kind === 'needsToken' && tokenError ? undefined : 'alert'}>
            <strong>{failure.title}</strong>
            <p>{failure.body}</p>
          </div>
          {state.kind === 'needsToken' ? <div style={{ marginBlockStart: 16 }}>{tokenField}</div> : null}
          <div className={styles.dialogActions}>
            {state.kind === 'unreachable' || state.kind === 'notMcp' ? (
              <button type="button" className={styles.quietButton} onClick={backToForm}>{t('addServer.editAddress')}</button>
            ) : (
              <button type="button" className={styles.quietButton} onClick={dismiss}>
                {state.kind === 'limitReached' || state.kind === 'saveFailed' ? t('addServer.close') : t('addServer.cancel')}
              </button>
            )}
            {state.kind === 'unreachable' ? <Button data-mcp-primary onClick={() => void run({ authKind, token: authKind === 'token' ? token : '' })}>{t('addServer.retry')}</Button> : null}
            {state.kind === 'needsToken' ? (
              <Button
                data-mcp-primary
                disabled={!token.trim()}
                onClick={() => {
                  setAuthKind('token');
                  void run({ authKind: 'token', token });
                }}
              >
                {t('addServer.connect')}
              </Button>
            ) : null}
            {state.kind === 'authCancelled' ? <Button data-mcp-primary onClick={() => void run({ authKind: 'auto', token })}>{t('addServer.signInAgain')}</Button> : null}
          </div>
        </div>
      );
    }
  }

  return (
    <Dialog open onClose={finishing ? undefined : dismiss} dismissible={!finishing} size="lg" ariaLabelledBy="mcp-add-title" className={styles.dialog} lockBodyScroll>
      {body}
    </Dialog>
  );
}
