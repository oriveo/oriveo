import { FolderDetailClient } from './FolderDetailClient';

// Next 16: web must not export generateStaticParams (not even returning []), otherwise the dynamic
// route is treated as statically generated and on-demand rendering 500s because the root layout
// reads cookies(), which triggers DYNAMIC_SERVER_USAGE. Hence the conditional export: the desktop
// export produces a placeholder shell and web gets undefined, which is equivalent to not exporting it at all and leaves a purely dynamic route.
export const generateStaticParams =
  process.env.ORIVEO_DESKTOP === '1'
    ? (): { folderId: string }[] => [{ folderId: 'shell' }]
    : undefined;

export default function FolderDetailPage() {
  return <FolderDetailClient />;
}
