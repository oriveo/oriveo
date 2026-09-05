import { useEffect, useMemo, useRef, useState } from 'react';
import type { Note } from '@oriveo/shared';
import {
  NoteRecallIndex,
  NOTE_RECALL_WORKER_MAX_INDEX_NOTES,
  recallCandidates,
  type NoteRecallMatch,
  type RelatedNoteResult,
} from '../../../lib/core/notes/note-recall';

interface WorkerResult {
  type: 'result';
  requestID: number;
  matches: NoteRecallMatch[];
}

export function useRelatedNoteRecall(inputText: string, notes: Note[]): RelatedNoteResult[] {
  const [matches, setMatches] = useState<NoteRecallMatch[]>([]);
  const workerRef = useRef<Worker | null>(null);
  // Main-thread fallback when the worker is unavailable: uses the default 128-note budget, since the larger library-wide budget is only allowed inside the worker.
  const fallbackIndexRef = useRef(new NoteRecallIndex());
  const latestRequestIDRef = useRef(0);
  const notesRef = useRef(notes);
  const inputTextRef = useRef(inputText);
  notesRef.current = notes;
  inputTextRef.current = inputText;

  useEffect(() => {
    if (typeof Worker === 'undefined') return undefined;
    let worker: Worker;
    try {
      worker = new Worker(
        new URL('../../../lib/core/notes/note-recall.worker.ts', import.meta.url),
        { type: 'module' },
      );
    } catch {
      fallbackIndexRef.current.update(
        recallCandidates(notesRef.current, NOTE_RECALL_WORKER_MAX_INDEX_NOTES),
      );
      return undefined;
    }
    worker.onmessage = (event: MessageEvent<WorkerResult>) => {
      if (event.data.type !== 'result' || event.data.requestID !== latestRequestIDRef.current) return;
      setMatches(event.data.matches);
    };
    worker.onerror = () => {
      worker.terminate();
      if (workerRef.current === worker) workerRef.current = null;
      fallbackIndexRef.current.update(
        recallCandidates(notesRef.current, NOTE_RECALL_WORKER_MAX_INDEX_NOTES),
      );
      const draftText = inputTextRef.current;
      if (draftText.trim()) {
        setMatches(fallbackIndexRef.current.find(draftText));
      }
    };
    workerRef.current = worker;
    return () => {
      worker.terminate();
      if (workerRef.current === worker) workerRef.current = null;
    };
  }, []);

  useEffect(() => {
    // Only a bounded candidate projection crosses the worker boundary, truncated before the structured clone; full Note objects never cross.
    const candidates = recallCandidates(notes, NOTE_RECALL_WORKER_MAX_INDEX_NOTES);
    const worker = workerRef.current;
    if (worker) {
      try {
        worker.postMessage({ type: 'update-notes', candidates });
      } catch {
        worker.terminate();
        workerRef.current = null;
        fallbackIndexRef.current.update(candidates);
      }
    } else {
      fallbackIndexRef.current.update(candidates);
    }
  }, [notes]);

  useEffect(() => {
    latestRequestIDRef.current += 1;
    const requestID = latestRequestIDRef.current;
    if (!inputText.trim()) {
      setMatches([]);
      return undefined;
    }

    const timer = window.setTimeout(() => {
      const worker = workerRef.current;
      if (worker) {
        try {
          worker.postMessage({ type: 'recall', requestID, draftText: inputText });
          return;
        } catch {
          worker.terminate();
          workerRef.current = null;
          fallbackIndexRef.current.update(
            recallCandidates(notesRef.current, NOTE_RECALL_WORKER_MAX_INDEX_NOTES),
          );
        }
      }
      const fallbackMatches = fallbackIndexRef.current.find(inputText);
      if (requestID === latestRequestIDRef.current) setMatches(fallbackMatches);
    }, 180);
    return () => window.clearTimeout(timer);
  }, [inputText, notes]);

  return useMemo(() => {
    const notesByID = new Map(notesRef.current.map((note) => [note.id, note]));
    return matches.flatMap((match) => {
      const note = notesByID.get(match.id);
      return note ? [{ note, score: match.score, matchedTerms: match.matchedTerms }] : [];
    });
  }, [matches, notes]);
}
