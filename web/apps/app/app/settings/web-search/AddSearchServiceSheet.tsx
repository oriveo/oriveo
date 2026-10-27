'use client';

// Add search service sheet: grouped presets → connect page (reuse / paste) or custom form → consent → test → save.
// Desktop: centered card. Narrow screens: bottom sheet.

import { useMemo, useRef, useState, type ReactNode } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Check, ChevronRight, Plus } from 'lucide-react';
import { BackButton, CloseButton, Dialog } from '@oriveo/ui';
import type { CatalogEntry } from '@oriveo/core/search/search-catalog';
import { regionLinks } from '@oriveo/core/search/search-catalog';
import { normalizeSearchKey } from '@oriveo/core/search/search-transport';
import {
  customFormFieldErrors,
  searchAddSheetSections,
  searchConsentLines,
  searchPriceSummary,
  RESULT_COUNT_DEFAULT,
  SEARXNG_SETUP_GUIDE_URL,
  type CustomFormFieldErrors,
  type SearchAddSheetRow,
  type SearchTestAction,
} from '@oriveo/core/search/search-settings';
import { saveCustomSearchService, savePresetSearchService } from '../../../lib/search/search-service-store';
import { trackEvent } from '../../../lib/core/telemetry';
import {
  runSearchTest,
  type SearchConnectionOption,
  type SearchServiceView,
  type SettingsCatalog,
} from '../../../lib/search/search-settings-data';
import { CustomServiceForm } from './CustomServiceForm';
import { checkCustomForm, emptyCustomForm, FIELD_OF_INPUT, type CustomFormCheck, type CustomFormKey, type CustomFormValues } from './custom-form-model';
import { useTestGate, type TestGateState } from './use-test-gate';
import { ConsentCard, ExternalLink, priceSummaryText, SearchServiceLogo, Spinner, TestFailure } from './WebSearchParts';
import styles from './WebSearch.module.css';

type Step =
  | { kind: 'pick' }
  | { kind: 'connect'; row: SearchAddSheetRow }
  | { kind: 'custom' }
  | { kind: 'customConsent'; values: CustomFormValues; check: CustomFormCheck };

/** Where the sheet opens: the pick step by default; the chat «Turn on» action opens connect with the reused connection prefilled. */
export type AddSheetInitial =
  | { step: 'pick' }
  | { step: 'connect'; row: SearchAddSheetRow; mode?: 'connection' | 'paste'; gate?: TestGateState }
  | { step: 'custom'; values: CustomFormValues }
  | { step: 'customConsent'; values: CustomFormValues; check: CustomFormCheck; gate?: TestGateState };

interface Props {
  initial?: AddSheetInitial;
  open: boolean;
  onClose: () => void;
  uid: string;
  catalog: SettingsCatalog | null;
  connections: SearchConnectionOption[];
  services: SearchServiceView[];
  onSaved: () => void;
  onOpenService: (id: string) => void;
}

const SECTION_TITLE = { reuse: 'add.sectionReuse', domestic: 'add.sectionDomestic', overseas: 'add.sectionOverseas' } as const;

function newServiceId(): string {
  return typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : `svc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function openExternal(url: string) {
  window.open(url, '_blank', 'noopener,noreferrer');
}

function initialStep(initial: AddSheetInitial | undefined): Step {
  if (!initial || initial.step === 'pick') return { kind: 'pick' };
  if (initial.step === 'connect') return { kind: 'connect', row: initial.row };
  if (initial.step === 'custom') return { kind: 'custom' };
  return { kind: 'customConsent', values: initial.values, check: initial.check };
}

export function AddSearchServiceSheet({ initial, open, onClose, uid, catalog, connections, services, onSaved, onOpenService }: Props) {
  const t = useTranslations('webSearch');
  const tCommon = useTranslations('common');
  const [step, setStep] = useState<Step>(() => initialStep(initial));
  const [busy, setBusy] = useState(false);
  const [customValues, setCustomValues] = useState<CustomFormValues>(() => (initial?.step === 'custom' ? initial.values : emptyCustomForm()));
  const [customFeedback, setCustomFeedback] = useState<CustomFormFieldErrors | null>(null);

  const close = () => {
    if (busy) return;
    setStep({ kind: 'pick' });
    setCustomValues(emptyCustomForm());
    setCustomFeedback(null);
    onClose();
  };

  const back = () => {
    if (busy) return;
    setStep(step.kind === 'customConsent' ? { kind: 'custom' } : { kind: 'pick' });
  };

  const title = step.kind === 'custom' ? t('custom.title') : t('add.title');

  return (
    <Dialog
      open={open}
      onClose={close}
      dismissible={!busy}
      size="lg"
      padded={false}
      ariaLabelledBy="web-search-add-title"
      overlayClassName={styles.sheetOverlay}
      className={styles.sheet}
      lockBodyScroll
    >
      <div className={styles.sheetHeader}>
        {step.kind !== 'pick' ? (
          <BackButton label={tCommon('back')} onClick={back} disabled={busy} className={styles.sheetBack} />
        ) : <span className={styles.sheetHeaderSpacer} />}
        <h2 id="web-search-add-title" className={styles.sheetTitle}>{title}</h2>
        <CloseButton label={tCommon('close')} onClick={close} disabled={busy} />
      </div>
      {step.kind === 'pick' ? (
        <PickStep
          catalog={catalog}
          connections={connections}
          services={services}
          onPick={(row) => {
            if (row.addedServiceRef) {
              close();
              onOpenService(row.addedServiceRef);
            } else {
              setStep({ kind: 'connect', row });
            }
          }}
          onCustom={() => setStep({ kind: 'custom' })}
        />
      ) : null}
      {step.kind === 'connect' ? (
        <ConnectStep
          uid={uid}
          catalog={catalog}
          row={step.row}
          connections={connections}
          services={services}
          onBusy={setBusy}
          onSaved={onSaved}
          onDone={close}
          initialMode={initial?.step === 'connect' && initial.row.serviceId === step.row.serviceId ? initial.mode : undefined}
          initialGate={initial?.step === 'connect' && initial.row.serviceId === step.row.serviceId ? initial.gate : undefined}
        />
      ) : null}
      {step.kind === 'custom' ? (
        <div className={styles.sheetBodyWithFooter}>
          <div className={styles.sheetScroll}>
            <CustomServiceForm
              values={customValues}
              catalog={catalog}
              feedback={customFeedback}
              onChange={<K extends CustomFormKey>(key: K, value: CustomFormValues[K]) => {
                setCustomValues((prev) => ({ ...prev, [key]: value }));
                const field = FIELD_OF_INPUT[key];
                if (field) {
                  setCustomFeedback((prev) => {
                    if (!prev) return prev;
                    const fields = { ...prev.fields };
                    delete fields[field];
                    const warnings = field === 'address' ? {} : prev.warnings;
                    return { ...prev, fields, warnings };
                  });
                }
              }}
            />
          </div>
          <div className={styles.sheetFooter}>
            <button
              type="button"
              className={styles.primaryButton}
              onClick={() => {
                const check = checkCustomForm(customValues, catalog);
                setCustomFeedback(check.feedback);
                if (!check.feedback.blocking) setStep({ kind: 'customConsent', values: customValues, check });
              }}
            >
              {t('custom.continue')}
            </button>
          </div>
        </div>
      ) : null}
      {step.kind === 'customConsent' ? (
        <CustomConsentStep
          uid={uid}
          values={step.values}
          check={step.check}
          services={services}
          onBusy={setBusy}
          onSaved={onSaved}
          onDone={close}
          onCheckSettings={() => setStep({ kind: 'custom' })}
          initialGate={initial?.step === 'customConsent' ? initial.gate : undefined}
        />
      ) : null}
    </Dialog>
  );
}

function PickStep({
  catalog,
  connections,
  services,
  onPick,
  onCustom,
}: {
  catalog: SettingsCatalog | null;
  connections: SearchConnectionOption[];
  services: SearchServiceView[];
  onPick: (row: SearchAddSheetRow) => void;
  onCustom: () => void;
}) {
  const t = useTranslations('webSearch');
  const locale = useLocale();
  const sheet = useMemo(() => searchAddSheetSections({
    catalogAvailable: !!catalog?.available,
    entries: catalog?.entries ?? [],
    connections,
    services: services.map((s) => (s.record.kind === 'preset'
      ? { id: s.record.id, kind: 'preset' as const, serviceId: s.record.serviceId }
      : { id: s.record.id, kind: 'custom' as const })),
  }), [catalog, connections, services]);
  const entryOf = (id: string) => catalog?.entries.find((e) => e.id === id) ?? null;

  return (
    <div className={styles.sheetScroll}>
      {sheet.presets === 'unavailable' ? (
        <div className={styles.card}><p className={styles.cardNote}>{t('add.presetsUnavailable')}</p></div>
      ) : null}
      {sheet.sections.map((section) => (
        <section key={section.id} className={styles.group} data-add-section={section.id}>
          <h3 className={styles.groupTitle}>{t(SECTION_TITLE[section.id])}</h3>
          <div className={styles.card}>
            {section.rows.map((row) => {
              const entry = entryOf(row.serviceId);
              if (!entry) return null;
              const price = priceSummaryText(t, locale, searchPriceSummary(entry, row.regionId), { otherRegion: section.id !== 'reuse' });
              const subtitle = row.addedServiceRef
                ? t('add.added')
                : section.id === 'reuse'
                  ? [t('add.reuseRow', { name: row.connectionName ?? '' }), price].filter(Boolean).join(' · ')
                  : price;
              return (
                <button key={row.serviceId} type="button" className={styles.row} data-add-row={row.serviceId} onClick={() => onPick(row)}>
                  <SearchServiceLogo serviceId={row.serviceId} />
                  <span className={styles.rowText}>
                    <span className={styles.rowTitle}>{entry.displayName}</span>
                    {subtitle ? <span className={styles.rowSubtitle}>{subtitle}</span> : null}
                  </span>
                  {row.addedServiceRef ? <Check className={styles.rowCheck} size={18} aria-hidden /> : <ChevronRight className={styles.chevron} size={18} aria-hidden />}
                </button>
              );
            })}
          </div>
        </section>
      ))}
      <section className={styles.group} data-add-section="custom">
        <h3 className={styles.groupTitle}>{t('add.sectionCustom')}</h3>
        <div className={styles.card}>
          <button type="button" className={styles.row} data-add-row="custom" onClick={onCustom}>
            <SearchServiceLogo serviceId={null} />
            <span className={styles.rowText}>
              <span className={styles.rowTitle}>{t('add.customTitle')}</span>
              <span className={styles.rowSubtitle}>{t('add.customSubtitle')}</span>
            </span>
            <Plus className={styles.chevron} size={18} aria-hidden />
          </button>
        </div>
      </section>
      <p className={styles.footer}>{t('add.footer')}</p>
    </div>
  );
}

/** Bottom primary button + the passed / failed lines that sit around the consent card. */
function GateFooter({ gate, onAgree, onDone }: { gate: TestGateState; onAgree: () => void; onDone: () => void }) {
  const t = useTranslations('webSearch');
  if (gate.phase === 'passed') {
    return <button type="button" className={styles.primaryButton} onClick={onDone}>{t('consent.done')}</button>;
  }
  return (
    <button type="button" className={styles.primaryButton} disabled={gate.phase === 'testing'} aria-busy={gate.phase === 'testing'} onClick={onAgree}>
      {gate.phase === 'testing' ? <><Spinner />{t('consent.testing')}</> : t('consent.agree')}
    </button>
  );
}

function PassedNotice({ becameDefault }: { becameDefault: boolean }) {
  const t = useTranslations('webSearch');
  return (
    <div className={styles.passedNotice} role="status" data-testid="web-search-consent-passed">
      <Check size={18} aria-hidden />
      {t(becameDefault ? 'consent.passedDefault' : 'consent.passed')}
    </div>
  );
}

function StepShell({ header, children, footer }: { header: ReactNode; children: ReactNode; footer: ReactNode }) {
  return (
    <div className={styles.sheetBodyWithFooter}>
      <div className={styles.sheetScroll}>
        {header}
        {children}
      </div>
      <div className={styles.sheetFooter}>{footer}</div>
    </div>
  );
}

function ConnectStep({
  uid,
  catalog,
  row,
  connections,
  services,
  onBusy,
  onSaved,
  onDone,
  initialMode,
  initialGate,
}: {
  initialMode?: 'connection' | 'paste';
  initialGate?: TestGateState;
  uid: string;
  catalog: SettingsCatalog | null;
  row: SearchAddSheetRow;
  connections: SearchConnectionOption[];
  services: SearchServiceView[];
  onBusy: (busy: boolean) => void;
  onSaved: () => void;
  onDone: () => void;
}) {
  const t = useTranslations('webSearch');
  const locale = useLocale();
  const entry = catalog?.entries.find((e) => e.id === row.serviceId) as CatalogEntry;
  const connection = row.connectionRef ? connections.find((c) => c.id === row.connectionRef) ?? null : null;
  const [mode, setMode] = useState<'connection' | 'paste'>(connection && initialMode !== 'paste' ? 'connection' : 'paste');
  const [pasteRegion, setPasteRegion] = useState(entry.regions[0]?.id ?? '');
  const [key, setKey] = useState('');
  const [keyError, setKeyError] = useState<string | null>(null);
  const keyInput = useRef<HTMLInputElement | null>(null);
  const serviceId = useRef(newServiceId());
  const gate = useTestGate(initialGate);
  const wasEmpty = services.length === 0;
  const regionId = mode === 'connection' && connection ? row.regionId ?? entry.regions[0].id : pasteRegion;
  const region = entry.regions.find((r) => r.id === regionId) ?? entry.regions[0];
  const links = regionLinks(entry, region.id);
  const summary = searchPriceSummary(entry, region.id);
  const locked = gate.state.phase === 'testing' || gate.state.phase === 'passed';

  const agree = async () => {
    let useKey: string;
    if (mode === 'connection' && connection) {
      useKey = connection.apiKey;
    } else {
      const normalized = normalizeSearchKey(key);
      if (!normalized.ok) {
        setKeyError(customFormFieldErrors({ errors: [normalized.error] }).fields.key ?? null);
        keyInput.current?.focus();
        return;
      }
      useKey = normalized.key;
    }
    onBusy(true);
    try {
      await gate.run(
        () => runSearchTest({
          target: { kind: 'preset', serviceId: entry.id, regionId: region.id, boundHost: region.host },
          key: useKey,
          query: t('test.queryDefault'),
          count: RESULT_COUNT_DEFAULT,
          otherServices: services.length,
        }),
        async () => {
          const now = Date.now();
          await savePresetSearchService(uid, {
            id: serviceId.current,
            kind: 'preset',
            serviceId: entry.id,
            name: entry.displayName,
            regionId: region.id,
            boundHost: region.host,
            connectionRef: mode === 'connection' && connection ? connection.id : null,
            createdAt: now,
            updatedAt: now,
          }, { key: mode === 'connection' && connection ? undefined : useKey });
          // Saved only after the test search passed (search_service_added).
          trackEvent('search_service_added', {
            service: entry.id, protocol: 'catalog', via: mode === 'connection' && connection ? 'reuse' : 'paste', test_result: 'passed',
          });
          onSaved();
        },
      );
    } finally {
      onBusy(false);
    }
  };

  const onAction = (action: SearchTestAction) => {
    if (action === 'update_key') {
      setMode('paste');
      setTimeout(() => keyInput.current?.focus(), 0);
    } else if (action === 'top_up') openExternal(links.pricing);
    else if (action === 'view_setup_guide') openExternal(SEARXNG_SETUP_GUIDE_URL);
    else void agree();
  };

  const header = (
    <div className={styles.hero}>
      <SearchServiceLogo serviceId={entry.id} size={56} />
      <span className={styles.heroName}>{entry.displayName}</span>
      <span className={styles.heroSubtitle}>
        {[priceSummaryText(t, locale, summary), summary.billing === 'non_empty_only' ? t('price.nonEmptyOnly') : ''].filter(Boolean).join(' · ')}
      </span>
    </div>
  );

  return (
    <StepShell header={header} footer={<GateFooter gate={gate.state} onAgree={() => void agree()} onDone={onDone} />}>
      {connection ? (
        <div className={styles.card} role="radiogroup" aria-label={t('detail.key')}>
          <button type="button" role="radio" aria-checked={mode === 'connection'} className={styles.choiceRow} disabled={locked} onClick={() => setMode('connection')}>
            <span className={styles.rowText}>
              <span className={styles.rowTitle}>{t('connect.useConnection', { name: connection.name })}</span>
              <span className={styles.rowSubtitle}>{t('connect.useConnectionHint')}</span>
            </span>
            {mode === 'connection' ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
          </button>
          <button type="button" role="radio" aria-checked={mode === 'paste'} className={styles.choiceRow} disabled={locked} onClick={() => setMode('paste')}>
            <span className={styles.rowText}><span className={styles.rowTitle}>{t('connect.pasteAnother')}</span></span>
            {mode === 'paste' ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
          </button>
        </div>
      ) : null}
      {mode === 'paste' ? (
        <div className={styles.card}>
          {entry.regions.length > 1 ? (
            <div className={styles.formRow}>
              <span className={styles.formLabel}>{t('region.label')}</span>
              <div className={styles.segmented} role="radiogroup" aria-label={t('region.label')}>
                {entry.regions.map((r) => (
                  <button key={r.id} type="button" role="radio" aria-checked={r.id === pasteRegion} className={styles.segment} disabled={locked} onClick={() => setPasteRegion(r.id)}>
                    {r.id === 'cn' || r.id === 'intl' ? t(`region.${r.id}`) : r.id}
                  </button>
                ))}
              </div>
            </div>
          ) : null}
          <div className={styles.formRow}>
            <label className={styles.formLabel} htmlFor="web-search-connect-key">{t('connect.keyLabel')}</label>
            <input
              id="web-search-connect-key"
              ref={keyInput}
              className={styles.formInput}
              type="password"
              autoComplete="off"
              spellCheck={false}
              placeholder={t('connect.keyPlaceholder', { name: entry.displayName })}
              value={key}
              disabled={locked}
              aria-invalid={!!keyError || undefined}
              onChange={(e) => {
                setKey(e.target.value);
                setKeyError(null);
              }}
            />
            {keyError ? <span className={styles.fieldError} role="alert">{t(`form.${keyError}`)}</span> : null}
          </div>
          <div className={styles.linkRow}><ExternalLink href={links.keyHelp}>{t('connect.getKey', { name: entry.displayName })}</ExternalLink></div>
        </div>
      ) : null}
      {gate.state.phase === 'failed' ? <TestFailure presentation={gate.state.presentation} onAction={onAction} /> : null}
      {gate.state.phase === 'passed' ? <PassedNotice becameDefault={wasEmpty} /> : null}
      <ConsentCard lines={searchConsentLines({ kind: 'preset', platform: 'web', serviceName: entry.displayName, host: region.host })} />
      <div className={styles.linkRow}><ExternalLink href={links.terms}>{t('connect.viewTerms', { name: entry.displayName })}</ExternalLink></div>
    </StepShell>
  );
}

function CustomConsentStep({
  uid,
  values,
  check,
  services,
  onBusy,
  onSaved,
  onDone,
  onCheckSettings,
  initialGate,
}: {
  initialGate?: TestGateState;
  uid: string;
  values: CustomFormValues;
  check: CustomFormCheck;
  services: SearchServiceView[];
  onBusy: (busy: boolean) => void;
  onSaved: () => void;
  onDone: () => void;
  onCheckSettings: () => void;
}) {
  const t = useTranslations('webSearch');
  const gate = useTestGate(initialGate);
  const serviceId = useRef(newServiceId());
  const wasEmpty = services.length === 0;
  const protocolName = t(values.protocol === 'searxng' ? 'custom.protocolSearxng' : values.protocol === 'same_as' ? 'custom.protocolSameAs' : 'custom.protocolManual');

  const agree = async () => {
    onBusy(true);
    try {
      await gate.run(
        () => runSearchTest({
          target: { kind: 'custom', address: values.address.trim(), protocol: values.protocol, mapping: check.mapping },
          key: check.key,
          query: t('test.queryDefault'),
          count: RESULT_COUNT_DEFAULT,
          otherServices: services.length,
        }),
        async () => {
          const now = Date.now();
          await saveCustomSearchService(uid, {
            id: serviceId.current,
            kind: 'custom',
            name: values.name.trim(),
            protocol: values.protocol,
            address: values.address.trim(),
            mapping: check.mapping,
            createdAt: now,
            updatedAt: now,
          }, { key: check.key ?? undefined });
          trackEvent('search_service_added', { service: 'custom', protocol: values.protocol, via: 'custom', test_result: 'passed' });
          onSaved();
        },
      );
    } finally {
      onBusy(false);
    }
  };

  const onAction = (action: SearchTestAction) => {
    if (action === 'check_settings' || action === 'update_key') onCheckSettings();
    else if (action === 'view_setup_guide') openExternal(SEARXNG_SETUP_GUIDE_URL);
    else void agree();
  };

  const header = (
    <div className={styles.hero}>
      <span className={styles.heroServer}><SearchServiceLogo serviceId={null} size={56} /></span>
      <span className={styles.heroName}>
        {values.name.trim()}
        <span className={styles.badge}>{t('badge.custom')}</span>
      </span>
      <span className={styles.heroSubtitle}>{`${protocolName} · ${check.host ?? ''}`}</span>
    </div>
  );

  return (
    <StepShell header={header} footer={<GateFooter gate={gate.state} onAgree={() => void agree()} onDone={onDone} />}>
      {gate.state.phase === 'failed' ? <TestFailure presentation={gate.state.presentation} onAction={onAction} /> : null}
      {gate.state.phase === 'passed' ? <PassedNotice becameDefault={wasEmpty} /> : null}
      <ConsentCard lines={searchConsentLines({ kind: 'custom', platform: 'web', serviceName: values.name.trim(), host: check.host })} />
    </StepShell>
  );
}
