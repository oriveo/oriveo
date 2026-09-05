/// <reference lib="webworker" />

import {
  NoteRecallIndex,
  NOTE_RECALL_WORKER_MAX_INDEX_CHARS,
  NOTE_RECALL_WORKER_MAX_INDEX_NOTES,
  type NoteRecallCandidate,
  type NoteRecallMatch,
} from './note-recall';

type WorkerRequest =
  | { type: 'update-notes'; candidates: NoteRecallCandidate[] }
  | { type: 'recall'; requestID: number; draftText: string };

interface WorkerResult {
  type: 'result';
  requestID: number;
  matches: NoteRecallMatch[];
}

// Library-level index with both an item-count and a character budget, bounding memory and the CPU cost
// of a single recall. Only a bounded candidate projection is accepted as input; full notes never enter
// the worker.
const index = new NoteRecallIndex({
  maxNotes: NOTE_RECALL_WORKER_MAX_INDEX_NOTES,
  maxTotalChars: NOTE_RECALL_WORKER_MAX_INDEX_CHARS,
});

self.onmessage = (event: MessageEvent<WorkerRequest>) => {
  if (event.data.type === 'update-notes') {
    index.update(event.data.candidates);
    return;
  }

  const response: WorkerResult = {
    type: 'result',
    requestID: event.data.requestID,
    matches: index.find(event.data.draftText),
  };
  self.postMessage(response);
};

export {};
