import { describe, expect, it, vi } from 'vitest';
import {
  buildReferenceKnowledgeFile,
  codePointCount,
  prepareKnowledgeUpload,
  sanitizeSkillFileName,
  validateKnowledgeBaseQuota,
  validateReferenceFileSize,
} from '../knowledge-utils';

describe('knowledge utils', () => {
  describe('codePointCount', () => {
    it('counts mixed unicode by code point', () => {
      expect(codePointCount('abc\u4e2d\u6587\ud83e\udde0')).toBe(6);
    });
  });

  describe('reference files', () => {
    it('only enforces the raw 3MB upload size, not an 8000 character cap', () => {
      const content = '\u4e2d'.repeat(9001);
      const file = buildReferenceKnowledgeFile({
        id: 'ref-1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        sourceType: 'text',
        content,
        now: '2026-04-12T00:00:00.000Z',
      });

      expect(file.charCount).toBe(9001);
      expect(validateReferenceFileSize(3 * 1024 * 1024)).toBeNull();
      expect(validateReferenceFileSize(3 * 1024 * 1024 + 1)).toBe('reference_file_too_large');
    });
  });

  describe('knowledge base files', () => {
    it('extracts xlsx files into derived txt uploads while preserving display metadata', async () => {
      const parseOfficeText = vi.fn().mockResolvedValue('cell 1\tcell 2');
      const source = new File(['xlsx-bytes'], 'sheet.xlsx', {
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      });

      const prepared = await prepareKnowledgeUpload(source, parseOfficeText);

      expect(parseOfficeText).toHaveBeenCalledWith(source);
      expect(prepared.displayName).toBe('sheet.xlsx');
      expect(prepared.displayMimeType).toBe(source.type);
      expect(prepared.ingestionMode).toBe('extracted_text');
      expect(prepared.extractedFrom).toBe('xlsx');
      expect(prepared.uploadFile.name).toBe('sheet.txt');
      expect(prepared.uploadFile.type).toBe('text/plain');
      expect(prepared.uploadFile.size).toBeGreaterThan(0);
    });

    it('enforces file count, single-file size, and total storage quota', () => {
      expect(validateKnowledgeBaseQuota({ existingCount: 5, existingBytes: 0, nextFileBytes: 1 })).toBe('knowledge_total_size_exceeded');
      expect(validateKnowledgeBaseQuota({ existingCount: 1, existingBytes: 0, nextFileBytes: 20 * 1024 * 1024 + 1 })).toBe('knowledge_file_too_large');
      expect(validateKnowledgeBaseQuota({
        existingCount: 1,
        existingBytes: 100 * 1024 * 1024 - 10,
        nextFileBytes: 11,
      })).toBe('knowledge_total_size_exceeded');
      expect(validateKnowledgeBaseQuota({ existingCount: 1, existingBytes: 1024, nextFileBytes: 2048 })).toBeNull();
    });
  });

  describe('sanitizeSkillFileName', () => {
    it('removes control characters and truncates overly long file names', () => {
      const cleaned = sanitizeSkillFileName(`line1\n\t${'a'.repeat(200)}.txt`);

      expect(cleaned.includes('\n')).toBe(false);
      expect(cleaned.includes('\t')).toBe(false);
      expect(cleaned.length).toBeLessThanOrEqual(120);
    });
  });
});
