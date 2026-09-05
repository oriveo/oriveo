import { Suspense, type ReactNode } from 'react';
import { ChatRouteShell } from '../../components/chat/ChatRouteShell';

export default function ChatLayout({ children }: { children: ReactNode }) {
  return (
    <Suspense fallback={children}>
      <ChatRouteShell>{children}</ChatRouteShell>
    </Suspense>
  );
}
