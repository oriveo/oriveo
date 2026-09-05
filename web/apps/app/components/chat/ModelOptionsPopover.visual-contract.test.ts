import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Geometry contract for the model options popover (source-level numeric assertions, not eyeballing).
 *
 * The popover is anchored `bottom` above the bottom of `.composer` and grows upward, so its usable
 * height is squeezed from both ends:
 *   below: the bottom padding of `.wrap` (--o-space-md on desktop, 76px + safe area on mobile)
 *          plus the popover's own bottom offset
 *   above: the TopBar headroom
 * A blind viewport percentage knows about neither end: on a short viewport (landscape phone, large
 * safe area) it pushes the top of the popover out of the viewport, and ChatView's `.view` is
 * `overflow:hidden`, so whatever is pushed out can never be scrolled back.
 *
 * Two equally important invariants:
 *   1. The popover's `bottom` offset must clear the bottom toolbar row, otherwise the panel sits on
 *      top of the send button and the chips, which is the only way the bottom of the panel can end
 *      up hidden behind the composer.
 *   2. The pinned bottom area (close bar, plus the scope upgrade row) must live outside the scroll
 *      region: once it scrolls with the content, close disappears under long content, and that is
 *      the only deterministic way out of this popover.
 */
const composerCss = readFileSync(join(process.cwd(), 'components/chat/InputComposer.module.css'), 'utf8');
const tokensCss = readFileSync(join(process.cwd(), '../../packages/ui/src/tokens/variables.css'), 'utf8');
const popoverTsx = readFileSync(join(process.cwd(), 'components/chat/ModelOptionsPopover.tsx'), 'utf8');
// The advanced settings pane renders this panel wholesale, so its scroll contract is the popover's scroll contract.
const panelCss = readFileSync(join(process.cwd(), 'components/generation/GenerationParameterPanel.module.css'), 'utf8');

const MOBILE_MEDIA = /@media\s*\(max-width:\s*767px\)\s*\{([\s\S]*?)\n\}\n/.exec(composerCss);

function ruleBody(selector: string, source: string): string {
  const match = new RegExp(`(?:^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(source);
  expect(match, `${selector} rule exists`).toBeTruthy();
  return match![1];
}

function declaration(body: string, property: string): string {
  const match = new RegExp(`(?:^|;|\\n)\\s*${property}\\s*:\\s*([^;]+)`).exec(body);
  expect(match, `declares ${property}`).toBeTruthy();
  return match![1].trim();
}

/** Split a shorthand by paren depth so `calc(76px + env(...))` stays a single part. */
function shorthandParts(value: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = '';
  for (const character of value.trim()) {
    if (character === '(') depth += 1;
    if (character === ')') depth -= 1;
    if (/\s/.test(character) && depth === 0) {
      if (current) parts.push(current);
      current = '';
      continue;
    }
    current += character;
  }
  if (current) parts.push(current);
  return parts;
}

function paddingBottom(value: string): string {
  const parts = shorthandParts(value);
  return parts.length >= 3 ? parts[2] : parts[0];
}

/**
 * Sum the pixel constants in a value and report whether it carries the bottom safe area;
 * `var(--o-space-*)` is resolved to real pixels first. `localTokens` resolves variables the CSS
 * Module declares itself (such as `--o-composer-home-lift`): they are not in the design system
 * token table, but they are just as much an indirection that has to be evaluated.
 */
function pxAndSafeArea(value: string, localTokens: Readonly<Record<string, string>> = {}): { px: number; safeArea: boolean } {
  const resolved = value.replace(/var\(\s*(--[a-zA-Z0-9-]+)[^)]*\)/g, (_, name: string) => {
    const local = localTokens[name];
    if (local !== undefined) return local;
    const token = new RegExp(`${name}\\s*:\\s*(\\d+(?:\\.\\d+)?px)`).exec(tokensCss);
    expect(token, `${name} is a pixel token`).toBeTruthy();
    return token![1];
  })
    // For `clamp(min, preferred, max)` take **max**: the reserved height has to cover the worst
    // case, and the worst case is the tallest lift (on a tall viewport 7.5vh hits the 84px upper
    // bound). Taking min would void the assertion on exactly the screens that need it.
    .replace(/clamp\(([^()]*)\)/g, (_, args: string) => args.split(',').pop()!.trim());
  const px = [...resolved.matchAll(/(\d+(?:\.\d+)?)px/g)]
    .map((match) => Number(match[1]))
    .filter((number) => number > 0)
    .reduce((sum, number) => sum + number, 0);
  // Look for the safe area on the **evaluated** string: an indirect reference such as
  // `calc(var(--o-composer-home-lift) + ...)` has no literal `env(` at all, yet it does carry the
  // safe area once substituted.
  return { px, safeArea: /env\(\s*safe-area-inset-bottom/.test(resolved) };
}

const popover = ruleBody('.modelControlsPopover', composerCss);
const popoverBottom = Number(/bottom\s*:\s*(\d+(?:\.\d+)?)px/.exec(popover)![1]);

function reservedHeight(body: string) {
  return pxAndSafeArea(declaration(body, '--o-model-options-popover-reserved'));
}

describe('model options popover geometry', () => {
  it('height ceiling follows the real available space, not a blind viewport percentage', () => {
    expect(popover, 'popover has no max-height computed from the available space').toMatch(/max-height\s*:\s*calc\(100dvh\s*-/);
    // The content area has its own overflow:auto, and only a flex column with min-height:0 lets it shrink instead of bursting the popover.
    expect(popover).toMatch(/flex-direction\s*:\s*column/);
    expect(ruleBody('.modelControlSections', composerCss)).toMatch(/min-height\s*:\s*0/);
    expect(ruleBody('.modelControlSections', composerCss)).toMatch(/overflow-y\s*:\s*auto/);
  });

  it('desktop: the reservation covers the composer footprint and leaves TopBar headroom', () => {
    const wrapBottom = pxAndSafeArea(paddingBottom(declaration(ruleBody('.wrap', composerCss), 'padding')));
    const reserved = reservedHeight(popover);
    const occupied = wrapBottom.px + popoverBottom;

    expect(reserved.px, `reserved ${reserved.px}px must be >= the ${occupied}px taken below the popover`).toBeGreaterThanOrEqual(occupied);
    // TopBar min-height 52px: without that headroom the popover covers the title bar.
    expect(reserved.px - occupied).toBeGreaterThanOrEqual(52);
  });

  it('mobile: the reservation includes the safe area and shares its source with the .wrap bottom padding', () => {
    expect(MOBILE_MEDIA, '767px breakpoint block exists').toBeTruthy();
    const mobile = MOBILE_MEDIA![1];
    const wrapBottom = pxAndSafeArea(paddingBottom(declaration(ruleBody('.wrap', mobile), 'padding')));
    const reserved = reservedHeight(ruleBody('.modelControlsPopover', mobile));

    expect(wrapBottom.safeArea, 'mobile .wrap bottom padding includes the safe area').toBe(true);
    expect(reserved.safeArea, 'the reservation must include the safe area too, otherwise devices with a large safe area push the popover out of the viewport').toBe(true);
    const occupied = wrapBottom.px + popoverBottom;
    expect(reserved.px, `reserved ${reserved.px}px must be >= the ${occupied}px taken below the popover`).toBeGreaterThanOrEqual(occupied);
    // Mobile TopBar min-height is 50px.
    expect(reserved.px - occupied).toBeGreaterThanOrEqual(50);
  });

  /**
   * In the `home` form (first screen of a new conversation) the composer does not sit on the bottom
   * edge: the whole block is lifted by `--o-composer-home-lift` (clamp(44px,7.5vh,84px) on desktop,
   * 76px + safe area on mobile). That lift is **also** space taken below the popover, and the two
   * assertions above use the bottom padding of `.wrap`, which knows nothing about this form: on
   * desktop home the padding-bottom of `.wrap` is 0 while the popover is still lifted by 84px, so
   * the reservation is short by a full 84px and the top of the popover is pushed out of `.view`
   * (overflow:hidden).
   *
   * The rule is written as "every composer form goes through the same formula" instead of naming the
   * forms one by one, so adding a third form turns this red right away rather than waiting for
   * someone to open the panel in that form.
   */
  it('every composer form reserves enough height to cover its own footprint', () => {
    const mobile = MOBILE_MEDIA![1];
    /** The lift is a variable on `.wrapHome`, and the popover has to subtract that same variable. */
    const liftValue = (source: string) => declaration(ruleBody('.wrapHome', source), '--o-composer-home-lift');
    const homeLift = (source: string) => pxAndSafeArea(liftValue(source));
    /**
     * The home reservation is `calc(var(--o-composer-home-lift) + ...)`. Desktop and mobile share
     * the same rule (the media query does not override it, and `.wrapHome .modelControlsPopover` is
     * more specific than the `.modelControlsPopover` in there), so the difference is absorbed by the
     * variable and the two cases only substitute different values.
     */
    const homeReserved = (source: string) => pxAndSafeArea(
      declaration(ruleBody('.wrapHome .modelControlsPopover', composerCss), '--o-model-options-popover-reserved'),
      { '--o-composer-home-lift': liftValue(source) },
    );

    const forms = [
      {
        name: 'desktop - docked',
        occupied: pxAndSafeArea(paddingBottom(declaration(ruleBody('.wrap', composerCss), 'padding'))),
        reserved: reservedHeight(popover),
        headroom: 52,
      },
      {
        name: 'desktop - home',
        occupied: homeLift(composerCss),
        reserved: homeReserved(composerCss),
        headroom: 52,
      },
      {
        name: 'mobile - docked',
        occupied: pxAndSafeArea(paddingBottom(declaration(ruleBody('.wrap', mobile), 'padding'))),
        reserved: reservedHeight(ruleBody('.modelControlsPopover', mobile)),
        headroom: 50,
      },
      {
        name: 'mobile - home',
        occupied: homeLift(mobile),
        reserved: homeReserved(mobile),
        headroom: 50,
      },
    ] as const;

    for (const form of forms) {
      const occupied = form.occupied.px + popoverBottom;
      expect(form.reserved.px, `${form.name}: reserved ${form.reserved.px}px < the ${occupied}px taken below`)
        .toBeGreaterThanOrEqual(occupied);
      expect(form.reserved.px - occupied, `${form.name}: TopBar headroom below ${form.headroom}px`)
        .toBeGreaterThanOrEqual(form.headroom);
      // A form whose footprint includes the safe area must reserve it too, otherwise devices with a large safe area push the popover out of the viewport.
      if (form.occupied.safeArea) expect(form.reserved.safeArea, `${form.name}: reservation is missing the safe area`).toBe(true);
    }

    // The home form has to subtract the variable itself rather than a copied clamp literal, since two copies will drift.
    expect(declaration(ruleBody('.wrapHome .modelControlsPopover', composerCss), '--o-model-options-popover-reserved'))
      .toContain('var(--o-composer-home-lift)');
    expect(declaration(ruleBody('.wrapHome', composerCss), 'bottom')).toBe('var(--o-composer-home-lift)');
  });

  /**
   * The badge pill background differs between the light and dark scales (12% vs 20%). The same 12%
   * over the dark #1B1F2A all but merges into the background, and the badge degrades into a patch of
   * colored text with no container, which is the entire reason it exists.
   */
  it('the badge pill background has separate light and dark values, and the component only references variables', () => {
    for (const tone of ['manual', 'unavailable'] as const) {
      const rule = ruleBody(`.modelControlBadge[data-tone='${tone}']`, composerCss);
      const background = declaration(rule, 'background');
      // No literal color-mix may appear in the component: the difference between the two scales has
      // to live in tokens (in production lightningcss strips the whole [data-theme] override out of a CSS Module).
      expect(background, `${tone} badge background must go through a token`).toMatch(/^var\(--o-model-control-badge-/);
      const token = /var\(\s*(--[a-zA-Z0-9-]+)/.exec(background)![1];
      const alphaOf = (source: string) => {
        const declared = new RegExp(`${token}\\s*:\\s*([^;]+);`).exec(source);
        expect(declared, `${token} is defined in this scale`).toBeTruthy();
        return Number(/(\d+(?:\.\d+)?)%/.exec(declared![1])![1]);
      };
      // Strip block comments before splitting on the theme blocks: the comments in the light block
      // mention `[data-theme='dark']`, so a plain indexOf would cut on the comment and leave the light half without a single token.
      const tokenSource = tokensCss.replace(/\/\*[\s\S]*?\*\//g, '');
      const darkStart = tokenSource.indexOf("[data-theme='dark']");
      expect(darkStart, 'dark theme block is found').toBeGreaterThan(0);
      const light = alphaOf(tokenSource.slice(0, darkStart));
      const dark = alphaOf(tokenSource.slice(darkStart));
      expect(light, `${tone} light scale`).toBe(12);
      expect(dark, `${tone} dark scale must be more opaque, otherwise the pill disappears in dark mode`).toBe(20);
    }
  });

  /**
   * The three forward chevrons (status row, advanced settings row, candidate model row) must mirror
   * in RTL. The back control has had that rule for a while and the forward chevrons did not, so on a
   * mirrored interface that `>` points back the way you came.
   */
  it('forward chevrons mirror in RTL and all three really carry that class', () => {
    expect(composerCss).toMatch(/\[dir='rtl'\]\s*\.modelControlForwardChevron\s*\{[^}]*scaleX\(-1\)/);
    // The class is really used in production; without this, the assertion above is a false green.
    const tagged = [...popoverTsx.matchAll(/<ChevronRight[^>]*className=\{styles\.modelControlForwardChevron\}/g)];
    expect(tagged.length, 'status row / advanced settings row / candidate model row all need a mirrored forward chevron').toBe(3);
    // The reverse check: no unmirrored ChevronRight should remain in the panel.
    expect([...popoverTsx.matchAll(/<ChevronRight[^>]*\/>/g)].length).toBe(3);
  });

  /**
   * Explanatory text inside the panel always uses `--o-text-secondary`.
   * `--o-text-tertiary` measures 4.397:1 on the light `--o-bg-subtle`, 0.1 short of AA. The
   * per-instance measurements live in the table in `lib/design-system/semantic-text-contrast.ts`;
   * this only pins the shape rule that tertiary may not be used as body color in the panel, so a new
   * occurrence turns red on the spot.
   */
  it('no explanatory text in the panel falls back to --o-text-tertiary', () => {
    const offenders: string[] = [];
    for (const rule of composerCss.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = rule[1].trim().replace(/\s+/g, ' ');
      if (!/\.modelControl/.test(selector)) continue;
      if (/(?:^|;)\s*color\s*:\s*var\(\s*--o-text-tertiary\b/.test(rule[2])) offenders.push(selector);
    }
    expect(offenders, `these places only reach 4.40:1 on --o-bg-subtle:\n  ${offenders.join('\n  ')}`).toEqual([]);
  });

  it('the popover bottom offset clears the bottom toolbar row, so it cannot be covered by the composer', () => {
    const desktopSend = Number(/\.sendBtn\s*\{[^}]*height:\s*(\d+)px/.exec(composerCss)![1]);
    const desktopPaddingBottom = pxAndSafeArea(paddingBottom(declaration(ruleBody('.composer', composerCss), 'padding'))).px;
    expect(popoverBottom, 'desktop: the popover bottom edge must sit above the top of the toolbar row').toBeGreaterThanOrEqual(desktopSend + desktopPaddingBottom);

    const mobile = MOBILE_MEDIA![1];
    const mobileSend = Number(/\.sendBtn,\s*\n\s*\.stopBtn\s*\{[^}]*height:\s*(\d+)px/.exec(mobile)![1]);
    const mobilePaddingBottom = pxAndSafeArea(paddingBottom(declaration(ruleBody('.composer', mobile), 'padding'))).px;
    expect(popoverBottom, 'mobile: the popover bottom edge must sit above the top of the toolbar row').toBeGreaterThanOrEqual(mobileSend + mobilePaddingBottom);
  });

  it('the pinned bottom area does not scroll, so the close bar is always reachable', () => {
    const footer = ruleBody('.modelControlsFooter', composerCss);
    expect(footer, 'the pinned bottom area must not be compressed').toMatch(/flex\s*:\s*0\s+0\s+auto/);
    // Stacked: the scope upgrade row is pinned directly above the close bar and forms one block with it.
    expect(footer).toMatch(/flex-direction\s*:\s*column/);
    expect(footer).not.toMatch(/overflow/);
  });

  it('the upgrade row and the close bar form one block: no card, a single top hairline, and it honors reduceMotion', () => {
    const row = ruleBody('.modelControlScopeUpgrade', composerCss);
    // Same divider language as the close bar; it draws no background and no radius of its own, because it is a receipt, not a card.
    expect(row).toMatch(/border-top\s*:\s*1px solid var\(--o-border\)/);
    expect(row).not.toMatch(/border-radius/);
    expect(row).not.toMatch(/background/);
    // Hit area: the whole row is at least 44px.
    expect(Number(/min-height\s*:\s*(\d+)px/.exec(row)![1])).toBeGreaterThanOrEqual(44);
    // Show/hide animation has to be zeroed under reduceMotion, same discipline as the popover entrance.
    const reduced = /@media \(prefers-reduced-motion: reduce\)\s*\{([\s\S]*?)\n\}/.exec(composerCss)![1];
    expect(reduced).toContain('.modelControlScopeUpgrade');
  });

  it('hit areas are at least 44px (pill / status row / list row)', () => {
    const minHeight = (selector: string) =>
      Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(ruleBody(selector, composerCss))![1]);
    // The pill is 36 tall visually and reaches its hit area through padding and line height; the status row and the list rows are already tall enough.
    expect(minHeight('.modelControlStatusRow')).toBeGreaterThanOrEqual(44);
    expect(minHeight('.modelControlNavigationRow')).toBeGreaterThanOrEqual(44);
    expect(minHeight('.modelControlPlaceholderRow')).toBeGreaterThanOrEqual(44);
    expect(minHeight('.modelControlCandidateRow')).toBeGreaterThanOrEqual(44);
    expect(minHeight('.modelControlPill')).toBeGreaterThanOrEqual(36);

    // The pill is 36 visually and 44 for hit testing, and the 8px in between comes entirely from the
    // negative inset on `::after`. Asserting only `min-height >= 36` is a false green: delete that
    // pseudo element and the line above still passes while the hit area quietly drops back to 36.
    // The layer that provides the hit area has to be pinned itself.
    const hitArea = ruleBody('.modelControlPill::after', composerCss);
    expect(hitArea, 'the hit area pseudo element must really render').toMatch(/content\s*:\s*''/);
    expect(hitArea).toMatch(/position\s*:\s*absolute/);
    const outset = Number(/inset-block\s*:\s*-(\d+(?:\.\d+)?)px/.exec(hitArea)![1]);
    expect(minHeight('.modelControlPill') + outset * 2).toBeGreaterThanOrEqual(44);
    // `inset-inline: 0` rather than a negative value: the hit areas of two adjacent pills must not overlap.
    expect(declaration(hitArea, 'inset-inline')).toBe('0');
  });

  /**
   * Every clickable control on the panel that is visually smaller than 44px must have its **own**
   * layer bringing the hit area up to 44.
   *
   * Asserting the visual height alone is a false green: once the layer providing the hit area is
   * gone, `min-height: 32` still passes while the hit area quietly drops back to 32. So the rule is
   * always written as "visual size + the layer providing the hit area >= 44", pinning both sides.
   */
  it('clickable controls under 44px all have a pseudo element bringing the hit area to 44', () => {
    const minHeight = (selector: string) =>
      Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(ruleBody(selector, composerCss))![1]);
    const outset = (selector: string) => {
      const body = ruleBody(selector, composerCss);
      expect(body, `${selector} hit area pseudo element must really render`).toMatch(/content\s*:\s*''/);
      expect(body).toMatch(/position\s*:\s*absolute/);
      return Number(/inset(?:-block)?\s*:\s*-(\d+(?:\.\d+)?)px/.exec(body)![1]);
    };

    // Back control: 32 visually, extended by 6 on each side to 44x44. It is the only way out of a second-level pane, so a mis-tap costs the most.
    expect(minHeight('.modelControlsBack') + outset('.modelControlsBack::after') * 2)
      .toBeGreaterThanOrEqual(44);
    // Secondary in-card actions (switch model, refetch, open protocol settings): 36 visually plus 2x4.
    expect(minHeight('.modelControlInlineAction') + outset('.modelControlInlineAction::after') * 2)
      .toBeGreaterThanOrEqual(44);
    // Scope upgrade action: 32 visually plus 2x6, exactly filling that row's own 44.
    expect(minHeight('.modelControlScopeUpgradeAction') + outset('.modelControlScopeUpgradeAction::after') * 2)
      .toBeGreaterThanOrEqual(44);

    // Always `inset-inline: 0` horizontally: these all appear in a row, and a negative horizontal outset would make neighbors overlap.
    for (const selector of ['.modelControlInlineAction::after', '.modelControlScopeUpgradeAction::after']) {
      expect(declaration(ruleBody(selector, composerCss), 'inset-inline'), `${selector} does not extend horizontally`).toBe('0');
    }
  });

  it('the web search switch keeps native semantics and a 44px hit area without exposing the native browser checkbox', () => {
    const hit = ruleBody('.modelControlSwitchHit', composerCss);
    expect(Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(hit)![1])).toBeGreaterThanOrEqual(44);
    expect(Number(/min-width\s*:\s*(\d+(?:\.\d+)?)px/.exec(hit)![1])).toBeGreaterThanOrEqual(44);
    const input = ruleBody('.modelControlSwitch', composerCss);
    expect(input).toMatch(/position\s*:\s*absolute/);
    expect(input).toMatch(/inset\s*:\s*0/);
    expect(input).toMatch(/width\s*:\s*100%/);
    expect(input).toMatch(/height\s*:\s*100%/);
    expect(input).toMatch(/opacity\s*:\s*0/);
    expect(input).not.toMatch(/accent-color/);

    const track = ruleBody('.modelControlSwitchTrack', composerCss);
    expect(track).toMatch(/width\s*:\s*44px/);
    expect(track).toMatch(/height\s*:\s*24px/);
    expect(track).toMatch(/border-radius\s*:\s*var\(--o-radius-full\)/);
    expect(ruleBody('.modelControlSwitchThumb', composerCss)).toMatch(/width\s*:\s*20px/);
    expect(ruleBody('.modelControlSwitchThumb', composerCss)).toMatch(/height\s*:\s*20px/);
    expect(ruleBody('.modelControlSwitch:checked + .modelControlSwitchTrack', composerCss))
      .toMatch(/background\s*:\s*var\(--o-primary\)/);
    expect(ruleBody('.modelControlSwitch:focus-visible + .modelControlSwitchTrack', composerCss))
      .toMatch(/0 0 0 3px/);

    // Production really uses an accessible input with a custom track and thumb, not a block of CSS nobody applies.
    expect(popoverTsx).toMatch(/<label className=\{styles\.modelControlSwitchHit\}>[\s\S]{0,240}?role="switch"/);
    expect(popoverTsx).toMatch(/<span className=\{styles\.modelControlSwitchTrack\} aria-hidden="true">/);
    expect(popoverTsx).toMatch(/<span className=\{styles\.modelControlSwitchThumb\}>/);
  });

  /**
   * The advanced settings pane may contain only **one** scroll container.
   *
   * Two nested containers each with `overflow:auto` do not know how much the other has left to
   * scroll: reaching the inner boundary freezes the whole screen and the user cannot tell which
   * layer is blocking (the same gesture over the same area works sometimes and not others). On this
   * side scrolling belongs to `.modelControlSections`, and the panel has to hand it over entirely in
   * its embedded form.
   */
  it('the advanced settings pane has a single scroll container and the embedded form gives up overflow / max-height / border / shadow', () => {
    expect(ruleBody('.modelControlSections', composerCss)).toMatch(/overflow-y\s*:\s*auto/);

    const embedded = ruleBody(".panel[data-embedded='true']", panelCss);
    expect(embedded, 'the embedded form must not bring its own scrolling').toMatch(/overflow\s*:\s*visible/);
    expect(embedded, 'the embedded form must not bring its own height ceiling').toMatch(/max-height\s*:\s*none/);
    expect(embedded, 'no second border inside the popover').toMatch(/border\s*:\s*0/);
    expect(embedded, 'no second shadow inside the popover').toMatch(/box-shadow\s*:\s*none/);

    // The standalone provider detail form is unaffected: it has no outer scroll container, so it keeps its own layer.
    expect(ruleBody('.panel', panelCss)).toMatch(/overflow\s*:\s*auto/);
    expect(ruleBody('.panel', panelCss)).toMatch(/max-height\s*:\s*min\(/);

    // Wiring: the popover really passes `embedded` when it mounts the panel. Without this line the four assertions above only test CSS nobody applies.
    const mount = /<GenerationParameterPanel[\s\S]*?\/>/.exec(popoverTsx);
    expect(mount, 'the popover mounts GenerationParameterPanel').toBeTruthy();
    expect(mount![0]).toMatch(/^\s*embedded\s*$/m);
  });

  it('pill groups wrap instead of overflowing horizontally (all six thinking levels is the narrowest case)', () => {
    expect(ruleBody('.modelControlPills', composerCss)).toMatch(/flex-wrap\s*:\s*wrap/);
  });

  it('the pinned bottom area is opaque, so scrolled content cannot show through the close bar', () => {
    // `flex: 0 0 auto` only keeps it out of the scroll, it cannot keep it opaque. Without a
    // background, long content shimmers through behind the close bar, and that bar is the only deterministic way out of this popover.
    expect(declaration(ruleBody('.modelControlsFooter', composerCss), 'background')).toContain('var(--o-');
  });

  /**
   * **Every** animation on the panel has to be zeroed out under reduceMotion.
   *
   * Naming them one by one (is the upgrade row in the reduced block) only covers the animations that
   * existed the day the assertion was written. What actually needs guarding is the next person
   * adding a slide to the pane switch or a fade to the badge, and no test would go red then. So the
   * rule is inverted: **every `.modelControl*` rule that declares animation/transition must be named
   * in the reduced block**. Adding an animation without zeroing it turns red on the spot.
   */
  it('every class on the panel that declares an animation is zeroed in the reduced-motion block', () => {
    const reducedMatch = /@media \(prefers-reduced-motion: reduce\)\s*\{([\s\S]*?)\n\}/.exec(composerCss)!;
    const reduced = reducedMatch[1];
    const outsideReduced = composerCss.slice(0, reducedMatch.index) + composerCss.slice(reducedMatch.index + reducedMatch[0].length);

    const animated = new Set<string>();
    for (const rule of outsideReduced.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      if (!/(?:^|;|\n)\s*(?:animation|transition)\s*:\s*(?!none)/.test(rule[2])) continue;
      for (const className of rule[1].match(/\.modelControl[A-Za-z0-9]*/g) ?? []) animated.add(className);
    }

    // If the scan surface collapses (selectors renamed, regex stops matching) the set is empty and the assertion is vacuously true, so pin its size first.
    expect(animated.size).toBeGreaterThanOrEqual(3);
    for (const className of animated) {
      expect(reduced, `${className} declares an animation and must be zeroed in the reduced-motion block`).toContain(className);
    }
  });

  it('neither the popover nor the composer clips its children, so the panel is not cut off by overflow', () => {
    expect(ruleBody('.wrap', composerCss)).not.toMatch(/overflow[^:]*:\s*hidden/);
    expect(ruleBody('.composer', composerCss)).not.toMatch(/overflow[^:]*:\s*hidden/);
  });

  it('disabled states change color instead of dimming the whole layer, and the levels have no disabled state at all', () => {
    // There is no such thing as a grayed-out option in this interface, so the pill should not carry a single :disabled rule.
    expect(composerCss).not.toMatch(/\.modelControlPill:disabled/);
    expect(ruleBody('.modelControlInlineAction:disabled', composerCss))
      .toMatch(/color\s*:\s*var\(--o-text-disabled-on-control\)/);
    expect(ruleBody('.modelControlInlineAction:disabled', composerCss)).not.toMatch(/opacity/);
  });
});
