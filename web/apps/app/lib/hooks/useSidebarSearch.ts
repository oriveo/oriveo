import { useState, useMemo, useEffect } from 'react';
import type { Conversation } from '@oriveo/shared';
import { isVisibleConversation } from '../utils/conversation-list';
import { stripMarkdownForPreview } from '../utils/markdown-preview';
import { searchConversations } from '../infra/storage/idb';

/**
 * Sidebar search: local title, preview and message matching, plus a 300ms debounced IDB full-text
 * search, merged and deduplicated. With no query it returns the visible conversation list.
 */
export function useSidebarSearch(
  conversations: Conversation[],
  visibleConversations: Conversation[],
) {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<Conversation[] | null>(null);

  // Conflict copies are searchable too; a matching title already carries the conflict prefix, so no extra marker is needed
  const searchableConversations = useMemo(
    () =>
      conversations.filter(
        (c) => isVisibleConversation(c) || c.isConflictCopy === true,
      ),
    [conversations],
  );

  const localSearchMatches = useMemo(() => {
    const q = searchQuery.toLowerCase();
    return searchableConversations.filter(
      (c) =>
        c.title.toLowerCase().includes(q) ||
        stripMarkdownForPreview(c.previewText).toLowerCase().includes(q) ||
        c.messages?.some((m) => m.text.toLowerCase().includes(q)),
    );
  }, [searchableConversations, searchQuery]);

  useEffect(() => {
    let cancelled = false;

    const query = searchQuery.trim();
    if (!query || query.length < 2) {
      setSearchResults(null);
      return;
    }

    // 300ms debounce, so not every keystroke triggers an IDB search
    const timer = setTimeout(() => {
      searchConversations(query).then((persisted) => {
        if (cancelled) return;

        const merged = new Map<string, Conversation>();
        for (const conversation of [...localSearchMatches, ...persisted]) {
          merged.set(conversation.id, conversation);
        }
        setSearchResults(Array.from(merged.values()));
      });
    }, 300);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [searchQuery, localSearchMatches]);

  const filtered = useMemo(() => {
    if (!searchQuery.trim()) return visibleConversations;
    return searchResults ?? [];
  }, [visibleConversations, searchQuery, searchResults]);

  return { searchQuery, setSearchQuery, filtered };
}
