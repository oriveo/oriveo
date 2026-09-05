import { NoteDetailClient } from './NoteDetailClient';

// Next 16: the web build must not export generateStaticParams, even one returning [],
// because that makes the dynamic route be treated as statically generated, and on-demand
// rendering then hits DYNAMIC_SERVER_USAGE with a 500 when the root layout reads cookies().
// Hence the conditional export: the desktop export produces a placeholder shell, while web
// gets undefined, which is equivalent to not exporting it at all and stays fully dynamic.
export const generateStaticParams =
  process.env.ORIVEO_DESKTOP === '1'
    ? (): { noteId: string }[] => [{ noteId: 'shell' }]
    : undefined;

export default function NoteDetailPage() {
  return <NoteDetailClient />;
}
