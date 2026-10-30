'use client';

// Custom search service form (name / address / key → protocol → manual mapping). Shared by the add sheet and the detail page.

import { useId, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Check, Plus, X } from 'lucide-react';
import type { CustomFormField, CustomFormFieldErrors } from '@oriveo/core/search/search-settings';
import type { CustomProtocol } from '@oriveo/core/search/search-transport';
import type { SettingsCatalog } from '../../../lib/search/search-settings-data';
import { MAX_STATIC_PARAMS, type CustomFormKey, type CustomFormValues } from './custom-form-model';
import styles from './WebSearch.module.css';

interface Props {
  values: CustomFormValues;
  onChange: <K extends CustomFormKey>(key: K, value: CustomFormValues[K]) => void;
  feedback: CustomFormFieldErrors | null;
  catalog: SettingsCatalog | null;
  /** Edit mode hides the key field (keys are changed from the Key row). */
  showKey?: boolean;
  /** Notice shown under the address (detail page: address origin change clears the key). */
  addressNotice?: ReactNode;
  disabled?: boolean;
}

const PROTOCOLS: CustomProtocol[] = ['searxng', 'same_as', 'manual'];
const PROTOCOL_LABEL: Record<CustomProtocol, string> = { searxng: 'custom.protocolSearxng', same_as: 'custom.protocolSameAs', manual: 'custom.protocolManual' };
const PROTOCOL_HINT: Record<CustomProtocol, string> = { searxng: 'custom.protocolSearxngHint', same_as: 'custom.protocolSameAsHint', manual: 'custom.protocolManualHint' };

export function CustomServiceForm({ values, onChange, feedback, catalog, showKey = true, addressNotice, disabled }: Props) {
  const t = useTranslations('webSearch');
  const baseId = useId();
  const error = (field: CustomFormField) => {
    const key = feedback?.fields[field];
    return key ? <span className={styles.fieldError} role="alert">{t(`form.${key}`)}</span> : null;
  };
  const presetsAvailable = !!catalog?.available && catalog.entries.length > 0;
  const sameAsRegions = values.protocol === 'same_as' && presetsAvailable && values.sameAsId
    ? catalog!.entries.find((e) => e.id === values.sameAsId)?.regions ?? []
    : [];

  const textField = (key: CustomFormKey, label: string, field: CustomFormField, opts: { placeholder?: string; optional?: boolean; secure?: boolean } = {}) => {
    const id = `${baseId}-${key}`;
    return (
      <div className={styles.formRow}>
        <label className={styles.formLabel} htmlFor={id}>
          {label}
          {opts.optional ? <span className={styles.formOptional}>{t('manual.optional')}</span> : null}
        </label>
        <input
          id={id}
          className={styles.formInput}
          type={opts.secure ? 'password' : 'text'}
          autoComplete="off"
          spellCheck={false}
          placeholder={opts.placeholder}
          value={values[key] as string}
          disabled={disabled}
          aria-invalid={!!feedback?.fields[field] || undefined}
          onChange={(e) => onChange(key, e.target.value as CustomFormValues[typeof key])}
        />
        {error(field)}
      </div>
    );
  };

  return (
    <div className={styles.form}>
      <div className={styles.card}>
        {textField('name', t('custom.name'), 'name', { placeholder: t('custom.namePlaceholder') })}
        <div className={styles.formRow}>
          <label className={styles.formLabel} htmlFor={`${baseId}-address`}>{t('custom.address')}</label>
          <input
            id={`${baseId}-address`}
            className={styles.formInput}
            type="url"
            inputMode="url"
            autoComplete="off"
            spellCheck={false}
            placeholder="https://"
            value={values.address}
            disabled={disabled}
            aria-invalid={!!feedback?.fields.address || undefined}
            onChange={(e) => onChange('address', e.target.value)}
          />
          {error('address')}
          {feedback?.warnings.address ? <span className={styles.fieldWarning}>{t(`form.${feedback.warnings.address}`)}</span> : null}
          {addressNotice}
        </div>
        {showKey ? (
          <div className={styles.formRow}>
            <label className={styles.formLabel} htmlFor={`${baseId}-key`}>
              {t('custom.key')}
              <span className={styles.formOptional}>{t('custom.keyOptional')}</span>
            </label>
            <input
              id={`${baseId}-key`}
              className={styles.formInput}
              type="password"
              autoComplete="off"
              spellCheck={false}
              value={values.key}
              disabled={disabled}
              aria-invalid={!!feedback?.fields.key || undefined}
              onChange={(e) => onChange('key', e.target.value)}
            />
            {error('key')}
          </div>
        ) : null}
      </div>
      <p className={styles.footer}>{t('custom.addressHintWeb')}</p>

      <h3 className={styles.groupTitle}>{t('custom.protocol')}</h3>
      <div className={styles.card} role="radiogroup" aria-label={t('custom.protocol')}>
        {PROTOCOLS.map((protocol) => {
          const unavailable = protocol === 'same_as' && !presetsAvailable;
          const on = values.protocol === protocol;
          return (
            <button
              key={protocol}
              type="button"
              role="radio"
              aria-checked={on}
              className={styles.choiceRow}
              disabled={disabled || unavailable}
              data-protocol={protocol}
              onClick={() => onChange('protocol', protocol)}
            >
              <span className={styles.rowText}>
                <span className={styles.rowTitle}>{t(PROTOCOL_LABEL[protocol])}</span>
                <span className={styles.rowSubtitle}>{unavailable ? t('form.presetUnavailable') : t(PROTOCOL_HINT[protocol])}</span>
              </span>
              {on ? <Check className={styles.choiceCheck} size={18} aria-hidden /> : null}
            </button>
          );
        })}
        {values.protocol === 'same_as' && presetsAvailable ? (
          <div className={styles.formRow}>
            <label className={styles.formLabel} htmlFor={`${baseId}-sameAs`}>{t('custom.protocolSameAsPick')}</label>
            <select
              id={`${baseId}-sameAs`}
              className={styles.formInput}
              value={values.sameAsId ?? ''}
              disabled={disabled}
              onChange={(e) => {
                onChange('sameAsId', e.target.value || null);
                onChange('sameAsRegionId', null);
              }}
            >
              <option value="" disabled>{t('custom.protocolSameAsPick')}</option>
              {catalog!.entries.map((entry) => <option key={entry.id} value={entry.id}>{entry.displayName}</option>)}
            </select>
          </div>
        ) : null}
        {sameAsRegions.length > 1 ? (
          <div className={styles.formRow}>
            <span className={styles.formLabel}>{t('region.label')}</span>
            <Segmented
              options={sameAsRegions.map((r) => ({ value: r.id, label: r.id === 'cn' || r.id === 'intl' ? t(`region.${r.id}`) : r.id }))}
              value={values.sameAsRegionId ?? sameAsRegions[0].id}
              disabled={disabled}
              onChange={(v) => onChange('sameAsRegionId', v)}
              label={t('region.label')}
            />
          </div>
        ) : null}
        {error('protocol')}
      </div>

      {values.protocol === 'manual' ? (
        <>
          <h3 className={styles.groupTitle}>{t('manual.section')}</h3>
          <div className={styles.card}>
            {error('mapping')}
            <div className={styles.formRow}>
              <span className={styles.formLabel}>{t('manual.method')}</span>
              <Segmented
                options={[{ value: 'GET', label: 'GET' }, { value: 'POST', label: 'POST' }]}
                value={values.method}
                disabled={disabled}
                onChange={(v) => onChange('method', v as CustomFormValues['method'])}
                label={t('manual.method')}
              />
              {error('method')}
            </div>
            <div className={styles.formRow}>
              <span className={styles.formLabel}>{t('manual.auth')}</span>
              <Segmented
                options={[
                  { value: 'bearer', label: t('manual.authBearer') },
                  { value: 'header', label: t('manual.authHeader') },
                  { value: 'none', label: t('manual.authNone') },
                ]}
                value={values.auth}
                disabled={disabled}
                onChange={(v) => onChange('auth', v as CustomFormValues['auth'])}
                label={t('manual.auth')}
              />
              {values.auth !== 'header' ? error('auth') : null}
            </div>
            {values.auth === 'header' ? textField('headerName', t('manual.headerName'), 'auth') : null}
            {textField('queryField', t('manual.queryField'), 'query')}
            {textField('countField', t('manual.countField'), 'count', { optional: true })}
            <div className={styles.formRow}>
              <span className={styles.formLabel}>{t('manual.params')}</span>
              {values.params.map((param, index) => (
                <div key={index} className={styles.paramRow}>
                  <input
                    className={styles.formInput}
                    aria-label={t('manual.paramName')}
                    placeholder={t('manual.paramName')}
                    value={param.name}
                    disabled={disabled}
                    onChange={(e) => onChange('params', values.params.map((p, i) => (i === index ? { ...p, name: e.target.value } : p)))}
                  />
                  <input
                    className={styles.formInput}
                    aria-label={t('manual.paramValue')}
                    placeholder={t('manual.paramValue')}
                    value={param.value}
                    disabled={disabled}
                    onChange={(e) => onChange('params', values.params.map((p, i) => (i === index ? { ...p, value: e.target.value } : p)))}
                  />
                  <button
                    type="button"
                    className={styles.iconButton}
                    aria-label={t('detail.deleteConfirm')}
                    disabled={disabled}
                    onClick={() => onChange('params', values.params.filter((_, i) => i !== index))}
                  >
                    <X size={16} aria-hidden />
                  </button>
                </div>
              ))}
              {values.params.length < MAX_STATIC_PARAMS ? (
                <button type="button" className={styles.addInline} disabled={disabled} onClick={() => onChange('params', [...values.params, { name: '', value: '' }])}>
                  <Plus size={16} aria-hidden />
                  {t('manual.addParam')}
                </button>
              ) : null}
              {error('params')}
            </div>
            {textField('resultsPath', t('manual.resultsPath'), 'results')}
            {textField('titlePath', t('manual.titlePath'), 'title')}
            {textField('urlPath', t('manual.urlPath'), 'url')}
            {textField('snippetPath', t('manual.snippetPath'), 'snippet')}
            {textField('sitePath', t('manual.sitePath'), 'site', { optional: true })}
            {textField('datePath', t('manual.datePath'), 'date', { optional: true })}
          </div>
          <p className={styles.footer}>{t('manual.pathHint')}</p>
        </>
      ) : null}
      <p className={styles.footer}>{t('custom.footer')}</p>
    </div>
  );
}

export function Segmented({
  options,
  value,
  onChange,
  disabled,
  label,
}: {
  options: Array<{ value: string; label: string }>;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <div className={styles.segmented} role="radiogroup" aria-label={label}>
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={option.value === value}
          className={styles.segment}
          disabled={disabled}
          onClick={() => onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
