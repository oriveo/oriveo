'use client';

// Search service detail: status notice, key, default, test search, pricing, results per search, custom edit, delete.

import { useEffect, useMemo, useRef, useState } from 'react';
import { trackEvent } from '../../../lib/core/telemetry';
import { useLocale, useTranslations } from 'next-intl';
import { AlertTriangle, Check, ChevronRight } from 'lucide-react';
import { BackButton } from '@oriveo/ui';
import { regionLinks } from '@oriveo/core/search/search-catalog';
import { normalizeSearchKey, type TransportSpec } from '@oriveo/core/search/search-transport';
import {
  customFormFieldErrors,
  customServiceEditPlan,
  resolveDefaultSearchService,
  RESULT_COUNT_DEFAULT,
  searchAddSheetSections,
  searchPriceSummary,
  RESULT_COUNT_CHOICES,
  SEARXNG_SETUP_GUIDE_URL,
  type CustomFormFieldErrors,
  type SearchTestAction,
} from '@oriveo/core/search/search-settings';
import { ConfirmDialog } from '../../../components/dialogs/ConfirmDialog';
import {
  readSearchServiceKey,
  removeSearchService,
  saveCustomSearchService,
  savePresetSearchService,
  setDefaultSearchServiceId,
  type StoredSearchService,
} from '../../../lib/search/search-service-store';
import {
  camelKey,
  runSearchTest,
  type SearchConnectionOption,
  type SearchForwardTarget,
  type SearchServiceView,
  type SettingsCatalog,
} from '../../../lib/search/search-settings-data';
import { CustomServiceForm } from './CustomServiceForm';
import { checkCustomForm, customFormFromRecord, FIELD_OF_INPUT, manualMapping, type CustomFormKey, type CustomFormValues } from './custom-form-model';
import { useTestGate, type TestGateState } from './use-test-gate';
import { ExternalLink, priceSummaryText, SearchServiceLogo, Spinner, TestFailure, TestResultLine } from './WebSearchParts';
import styles from './WebSearch.module.css';

interface Props {
  /** Dev shots only: an already finished test-search result (production starts idle). */
  initialTest?: TestGateState;
  uid: string;
  view: SearchServiceView;
  catalog: SettingsCatalog | null;
  connections: SearchConnectionOption[];
  services: SearchServiceView[];
  isDefault: boolean;
  onChanged: () => void;
  onDeleted: () => void;
  onBack: () => void;
  /** Opened from a chat search error card: start at the part to fix (key editor / custom settings). */
  initialFocus?: 'key' | 'edit' | 'reconfirm';
}

function openExternal(url: string) {
  window.open(url, '_blank', 'noopener,noreferrer');
}

function targetOf(record: StoredSearchService): SearchForwardTarget {
  return record.kind === 'preset'
    ? { kind: 'preset', serviceId: record.serviceId, regionId: record.regionId, boundHost: record.boundHost }
    : { kind: 'custom', address: record.address, protocol: record.protocol, mapping: record.mapping };
}

export function SearchServiceDetail({ initialTest, uid, view, catalog, connections, services, isDefault, onChanged, onDeleted, onBack, initialFocus }: Props) {
  const t = useTranslations('webSearch');
  const tCommon = useTranslations('common');
  const locale = useLocale();
  const record = view.record;
  const entry = record.kind === 'preset' ? catalog?.entries.find((e) => e.id === record.serviceId) ?? null : null;
  const currentRegion = record.kind === 'preset' ? entry?.regions.find((r) => r.id === record.regionId) ?? null : null;
  const connection = record.kind === 'preset' && record.connectionRef ? connections.find((c) => c.id === record.connectionRef) ?? null : null;
  const reusable = useMemo(() => {
    if (!entry) return null;
    const row = searchAddSheetSections({ catalogAvailable: true, entries: [entry], connections }).sections.find((s) => s.id === 'reuse')?.rows[0];
    return row?.connectionRef ? { connection: connections.find((c) => c.id === row.connectionRef)!, regionId: row.regionId } : null;
  }, [entry, connections]);

  const [subPage, setSubPage] = useState<'main' | 'resultCount'>('main');
  const [keyEditor, setKeyEditor] = useState<null | 'connection' | 'paste'>(null);
  const [pastedKey, setPastedKey] = useState('');
  // For a provider with multiple sites, pick the site when pasting a key; defaults to the first site in the catalog
  const [pasteRegion, setPasteRegion] = useState<string | null>(() => entry?.regions[0]?.id ?? null);
  const [keyError, setKeyError] = useState<string | null>(null);
  const keyInput = useRef<HTMLInputElement | null>(null);
  const keyGate = useTestGate();
  const [query, setQuery] = useState(() => t('test.queryDefault'));
  const testGate = useTestGate(initialTest);
  const [form, setForm] = useState<CustomFormValues | null>(() => (record.kind === 'custom' ? customFormFromRecord(record) : null));
  const [formFeedback, setFormFeedback] = useState<CustomFormFieldErrors | null>(null);
  const saveGate = useTestGate();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const busy = keyGate.state.phase === 'testing' || testGate.state.phase === 'testing' || saveGate.state.phase === 'testing' || deleting;

  const otherServices = services.length - 1;

  const currentKey = async (): Promise<string | null> => {
    if (record.kind === 'preset' && record.connectionRef) return connection?.apiKey ?? null;
    return readSearchServiceKey(uid, record.id);
  };

  // ── key change (test passes before saving) ──
  const openKeyEditor = (mode: 'connection' | 'paste') => {
    keyGate.reset();
    setKeyEditor(mode);
    setKeyError(null);
    if (mode === 'paste') setTimeout(() => keyInput.current?.focus(), 0);
  };

  useEffect(() => {
    if (initialFocus === 'key') openKeyEditor('paste');
    else if (initialFocus === 'edit') setTimeout(() => document.getElementById('web-search-detail-edit')?.scrollIntoView({ block: 'start' }), 0);
    // Mount only: the focus is a one-time entry hint.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const saveKey = async () => {
    if (!keyEditor) return;
    let key: string;
    let regionId = record.kind === 'preset' ? record.regionId : '';
    if (keyEditor === 'connection' && reusable) {
      key = reusable.connection.apiKey;
      regionId = reusable.regionId ?? regionId;
    } else {
      const normalized = normalizeSearchKey(pastedKey);
      if (!normalized.ok) {
        setKeyError(customFormFieldErrors({ errors: [normalized.error] }).fields.key ?? null);
        keyInput.current?.focus();
        return;
      }
      key = normalized.key;
      if (record.kind === 'preset' && pasteRegion && entry && entry.regions.length > 1) regionId = pasteRegion;
    }
    const now = Date.now();
    if (record.kind === 'preset') {
      const region = entry?.regions.find((r) => r.id === regionId);
      const next = {
        ...record,
        regionId,
        boundHost: region?.host ?? record.boundHost,
        connectionRef: keyEditor === 'connection' && reusable ? reusable.connection.id : null,
        updatedAt: now,
      };
      await keyGate.run(
        () => runSearchTest({ target: targetOf(next), key, query: t('test.queryDefault'), count: RESULT_COUNT_DEFAULT, otherServices }),
        async () => {
          await savePresetSearchService(uid, next, { key: next.connectionRef ? undefined : key });
          setKeyEditor(null);
          setPastedKey('');
          onChanged();
        },
      );
    } else {
      await keyGate.run(
        () => runSearchTest({ target: targetOf(record), key, query: t('test.queryDefault'), count: RESULT_COUNT_DEFAULT, otherServices }),
        async () => {
          await saveCustomSearchService(uid, { ...record, updatedAt: now }, { key });
          setKeyEditor(null);
          setPastedKey('');
          onChanged();
        },
      );
    }
  };

  const onAction = (action: SearchTestAction, retry: () => void) => {
    if (action === 'update_key') openKeyEditor('paste');
    else if (action === 'top_up' && entry) openExternal(regionLinks(entry, record.kind === 'preset' ? record.regionId : '').pricing);
    else if (action === 'view_setup_guide') openExternal(SEARXNG_SETUP_GUIDE_URL);
    else if (action === 'reconfirm') void reconfirmHost();
    else if (action === 'check_settings') document.getElementById('web-search-detail-edit')?.scrollIntoView({ block: 'start' });
    else retry();
  };

  // ── host changed: rebind to the catalog host, key kept ──
  const reconfirmHost = async () => {
    if (record.kind !== 'preset' || !currentRegion) return;
    await savePresetSearchService(uid, { ...record, boundHost: currentRegion.host, updatedAt: Date.now() });
    onChanged();
  };

  const runTest = async () => {
    const key = await currentKey();
    await testGate.run(() => runSearchTest({ target: targetOf(record), key, query: query.trim(), count: view.resultCount, otherServices }));
  };

  const setResultCount = async (count: number) => {
    const next = { ...record, resultCount: count, updatedAt: Date.now() };
    if (next.kind === 'preset') await savePresetSearchService(uid, next);
    else await saveCustomSearchService(uid, next);
    setSubPage('main');
    onChanged();
  };

  // ── custom edit (customServiceEditPlan) ──
  const snapshotRef = (mapping: TransportSpec | null) => (mapping as { snapshotOf?: { serviceId?: string; region?: string | null } } | null)?.snapshotOf ?? null;
  const editPlan = record.kind === 'custom' && form
    ? customServiceEditPlan({
      before: {
        name: record.name,
        address: record.address,
        protocol: record.protocol,
        mapping: record.mapping,
        presetId: snapshotRef(record.mapping)?.serviceId ?? null,
        regionId: snapshotRef(record.mapping)?.region ?? null,
      },
      after: {
        name: form.name,
        address: form.address,
        protocol: form.protocol,
        mapping: form.protocol === 'manual' ? manualMapping(form) : null,
        presetId: form.sameAsId,
        regionId: form.sameAsId ? form.sameAsRegionId ?? catalog?.entries.find((e) => e.id === form.sameAsId)?.regions[0]?.id ?? null : null,
      },
    })
    : null;
  const saveCustom = async () => {
    if (record.kind !== 'custom' || !form || !editPlan) return;
    const keepSnapshot = form.protocol === 'same_as' && record.protocol === 'same_as' && !editPlan.resnapshot ? record.mapping : null;
    const check = checkCustomForm(form, catalog, { requireKeyCheck: editPlan.showKeyField, keepSnapshot });
    setFormFeedback(check.feedback);
    if (check.feedback.blocking) return;
    const next = { ...record, name: form.name.trim(), address: form.address.trim(), protocol: form.protocol, mapping: check.mapping, updatedAt: Date.now() };
    if (editPlan.mode === 'save') {
      await saveCustomSearchService(uid, { ...record, name: next.name, updatedAt: next.updatedAt });
      onChanged();
      return;
    }
    // Source changed: test the new key (may be empty) together with the new address in one test; otherwise keep the stored key
    const key = editPlan.clearsKey ? check.key : await readSearchServiceKey(uid, record.id);
    await saveGate.run(
      () => runSearchTest({ target: targetOf(next), key, query: t('test.queryDefault'), count: RESULT_COUNT_DEFAULT, otherServices }),
      async () => {
        await saveCustomSearchService(uid, next, editPlan.clearsKey ? { key: check.key ?? null } : {});
        setForm((prev) => (prev ? { ...prev, key: '' } : prev));
        onChanged();
      },
    );
  };

  // ── delete ──
  const remaining = services.filter((s) => s.record.id !== record.id);
  const newDefaultId = isDefault && remaining.length > 0
    ? resolveDefaultSearchService({ serviceIds: remaining.map((s) => s.record.id), storedDefault: null })
    : null;
  const newDefaultName = newDefaultId ? remaining.find((s) => s.record.id === newDefaultId)?.name ?? '' : '';
  const doDelete = async () => {
    setDeleting(true);
    try {
      await removeSearchService(uid, record.id);
      trackEvent('search_service_removed', {
        service: record.kind === 'preset' ? record.serviceId : 'custom',
        protocol: record.kind === 'preset' ? 'catalog' : record.protocol,
      });
      if (isDefault) await setDefaultSearchServiceId(uid, null);
      setConfirmDelete(false);
      onDeleted();
    } finally {
      setDeleting(false);
    }
  };

  const keyValue = view.keySource === 'connection'
    ? t('detail.keyViaConnection', { name: view.row.connectionName ?? '' })
    : view.hasKey
      ? `${t('detail.keySaved')} ••••${view.keyTail ?? ''}`
      : t('detail.keyNone');

  const status = view.row.status;
  const notice = (() => {
    if (status === 'host_changed' && currentRegion) {
      return (
        <div className={styles.noticeCard} role="status">
          <AlertTriangle size={18} aria-hidden />
          <span>{t('detail.hostChangedNotice', { name: view.name, host: currentRegion.host })}</span>
          <button type="button" className={styles.inlineAction} disabled={busy} onClick={() => void reconfirmHost()}>{t('action.reconfirm')}</button>
        </div>
      );
    }
    if (status === 'withdrawn') {
      return <div className={styles.noticeCard} role="status"><AlertTriangle size={18} aria-hidden /><span>{t('detail.withdrawnNotice')}</span></div>;
    }
    if (status === 'catalog_unavailable') {
      return <div className={styles.noticeCard} role="status"><AlertTriangle size={18} aria-hidden /><span>{t('row.catalogUnavailable')}</span></div>;
    }
    if (status === 'connection_missing' || status === 'needs_key') {
      return (
        <div className={styles.noticeCard} role="status">
          <AlertTriangle size={18} aria-hidden />
          <span>{status === 'connection_missing' ? t('detail.connectionMissingNotice') : t('row.needsKey')}</span>
          <button type="button" className={styles.inlineAction} disabled={busy} onClick={() => openKeyEditor('paste')}>{t('connect.pasteAnother')}</button>
        </div>
      );
    }
    return null;
  })();

  if (subPage === 'resultCount') {
    return (
      <div className={styles.page} data-testid="web-search-result-count">
        <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => setSubPage('main')} />
        <h1 className={styles.title}>{t('detail.resultCount')}</h1>
        <div className={styles.card} role="radiogroup" aria-label={t('detail.resultCount')}>
          {RESULT_COUNT_CHOICES.map((count) => (
            <button key={count} type="button" role="radio" aria-checked={view.resultCount === count} className={styles.choiceRow} onClick={() => void setResultCount(count)}>
              <span className={styles.rowTitle}>{t('detail.resultCountValue', { count: String(count) })}</span>
              {view.resultCount === count ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
            </button>
          ))}
        </div>
        <p className={styles.footer}>{t('detail.resultCountFooter')}</p>
      </div>
    );
  }

  const summary = entry && record.kind === 'preset' ? searchPriceSummary(entry, record.regionId) : null;

  return (
    <div className={styles.page} data-testid="web-search-detail">
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={onBack} disabled={busy} />
      <h1 className={styles.titleWithLogo}>
        <SearchServiceLogo serviceId={record.kind === 'preset' ? record.serviceId : null} size={32} />
        <span>{view.name}</span>
      </h1>

      {notice}

      <div className={styles.card}>
        <button type="button" className={styles.row} disabled={busy} onClick={() => openKeyEditor(reusable && record.kind === 'preset' ? 'connection' : 'paste')}>
          <span className={styles.rowText}><span className={styles.rowTitle}>{t('detail.key')}</span></span>
          <span className={styles.rowValue} data-testid="web-search-key-value">{keyValue}</span>
          <ChevronRight className={styles.chevron} size={18} aria-hidden />
        </button>
        <div className={styles.switchRow}>
          <span id="web-search-default-title" className={styles.rowTitle}>{t('detail.setDefault')}</span>
          <button
            type="button"
            role="switch"
            className={styles.switch}
            aria-checked={isDefault}
            aria-labelledby="web-search-default-title"
            disabled={isDefault || busy}
            onClick={async () => {
              await setDefaultSearchServiceId(uid, record.id);
              onChanged();
            }}
          >
            <span className={styles.switchThumb} aria-hidden />
          </button>
        </div>
      </div>

      {keyEditor ? (
        <div className={styles.card} data-testid="web-search-key-editor">
          {reusable && record.kind === 'preset' ? (
            <div role="radiogroup" aria-label={t('detail.key')}>
              <button type="button" role="radio" aria-checked={keyEditor === 'connection'} className={styles.choiceRow} disabled={busy} onClick={() => setKeyEditor('connection')}>
                <span className={styles.rowText}>
                  <span className={styles.rowTitle}>{t('connect.useConnection', { name: reusable.connection.name })}</span>
                  <span className={styles.rowSubtitle}>{t('connect.useConnectionHint')}</span>
                </span>
                {keyEditor === 'connection' ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
              </button>
              <button type="button" role="radio" aria-checked={keyEditor === 'paste'} className={styles.choiceRow} disabled={busy} onClick={() => openKeyEditor('paste')}>
                <span className={styles.rowText}><span className={styles.rowTitle}>{t('connect.pasteAnother')}</span></span>
                {keyEditor === 'paste' ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
              </button>
            </div>
          ) : null}
          {keyEditor === 'paste' && record.kind === 'preset' && entry && entry.regions.length > 1 ? (
            <div className={styles.formRow}>
              <span className={styles.formLabel}>{t('region.label')}</span>
              <div className={styles.segmented} role="radiogroup" aria-label={t('region.label')}>
                {entry.regions.map((r) => (
                  <button key={r.id} type="button" role="radio" aria-checked={r.id === pasteRegion} className={styles.segment} disabled={busy} onClick={() => setPasteRegion(r.id)}>
                    {r.id === 'cn' || r.id === 'intl' ? t(`region.${r.id}`) : r.id}
                  </button>
                ))}
              </div>
            </div>
          ) : null}
          {keyEditor === 'paste' ? (
            <div className={styles.formRow}>
              <label className={styles.formLabel} htmlFor="web-search-detail-key">{t('connect.keyLabel')}</label>
              <input
                id="web-search-detail-key"
                ref={keyInput}
                className={styles.formInput}
                type="password"
                autoComplete="off"
                spellCheck={false}
                placeholder={t('connect.keyPlaceholder', { name: view.name })}
                value={pastedKey}
                disabled={busy}
                aria-invalid={!!keyError || undefined}
                onChange={(e) => {
                  setPastedKey(e.target.value);
                  setKeyError(null);
                }}
              />
              {keyError ? <span className={styles.fieldError} role="alert">{t(`form.${keyError}`)}</span> : null}
              {entry && record.kind === 'preset' ? (
                <div className={styles.linkRow}><ExternalLink href={regionLinks(entry, pasteRegion ?? record.regionId).keyHelp}>{t('connect.getKey', { name: view.name })}</ExternalLink></div>
              ) : null}
            </div>
          ) : null}
          {keyGate.state.phase === 'failed' ? <TestFailure presentation={keyGate.state.presentation} onAction={(a) => onAction(a, () => void saveKey())} disabled={busy} /> : null}
          <div className={styles.cardActions}>
            <button type="button" className={styles.secondaryButton} disabled={busy} onClick={() => setKeyEditor(null)}>{tCommon('cancel')}</button>
            <button type="button" className={styles.primaryButtonSmall} disabled={busy} onClick={() => void saveKey()}>
              {keyGate.state.phase === 'testing' ? <><Spinner />{t('consent.testing')}</> : t('detail.save')}
            </button>
          </div>
        </div>
      ) : null}

      <section className={styles.group}>
        <h2 className={styles.groupTitle}>{t('test.section')}</h2>
        <div className={styles.card}>
          <div className={styles.testRow}>
            <input
              className={styles.formInput}
              aria-label={t('test.section')}
              value={query}
              disabled={busy}
              onChange={(e) => setQuery(e.target.value)}
            />
            <button type="button" className={styles.primaryButtonSmall} disabled={busy || !query.trim()} onClick={() => void runTest()}>
              {testGate.state.phase === 'testing' ? <Spinner /> : t('test.run')}
            </button>
          </div>
          {testGate.state.phase === 'passed' || testGate.state.phase === 'failed' ? (
            <div className={styles.testResult}>
              <TestResultLine presentation={testGate.state.presentation} />
              {testGate.state.phase === 'failed' && testGate.state.presentation.action !== 'none' ? (
                <button type="button" className={styles.inlineAction} disabled={busy} onClick={() => {
                    if (testGate.state.phase === 'failed') onAction(testGate.state.presentation.action, () => void runTest());
                  }}>
                  {t(`action.${camelKey(testGate.state.presentation.action)}`)}
                </button>
              ) : null}
            </div>
          ) : null}
        </div>
      </section>

      {summary && entry && record.kind === 'preset' ? (
        <section className={styles.group}>
          <h2 className={styles.groupTitle}>{t('detail.price')}</h2>
          <div className={styles.card}>
            <div className={styles.priceBlock}>
              <span className={styles.priceMain}>{priceSummaryText(t, locale, summary)}</span>
              <span className={styles.priceNote}>
                {[summary.billing === 'non_empty_only' ? t('price.nonEmptyOnly') : '', t('price.billedBy', { name: view.name })].filter(Boolean).join(' · ')}
              </span>
              <ExternalLink href={regionLinks(entry, record.regionId).pricing}>{t('detail.officialLink', { name: view.name })}</ExternalLink>
            </div>
          </div>
        </section>
      ) : null}

      <section className={styles.group}>
        <div className={styles.card}>
          <button type="button" className={styles.row} disabled={busy} data-testid="web-search-advanced" onClick={() => setSubPage('resultCount')}>
            <span className={styles.rowText}><span className={styles.rowTitle}>{t('detail.advanced')}</span></span>
            <span className={styles.rowValue}>{t('detail.resultCountValue', { count: String(view.resultCount) })}</span>
            <ChevronRight className={styles.chevron} size={18} aria-hidden />
          </button>
        </div>
      </section>

      {record.kind === 'custom' && form ? (
        <section className={styles.group} id="web-search-detail-edit">
          <CustomServiceForm
            values={form}
            catalog={catalog}
            feedback={formFeedback}
            showKey={editPlan?.showKeyField ?? false}
            disabled={busy}
            addressNotice={editPlan?.clearsKey && view.hasKey ? <span className={styles.fieldWarning}>{t('detail.addressChangeNotice')}</span> : null}
            onChange={<K extends CustomFormKey>(key: K, value: CustomFormValues[K]) => {
              setForm((prev) => (prev ? { ...prev, [key]: value } : prev));
              const field = FIELD_OF_INPUT[key];
              if (field) {
                setFormFeedback((prev) => {
                  if (!prev) return prev;
                  const fields = { ...prev.fields };
                  delete fields[field];
                  return { ...prev, fields, warnings: field === 'address' ? {} : prev.warnings };
                });
              }
            }}
          />
          {saveGate.state.phase === 'failed' ? <TestFailure presentation={saveGate.state.presentation} onAction={(a) => onAction(a, () => void saveCustom())} disabled={busy} /> : null}
          <div className={styles.cardActions}>
            <button type="button" className={styles.primaryButtonSmall} disabled={busy} onClick={() => void saveCustom()}>
              {saveGate.state.phase === 'testing' ? <><Spinner />{t('consent.testing')}</> : t('detail.save')}
            </button>
          </div>
        </section>
      ) : null}

      <section className={styles.group}>
        <div className={styles.card}>
          <button type="button" className={styles.dangerRow} disabled={busy} onClick={() => setConfirmDelete(true)}>{t('detail.delete')}</button>
        </div>
      </section>

      <ConfirmDialog
        open={confirmDelete}
        title={t('detail.deleteTitle', { name: view.name })}
        message={[t('detail.deleteBody'), newDefaultId ? t('detail.deleteNewDefault', { name: newDefaultName }) : ''].filter(Boolean).join(' ')}
        confirmLabel={t('detail.deleteConfirm')}
        cancelLabel={tCommon('cancel')}
        destructive
        loading={deleting}
        onConfirm={() => void doDelete()}
        onCancel={() => setConfirmDelete(false)}
      />
    </div>
  );
}
