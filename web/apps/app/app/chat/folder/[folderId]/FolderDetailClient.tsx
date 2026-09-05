'use client';

import { useParams } from 'next/navigation';
import { FolderDetailView } from '../../../../components/sidebar/FolderDetailView';

export function FolderDetailClient() {
  const { folderId } = useParams<{ folderId: string }>();
  return <FolderDetailView folderId={folderId} />;
}
