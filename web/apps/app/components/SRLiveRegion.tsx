'use client';

import { useState, useCallback, useMemo, createContext, useContext, type ReactNode } from 'react';

interface SRAnnounceContextType {
  announce: (message: string) => void;
}

const SRAnnounceContext = createContext<SRAnnounceContextType>({ announce: () => {} });

export function useSRAnnounce() {
  return useContext(SRAnnounceContext);
}

export function SRLiveRegion({ children }: { children: ReactNode }) {
  const [message, setMessage] = useState('');

  const announce = useCallback((msg: string) => {
    setMessage('');
    requestAnimationFrame(() => setMessage(msg));
  }, []);

  // An object literal is a new reference on every render and would re-render the whole wrapped tree.
  // announce is already a stable useCallback, so it just must not be rewrapped in a new object.
  const contextValue = useMemo(() => ({ announce }), [announce]);

  return (
    <SRAnnounceContext.Provider value={contextValue}>
      {children}
      <div
        role="status"
        aria-live="assertive"
        aria-atomic="true"
        style={{
          position: 'absolute',
          width: '1px',
          height: '1px',
          padding: 0,
          margin: '-1px',
          overflow: 'hidden',
          clip: 'rect(0, 0, 0, 0)',
          whiteSpace: 'nowrap',
          border: 0,
        }}
      >
        {message}
      </div>
    </SRAnnounceContext.Provider>
  );
}
