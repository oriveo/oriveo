'use client';

import { useEffect, useRef } from 'react';
import { useTranslations } from 'next-intl';

/**
 * Sends a browser notification when streaming completes while the tab is hidden.
 * Permission is requested lazily: only on the first time the user returns to the tab
 * after a generation completed while they were away.
 */
export function useNotifications(isStreaming: boolean) {
  const t = useTranslations('notification');
  const wasStreamingRef = useRef(false);
  const permissionRequestedRef = useRef(false);
  // Cache the translated string so the effect does not depend on t directly
  const titleRef = useRef(t('title'));
  const bodyRef = useRef(t('responseReady'));
  titleRef.current = t('title');
  bodyRef.current = t('responseReady');

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) return;

    // Track streaming→done transition while hidden
    if (isStreaming) {
      wasStreamingRef.current = true;
    } else if (wasStreamingRef.current && document.hidden) {
      wasStreamingRef.current = false;

      if (Notification.permission === 'granted') {
        const notification = new Notification(titleRef.current, {
          body: bodyRef.current,
          icon: '/favicon.ico',
        });
        notification.onclick = () => {
          window.focus();
          notification.close();
        };
      }
    } else {
      wasStreamingRef.current = false;
    }
  }, [isStreaming]);

  // Request permission lazily when user returns from being away during streaming
  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) return;
    if (permissionRequestedRef.current) return;
    if (Notification.permission !== 'default') return;

    const handleVisibilityChange = () => {
      if (
        !document.hidden &&
        wasStreamingRef.current &&
        !permissionRequestedRef.current
      ) {
        permissionRequestedRef.current = true;
        Notification.requestPermission();
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange);
  }, []);
}
