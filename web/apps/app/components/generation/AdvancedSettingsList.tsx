'use client';

import { useMemo, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight } from 'lucide-react';
import type { GenerationParameterOverrides, GenerationParameterProfile, GenerationParameterValue } from '@oriveo/core/providers/request-builders/types';
import { generationParameterRows, type GenerationParameterRow } from '../../lib/core/chat/generation-parameter-rows';
import type { GenerationParameterLayer, SourcedGenerationParameterOverrides } from '../../lib/core/chat/generation-parameter-settings';
import {
  advancedClusterSummary,
  advancedCommonFootnote,
  advancedSettingsSections,
  type AdvancedSettingsCluster,
  type AdvancedSettingsItem,
} from '../../lib/core/chat/advanced-settings-layout';
import {
  advancedClusterSubtitleCopy,
  advancedClusterSummaryCopy,
  advancedClusterTitleCopy,
  advancedCommonFootnoteCopy,
  advancedFamilyNoteCopy,
  advancedModeLabelCopy,
  advancedSectionTitleCopy,
} from '../../lib/core/chat/model-options-copy';
import type { AdditionalBodyEntryRow } from '../../lib/core/chat/additional-body-entry';
import { AdvancedParameterRow, type AdvancedRowExtras } from './AdvancedParameterRow';
import { useCopy } from './useCopy';
import styles from './AdvancedSettingsList.module.css';

type ProfileParameter = GenerationParameterProfile['parameters'][number];

/**
 * Parameter list of advanced settings: sections, subgroups, and every row's value and explanation are computed by
 * the UI data layer, and this only draws them. None of the outbound / source / grouping rules are decided here.
 */
export function AdvancedSettingsList({
  profile, parameters, resolved, lowerValues, editingLayers, thinking, engineName, extras, inputIdPrefix,
  isReadOnly, showsLegend, additionalBody, onOpenAdditionalBody, onSet, onClear, onOmit,
}: {
  profile: GenerationParameterProfile;
  parameters: readonly ProfileParameter[];
  resolved: SourcedGenerationParameterOverrides | undefined;
  lowerValues: GenerationParameterOverrides;
  editingLayers: readonly GenerationParameterLayer[];
  thinking?: { budgetTokens?: number } | null;
  /** Local engine name, used in the common card footnote "gray numbers are X's own defaults". */
  engineName?: string;
  extras: Readonly<Record<string, AdvancedRowExtras>>;
  inputIdPrefix: string;
  isReadOnly: boolean;
  showsLegend: boolean;
  additionalBody: AdditionalBodyEntryRow;
  onOpenAdditionalBody: () => void;
  onSet: (id: string, value: GenerationParameterValue) => void;
  onClear: (id: string) => void;
  onOmit: (id: string) => void;
}) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const parameterIds = useMemo(() => parameters.map((parameter) => parameter.id), [parameters]);
  const rows = useMemo(() => generationParameterRows({
    parameterIds, profile, resolved, editingLayers, lowerValues, ...(thinking !== undefined ? { thinking } : {}),
  }), [editingLayers, lowerValues, parameterIds, profile, resolved, thinking]);
  const rowsById = useMemo(() => Object.fromEntries(rows.map((row) => [row.id, row])), [rows]);
  const parametersById = useMemo(() => new Map(parameters.map((parameter) => [parameter.id, parameter])), [parameters]);
  const sections = useMemo(() => advancedSettingsSections(parameters), [parameters]);

  const renderRow = (id: string) => {
    const row = rowsById[id];
    const parameter = parametersById.get(id);
    if (!row || !parameter) return null;
    return (
      <AdvancedParameterRow
        key={id}
        row={row}
        parameter={parameter}
        extras={extras[id] ?? { editable: false }}
        inputId={`${inputIdPrefix}-${id}`}
        isReadOnly={isReadOnly}
        onSet={(value) => onSet(id, value)}
        onClear={() => onClear(id)}
        onOmit={() => onOmit(id)}
      />
    );
  };
  const renderItem = (item: AdvancedSettingsItem) => {
    switch (item.kind) {
      case 'parameter': return renderRow(item.id);
      case 'cluster': return <ClusterRow key={item.cluster.id} cluster={item.cluster} rowsById={rowsById} renderRow={renderRow} />;
      case 'mode': {
        const row = rowsById[item.parameterId];
        const selected = currentNumber(row);
        const note = item.description ? advancedFamilyNoteCopy(item.description) : undefined;
        return (
          <div key={`mode:${item.parameterId}`} className={styles.mode} data-advanced-row={item.parameterId}>
            {note && <p className={styles.note}>{copy(note)}</p>}
            <div className={styles.segmented} role="radiogroup">
              {item.options.map((option) => {
                const label = copy(advancedModeLabelCopy(option.label));
                return (
                  <button
                    key={option.value}
                    type="button"
                    role="radio"
                    aria-label={label}
                    aria-checked={selected === option.value}
                    disabled={isReadOnly || !(extras[item.parameterId]?.editable ?? false)}
                    onClick={() => onSet(item.parameterId, option.value)}
                  >{label}</button>
                );
              })}
            </div>
          </div>
        );
      }
    }
  };

  return (
    <div className={styles.list}>
      {sections.map((section) => {
        const isCommon = section.title === 'common';
        const footnotes = isCommon
          ? advancedCommonFootnote(rows, section.items.flatMap((item) => item.kind === 'parameter' ? [item.id] : []), engineName)
          : [];
        return (
          <section key={section.id} className={styles.section} data-advanced-section={section.title ?? section.id}>
            {section.title && <h3 className={styles.sectionTitle}>{copy(advancedSectionTitleCopy(section.title))}</h3>}
            <div className={styles.card}>{section.items.map(renderItem)}</div>
            {footnotes.length > 0 && (
              <p className={styles.footnote}>{footnotes.map((note) => copy(advancedCommonFootnoteCopy(note))).join(' ')}</p>
            )}
          </section>
        );
      })}
      <AdditionalBodySection entry={additionalBody} onOpen={onOpenAdditionalBody} />
      {showsLegend && (
        <div className={styles.legend}>
          <span><i className={styles.legendSet} aria-hidden="true" />{tc('advancedChangedInConversation')}</span>
          <span><i className={styles.legendInherited} aria-hidden="true" />{tc('advancedUsingYourDefault')}</span>
        </div>
      )}
    </div>
  );
}

/** The "write it yourself" section: the additional request body entry. The criteria come from `additionalBodyEntryRow` alone. */
export function AdditionalBodySection({ entry, onOpen }: { entry: AdditionalBodyEntryRow; onOpen: () => void }) {
  const tc = useTranslations('common');
  return (
    <section className={styles.section} data-advanced-section="writeYourOwn">
      <h3 className={styles.sectionTitle}>{tc('advancedWriteYourOwn')}</h3>
      <div className={styles.card}>
        <div className={styles.row} data-advanced-row="additional-body">
          <button type="button" className={styles.rowHead} disabled={!entry.enabled} onClick={onOpen}>
            <span className={styles.rowTitle}>
              <span className={styles.titleStack}>
                <span className={styles.titleText}>{tc('additionalBodyTitle')}</span>
                <span className={styles.subtitle}>{tc('advancedAdditionalBodySubtitle')}</span>
              </span>
            </span>
            <span className={entry.status === 'fieldsCount' ? styles.setChip : styles.unset}>
              {additionalBodyStatus(entry, tc)}
            </span>
            {entry.enabled && <ChevronRight size={14} aria-hidden="true" className={styles.chevron} />}
          </button>
        </div>
      </div>
    </section>
  );
}

function ClusterRow({ cluster, rowsById, renderRow }: {
  cluster: AdvancedSettingsCluster;
  rowsById: Readonly<Record<string, GenerationParameterRow>>;
  renderRow: (id: string) => ReactNode;
}) {
  const copy = useCopy();
  const [expanded, setExpanded] = useState(false);
  const summary = advancedClusterSummary(cluster, rowsById);
  const subtitle = cluster.subtitle ? advancedClusterSubtitleCopy(cluster.subtitle) : undefined;
  return (
    <div className={styles.cluster} data-advanced-cluster={cluster.id}>
      <button type="button" className={styles.rowHead} aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
        <span className={styles.rowTitle}>
          <span className={styles.titleStack}>
            <span className={styles.titleText}>{copy(advancedClusterTitleCopy(cluster.title))}</span>
            {subtitle && <span className={styles.subtitle}>{copy(subtitle)}</span>}
          </span>
        </span>
        <span className={summary.emphasized ? styles.setChip : styles.summary}>
          {advancedClusterSummaryCopy(summary).map((part) => copy(part)).join(' ')}
        </span>
        <ChevronRight size={14} aria-hidden="true" className={styles.chevron} data-expanded={expanded ? 'true' : undefined} />
      </button>
      {expanded && <div className={styles.members}>{cluster.memberIds.map(renderRow)}</div>}
    </div>
  );
}

function currentNumber(row: GenerationParameterRow | undefined): number | undefined {
  const value = row?.displayValue;
  if (row?.isOmitted || value?.kind !== 'text') return undefined;
  const number = Number(value.text);
  return Number.isFinite(number) ? number : undefined;
}

function additionalBodyStatus(entry: AdditionalBodyEntryRow, tc: ReturnType<typeof useTranslations>): string {
  switch (entry.status) {
    case 'notInUse': return tc('customRequestFieldsNotInUse');
    case 'fieldsCount': return entry.count === undefined ? tc('advancedStateSet') : tc('advancedFieldsCount', { count: entry.count });
  }
}
