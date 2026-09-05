'use client';

import { useState, useRef, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Input, Dialog } from '@oriveo/ui';
import { parseBackupFile, generateImportPreview, executeImportAndRefreshStore } from '../../../lib/backup';
import type { ImportMode, ImportPreview, ImportResult } from '../../../lib/backup';
import { ImportResultCard } from './ImportResultCard';
import { BackupPreviewCard } from './BackupPreviewCard';
import styles from './BackupPage.module.css';

type ImportStep = 'idle' | 'password' | 'preview' | 'keyPassword' | 'importing' | 'done';

export function ImportSection() {
  const t = useTranslations('pages.backup');
  const tc = useTranslations('common');

  const [importFile, setImportFile] = useState<File | null>(null);
  const [importStep, setImportStep] = useState<ImportStep>('idle');
  const [importPassword, setImportPassword] = useState('');
  const [importMode, setImportMode] = useState<ImportMode>('importNew');
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [importResult, setImportResult] = useState<ImportResult | null>(null);
  const [importError, setImportError] = useState('');
  const [keyPassword, setKeyPassword] = useState('');
  const [showReplaceConfirm, setShowReplaceConfirm] = useState(false);
  const [dragging, setDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleFileSelected = useCallback(async (file: File) => {
    setImportFile(file); setImportError(''); setImportResult(null);
    setImportPassword(''); setKeyPassword(''); setImportMode('importNew');
    try {
      const { backupFile, imageEntries } = await parseBackupFile(file);
      const previewData = await generateImportPreview(backupFile, imageEntries);
      setPreview(previewData); setImportStep('preview');
    } catch (err: any) {
      if (err?.message === 'PASSWORD_REQUIRED') { setImportStep('password'); }
      else { setImportError(t('invalidFile')); setImportStep('idle'); }
    }
  }, [t]);

  async function handleDecryptLegacy() {
    if (!importFile || !importPassword) return;
    setImportError('');
    try {
      const { backupFile, imageEntries } = await parseBackupFile(importFile, importPassword);
      const previewData = await generateImportPreview(backupFile, imageEntries);
      setPreview(previewData); setImportStep('preview');
    } catch { setImportError(t('wrongPassword')); }
  }

  function handleStartImport() {
    if (!preview) return;
    if (importMode === 'replaceAll') { setShowReplaceConfirm(true); return; }
    if (preview.backupFile.containsKeys && preview.backupFile.encryptedKeys && !keyPassword) { setImportStep('keyPassword'); return; }
    doImport();
  }

  function handleConfirmReplace() {
    setShowReplaceConfirm(false);
    if (preview?.backupFile.containsKeys && preview.backupFile.encryptedKeys && !keyPassword) { setImportStep('keyPassword'); return; }
    doImport();
  }

  async function doImport() {
    if (!preview) return;
    setImportStep('importing'); setImportError('');
    try {
      const result = await executeImportAndRefreshStore(preview, importMode, keyPassword || undefined);
      setImportResult(result); setImportStep('done');
    } catch (err: any) {
      if (err?.message === 'WRONG_PASSWORD') { setImportError(t('wrongPassword')); setImportStep('keyPassword'); }
      else { setImportError(t('importFailed')); setImportStep('preview'); }
    }
  }

  function resetImport() {
    setImportFile(null); setImportStep('idle'); setPreview(null); setImportResult(null);
    setImportError(''); setImportPassword(''); setKeyPassword(''); setImportMode('importNew');
  }

  function renderModeOption(mode: ImportMode, title: string, hint: string, recommended?: boolean) {
    return (
      <label className={`${styles.modeOption} ${importMode === mode ? styles.modeOptionSelected : ''}`}>
        <input type="radio" name="importMode" checked={importMode === mode} onChange={() => setImportMode(mode)} />
        <div className={styles.modeOptionContent}>
          <span className={styles.modeOptionTitle}>
            {title}
            {recommended && <span className={styles.modeRecommended}>{t('recommended')}</span>}
          </span>
          <span className={styles.modeOptionHint}>{hint}</span>
        </div>
      </label>
    );
  }

  return (
    <>
      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('importSection')}</h2>
        <p className={styles.sectionHint}>{t('importDescription')}</p>
        <div className={styles.form}>
          {importStep === 'idle' && (
            <>
              <div className={`${styles.dropZone} ${dragging ? styles.dropZoneDragging : ''}`}
                onClick={() => fileInputRef.current?.click()}
                onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
                onDragLeave={(e) => { e.preventDefault(); setDragging(false); }}
                onDrop={(e) => { e.preventDefault(); setDragging(false); const file = e.dataTransfer.files[0]; if (file) handleFileSelected(file); }}>
                {t('dropZone')}
              </div>
              <input ref={fileInputRef} type="file" accept=".oriveo,.json" style={{ display: 'none' }}
                onChange={(e) => { const file = e.target.files?.[0]; if (file) handleFileSelected(file); e.target.value = ''; }} />
              {importError && <div className={styles.errorMsg}>{importError}</div>}
            </>
          )}

          {importStep === 'password' && importFile && (
            <>
              <div className={styles.fileInfoRow}>
                <span className={styles.fileName}>{importFile.name}</span>
                <span className={styles.fileClear} onClick={resetImport}>&times;</span>
              </div>
              <div className={styles.passwordSection}>
                <span className={styles.passwordLabel}>{t('legacyPasswordHint')}</span>
                <Input type="password" placeholder={t('importPassword')} value={importPassword}
                  onChange={(e) => setImportPassword(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && handleDecryptLegacy()} />
              </div>
              {importError && <div className={styles.errorMsg}>{importError}</div>}
              <div className={styles.importActions}>
                <Button tone="secondary" onClick={resetImport}>{tc('cancel')}</Button>
                <Button onClick={handleDecryptLegacy} disabled={!importPassword}>{tc('next')}</Button>
              </div>
            </>
          )}

          {importStep === 'preview' && preview && importFile && (
            <>
              <div className={styles.fileInfoRow}>
                <span className={styles.fileName}>{importFile.name}</span>
                <span className={styles.fileClear} onClick={resetImport}>&times;</span>
              </div>
              {preview.checksumValid === false && (
                <div className={styles.warningMsg}>
                  {preview.backupFile.platform !== 'Web' ? t('checksumCrossPlatform') : t('checksumWarning')}
                </div>
              )}
              {preview.attachmentChecksumIssues.length > 0 && (
                <div className={styles.warningMsg}>{t('attachmentChecksumWarning')}</div>
              )}
              <BackupPreviewCard preview={preview} />
              <div className={styles.modeSelector}>
                <h3 className={styles.modeSelectorLabel}>{t('importModeTitle')}</h3>
                {renderModeOption('importNew', t('modeImportNew'), t('modeImportNewHint'), true)}
                {renderModeOption('merge', t('modeMerge'), t('modeMergeHint'))}
                {renderModeOption('replaceAll', t('modeReplaceAll'), t('modeReplaceAllHint'))}
              </div>
              {importError && <div className={styles.errorMsg}>{importError}</div>}
              <div className={styles.importActions}>
                <Button tone="secondary" onClick={resetImport}>{tc('cancel')}</Button>
                <Button tone={importMode === 'replaceAll' ? 'danger' : 'primary'} onClick={handleStartImport}>{t('import')}</Button>
              </div>
            </>
          )}

          {importStep === 'keyPassword' && (
            <>
              <div className={styles.passwordSection}>
                <span className={styles.passwordLabel}>{t('keyPasswordHint')}</span>
                <Input type="password" placeholder={t('keyPasswordPlaceholder')} value={keyPassword}
                  onChange={(e) => { setKeyPassword(e.target.value); setImportError(''); }}
                  onKeyDown={(e) => e.key === 'Enter' && doImport()} />
              </div>
              {importError && <div className={styles.errorMsg}>{importError}</div>}
              <div className={styles.importActions}>
                <Button tone="secondary" onClick={() => { setKeyPassword(''); doImport(); }}>{t('skipKeys')}</Button>
                <Button onClick={() => doImport()} disabled={!keyPassword}>{t('restoreKeys')}</Button>
              </div>
            </>
          )}

          {importStep === 'importing' && (
            <div className={styles.importingState}>
              <div className={styles.spinner} />
              <span>{t('importing')}</span>
            </div>
          )}

          {importStep === 'done' && importResult && (
            <>
              <ImportResultCard result={importResult} />
              <Button className={styles.submitBtn} onClick={resetImport}>{tc('done')}</Button>
            </>
          )}
        </div>
      </div>

      <Dialog open={showReplaceConfirm} onClose={() => setShowReplaceConfirm(false)}>
        <h2 className={styles.confirmTitle}>{t('replaceConfirmTitle')}</h2>
        <p className={styles.confirmDesc}>{t('replaceConfirmDesc')}</p>
        <div className={styles.confirmActions}>
          <Button tone="secondary" size="sm" onClick={() => setShowReplaceConfirm(false)}>{tc('cancel')}</Button>
          <Button tone="danger" size="sm" onClick={handleConfirmReplace}>{t('replaceConfirmAction')}</Button>
        </div>
      </Dialog>
    </>
  );
}
