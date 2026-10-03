'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog } from '@oriveo/ui';
import type { McpServerRecord, McpToolChange, McpToolPermission, McpToolSnapshot } from '@oriveo/core/mcp/index';
import { confirmMcpToolChanges, pendingMcpToolChanges } from '../../lib/core/mcp/mcp-server-actions';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

const PERMISSION_KEYS: Record<McpToolPermission, 'permission.auto' | 'permission.ask' | 'permission.off'> = {
  auto: 'permission.auto',
  ask: 'permission.ask',
  off: 'permission.off',
};

/**
 * Confirmation of tool changes. Lists the quarantined tools (new, or description changed) and the ones
 * this read found to be removed. "Confirm and keep using" fetches the definitions from the server once
 * more and releases only the tools that still match what the user was shown.
 *
 * `previous`: the snapshots from before this refresh (available only right after the refresh), used
 * by "View changes" to show the earlier description.
 * `removed`: tools this refresh found the server no longer offers. Neither is persisted, so after a
 * page reload only the "now" half remains.
 */
export function McpToolsChangedDialog({
  server,
  previous,
  removed = [],
  onClose,
  onPause,
}: {
  server: McpServerRecord | null;
  previous?: readonly McpToolSnapshot[];
  removed?: readonly McpToolChange[];
  onClose: () => void;
  /** "Pause this server for now". */
  onPause: (serverId: string) => void;
}) {
  const t = useTranslations('mcp');
  const snapshots = useMcpStore((state) => (server ? state.snapshots[server.id] : undefined));
  const permissions = useMcpStore((state) => (server ? state.permissions[server.id] : undefined));
  const [expanded, setExpanded] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<'stillPending' | 'failedAuth' | 'failedUnreachable' | null>(null);

  if (!server) return null;
  const pending = pendingMcpToolChanges(snapshots ?? [], permissions ?? {});
  const before = new Map((previous ?? []).map((snapshot) => [snapshot.toolName, snapshot]));

  const confirm = async () => {
    setBusy(true);
    setNotice(null);
    const result = await confirmMcpToolChanges(server.id);
    setBusy(false);
    if (result.status === 'confirmed') {
      if (result.stillPending.length > 0) setNotice('stillPending');
      else onClose();
    } else if (result.status === 'needsAuth') setNotice('failedAuth');
    else if (result.status === 'unreachable') setNotice('failedUnreachable');
    else onClose();
  };

  return (
    <Dialog open onClose={busy ? undefined : onClose} dismissible={!busy} ariaLabelledBy="mcp-changes-title" className={styles.dialog} lockBodyScroll>
      <div className={styles.dialogHead}>
        <McpServerIcon name={server.name} iconURL={server.iconURL} size={44} />
        <div className={styles.dialogHeadText}>
          <h2 id="mcp-changes-title" className={styles.dialogTitle}>{t('changes.title', { server: server.name })}</h2>
          <p className={styles.dialogSubtitle}>{t('changes.subtitle')}</p>
        </div>
      </div>

      <ul className={styles.changeList}>
        {pending.map(({ kind, snapshot, permissionAfter }) => {
          const open = expanded === snapshot.toolName;
          const earlier = before.get(snapshot.toolName);
          return (
            <li key={snapshot.toolName} className={styles.changeRow} data-change={kind}>
              <span className={styles.changeBadge} data-tone={kind === 'added' ? 'primary' : 'warning'}>
                {kind === 'added' ? t('changes.new') : t('changes.changed')}
              </span>
              <span className={styles.changeText}>
                <strong>{snapshot.title}</strong>
                <span>
                  {t('changes.rowHint', {
                    group: snapshot.readOnly ? t('settings.readOnly') : t('settings.changesData'),
                    permission: t(PERMISSION_KEYS[permissionAfter]),
                  })}
                </span>
              </span>
              <button
                type="button"
                className={styles.linkButton}
                aria-expanded={open}
                onClick={() => setExpanded(open ? null : snapshot.toolName)}
              >
                {open ? t('changes.hideChanges') : t('changes.seeChanges')}
              </button>
              {open ? (
                <div className={styles.changeDiff}>
                  {kind === 'changed' ? (
                    <>
                      <span className={styles.diffLabel}>{t('changes.before')}</span>
                      <p className={styles.diffText} data-muted={!earlier || undefined}>
                        {earlier ? earlier.description || t('permission.noDescription') : t('changes.beforeUnavailable')}
                      </p>
                    </>
                  ) : null}
                  <span className={styles.diffLabel}>{t('changes.now')}</span>
                  {/* Shown exactly as the server provides it; not translated. */}
                  <p className={styles.diffText}>{snapshot.description || t('permission.noDescription')}</p>
                </div>
              ) : null}
            </li>
          );
        })}
        {removed.map((change) => (
          <li key={`removed:${change.toolName}`} className={styles.changeRow} data-change="removed">
            <span className={styles.changeBadge} data-tone="neutral">{t('changes.removed')}</span>
            <span className={styles.changeText}>
              <strong>{change.title}</strong>
              <span>{t('changes.removedHint')}</span>
            </span>
          </li>
        ))}
      </ul>

      {notice ? (
        <p className={styles.inlineNotice} role="alert">
          {t(`changes.${notice}`)}
        </p>
      ) : null}

      <div className={styles.dialogActionsStacked}>
        <Button data-mcp-primary disabled={busy} aria-busy={busy} onClick={() => void confirm()}>
          {busy ? t('changes.confirming') : t('changes.confirm')}
        </Button>
        <button type="button" className={styles.quietButton} disabled={busy} onClick={() => onPause(server.id)}>
          {t('changes.pause')}
        </button>
      </div>
    </Dialog>
  );
}
