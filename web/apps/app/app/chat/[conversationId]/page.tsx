// Next 16: generateStaticParams must not be exported on the web build. Exporting it, even returning
// [], makes Next treat this dynamic route as statically generated, and on-demand rendering then
// trips DYNAMIC_SERVER_USAGE through next-intl's cookies()/headers() in the root layout, so a direct
// SSR hit (a pasted URL or a hard refresh) returns 500. The `dynamic` segment config only accepts a
// literal and cannot be switched per target, so the function is exported conditionally instead: the
// desktop export produces a placeholder shell, while on the web it is undefined, which is equivalent
// to not exporting it and keeps the route purely dynamic.
export const generateStaticParams =
  process.env.ORIVEO_DESKTOP === '1'
    ? (): { conversationId: string }[] => [{ conversationId: 'shell' }]
    : undefined;

export default function ConversationPage() {
  // ChatRouteShell reads the dynamic param without replacing the mounted ChatView.
  return null;
}
