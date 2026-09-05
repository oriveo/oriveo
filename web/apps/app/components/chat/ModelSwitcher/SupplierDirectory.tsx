import { useTranslations } from "next-intl";
import { VendorIdentity } from "../../VendorIdentity";
import type { ModelBrowserGroup } from "../../../app/providers/[providerId]/model-browser-groups";
import styles from "../ModelSwitcher.module.css";

interface SupplierDirectoryProps {
  catalogQuery: string;
  catalogShortcutGroups: ModelBrowserGroup[];
  selectedCatalogGroupId: string | null;
  setSelectedCatalogGroupId: (id: string | null) => void;
  selectedCatalogGroup: ModelBrowserGroup | null;
}

export function SupplierDirectory({
  catalogQuery,
  catalogShortcutGroups,
  selectedCatalogGroupId,
  setSelectedCatalogGroupId,
  selectedCatalogGroup,
}: SupplierDirectoryProps) {
  const td = useTranslations("pages.providerDetail");

  return (
    <>
      {!catalogQuery && catalogShortcutGroups.length > 0 ? (
        <div className={styles.catalogShortcutRail}>
          <button
            type="button"
            className={styles.catalogShortcutButton}
            data-active={selectedCatalogGroupId == null}
            onClick={() => setSelectedCatalogGroupId(null)}
          >
            <span className={styles.catalogShortcutAll}>{td("allShort")}</span>
            <span className={styles.catalogShortcutLabel}>
              {td("allSuppliers")}
            </span>
          </button>
          {catalogShortcutGroups.map((group) => (
            <button
              key={group.id}
              type="button"
              className={styles.catalogShortcutButton}
              data-active={selectedCatalogGroupId === group.id}
              onClick={() => setSelectedCatalogGroupId(group.id)}
            >
              <VendorIdentity groupId={group.id} title={group.title} small />
              <span className={styles.catalogShortcutLabel}>{group.title}</span>
              <span className={styles.catalogShortcutCount}>
                {group.models.length}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      {!catalogQuery && selectedCatalogGroup ? (
        <div className={styles.catalogScopeBar}>
          <span className={styles.catalogScopeCaption}>
            {td("currentSupplier")}
          </span>
          <span className={styles.catalogScopeCurrent}>
            <VendorIdentity
              groupId={selectedCatalogGroup.id}
              title={selectedCatalogGroup.title}
              small
            />
            <span>{selectedCatalogGroup.title}</span>
          </span>
          <button
            type="button"
            className={styles.catalogScopeLink}
            onClick={() => setSelectedCatalogGroupId(null)}
          >
            {td("viewAll")}
          </button>
        </div>
      ) : null}
    </>
  );
}
