'use client';

import { useState, useMemo, useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { useAppStore } from '../../providers/StoreProvider';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as folderOps from '../../lib/core/folder-ops';
import * as conversationOps from '../../lib/core/conversation-ops';
import { getFolderColorPair } from '@oriveo/shared';
import { isVisibleConversation, sortConversationsByActivity } from '../../lib/utils/conversation-list';
import { stripMarkdownForPreview } from '../../lib/utils/markdown-preview';
import { formatCost } from '../../lib/utils/format-utils';
import { warmConversationInStore } from '../../lib/core/chat/conversation-bootstrap';
import { showToast } from '../Toast';

interface FolderDetailViewProps {
  folderId: string;
}

export function FolderDetailView({ folderId }: FolderDetailViewProps) {
  const router = useRouter();
  const t = useTranslations('sidebar');
  const folder = useAppStore((s) => s.folders.find((f) => f.id === folderId));
  // No filter/map inside a selector: the store equality function here is hardcoded to
  // Object.is (StoreProvider), so returning a new array means every store write re-renders
  // and also invalidates the two useMemo levels below. During streaming the stream batcher
  // writes to the store once per frame, and streaming deliberately continues when ChatView
  // unmounts, so "send a long answer then open a folder" would re-sort this list every frame.
  // See ConversationList for the right shape: subscribe to the whole array and filter in a useMemo.
  const allConversations = useAppStore((s) => s.conversations);
  const conversations = useMemo(
    () => allConversations.filter((c) => c.folderID === folderId),
    [allConversations, folderId],
  );
  const [searchQuery, setSearchQuery] = useState('');

  // Navigate home automatically when the folder is deleted
  useEffect(() => {
    if (!folder) router.push('/');
  }, [folder, router]);

  const sorted = useMemo(
    () => sortConversationsByActivity(conversations.filter(isVisibleConversation)),
    [conversations],
  );

  const filtered = useMemo(() => {
    if (!searchQuery.trim()) return sorted;
    const q = searchQuery.toLowerCase();
    return sorted.filter(
      (c) =>
        c.title.toLowerCase().includes(q) ||
        stripMarkdownForPreview(c.previewText).toLowerCase().includes(q),
    );
  }, [sorted, searchQuery]);

  const handleNewChat = useCallback(() => {
    const convId = folderOps.createConversationInFolder(getVanillaStore(), folderId);
    if (!convId) return;
    router.push(`/chat/${convId}`);
  }, [folderId, router]);

  const handleSelectConversation = useCallback((conversationId: string) => {
    void warmConversationInStore(conversationId);
    router.push(`/chat/${conversationId}`);
  }, [router]);

  if (!folder) return null;

  return (
    <div style={{
      display: 'flex', flexDirection: 'column', height: '100%',
      maxWidth: 720, margin: '0 auto', padding: 'var(--o-space-lg)',
    }}>
      {/* Top navigation */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12, marginBottom: 'var(--o-space-lg)',
      }}>
        <button
          type="button"
          onClick={() => router.push('/')}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            background: 'none', border: 'none', cursor: 'pointer',
            color: 'var(--o-text-secondary)', fontSize: 'var(--o-text-sm)',
            padding: '6px 10px', borderRadius: 'var(--o-radius-md)',
          }}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="15 18 9 12 15 6" />
          </svg>
          {t('back')}
        </button>
        <div style={{ flex: 1 }} />
        <button
          type="button"
          onClick={handleNewChat}
          style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '6px 14px', borderRadius: 'var(--o-radius-md)',
            background: 'var(--o-primary)', color: 'var(--o-primary-text)',
            border: 'none', cursor: 'pointer', fontSize: 'var(--o-text-sm)', fontWeight: 600,
          }}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
          </svg>
          {t('newChatInFolder')}
        </button>
      </div>

      {/* Folder title */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 'var(--o-space-md)' }}>
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke={getFolderColorPair(folder?.colorTag)[0]} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
        </svg>
        <h1 style={{ margin: 0, fontSize: 'var(--o-text-xl)', fontWeight: 600, color: 'var(--o-text)' }}>
          {folder.name}
        </h1>
        <span style={{ fontSize: 'var(--o-text-sm)', color: 'var(--o-text-tertiary)' }}>
          {conversations.length}
        </span>
      </div>

      {/* Search */}
      {sorted.length > 3 && (
        <div style={{ marginBottom: 'var(--o-space-md)', position: 'relative' }}>
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder={t('searchPlaceholder')}
            style={{
              width: '100%', padding: '8px 12px 8px 36px',
              border: '1px solid var(--o-border)', borderRadius: 'var(--o-radius-md)',
              background: 'var(--o-surface)', color: 'var(--o-text)',
              fontSize: 'var(--o-text-sm)', outline: 'none', boxSizing: 'border-box',
            }}
          />
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--o-text-tertiary)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }}>
            <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
        </div>
      )}

      {/* Conversation list */}
      <div style={{ flex: 1, overflowY: 'auto' }}>
        {filtered.length === 0 ? (
          <div style={{
            textAlign: 'center', padding: 'var(--o-space-2xl) var(--o-space-lg)',
            color: 'var(--o-text-tertiary)',
          }}>
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.4, marginBottom: 12 }}>
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
            </svg>
            <p style={{ margin: '0 0 4px', fontSize: 'var(--o-text-sm)' }}>{t('emptyFolder')}</p>
            <p style={{ margin: 0, fontSize: 'var(--o-text-xs)', opacity: 0.7 }}>{t('emptyFolderHint')}</p>
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {filtered.map((conv) => (
              <button
                key={conv.id}
                type="button"
                onClick={() => handleSelectConversation(conv.id)}
                style={{
                  display: 'flex', flexDirection: 'column', gap: 4,
                  padding: '12px 16px', borderRadius: 'var(--o-radius-md)',
                  border: 'none', background: 'none', cursor: 'pointer', textAlign: 'left',
                  transition: 'background 150ms ease',
                }}
                onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--o-surface-raised)')}
                onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
              >
                <span style={{ fontSize: 'var(--o-text-sm)', fontWeight: 500, color: 'var(--o-text)' }}>
                  {conv.title || t('untitled')}
                </span>
                {conv.previewText && (
                  <span style={{
                    fontSize: 'var(--o-text-xs)', color: 'var(--o-text-tertiary)',
                    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>
                    {stripMarkdownForPreview(conv.previewText)}
                  </span>
                )}
                <div style={{ display: 'flex', gap: 8, fontSize: 10, color: 'var(--o-text-tertiary)', opacity: 0.8 }}>
                  {Math.max(conv.messages.length, conv.remoteMessageCount ?? 0) > 0 && <span>{t('messagesCount', { count: Math.max(conv.messages.length, conv.remoteMessageCount ?? 0) })}</span>}
                  {conv.estimatedCost > 0 && <span>{formatCost(conv.estimatedCost)}</span>}
                </div>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
