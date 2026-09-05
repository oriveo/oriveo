'use client';

import { useParams } from 'next/navigation';
import { NoteDetail } from '../../../components/notes/NoteDetail';

export function NoteDetailClient() {
  const { noteId } = useParams<{ noteId: string }>();
  return <NoteDetail noteId={noteId} />;
}
