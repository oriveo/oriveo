import { CUSTOM_PALETTE_ID, DARK_PALETTE_IDS, DEFAULT_CUSTOM_SEED } from '@oriveo/shared';
import {
  CUSTOM_PALETTE_LIGHT_SELECTOR,
  CUSTOM_PALETTE_SELECTOR,
  CUSTOM_PALETTE_STYLE_ID,
  CUSTOM_PALETTE_VAR_NAME_PATTERN,
  CUSTOM_PALETTE_VAR_VALUE_PATTERN,
  CUSTOM_PALETTE_VARS_CACHE_KEY,
} from '../lib/theme/custom-palette-style';
import { THEME_COLOR_DARK_DEFAULT, THEME_COLOR_LIGHT, THEME_COLOR_META_SELECTOR } from '../lib/theme/theme-color';

/**
 * Inline script that runs before hydration to set the theme
 * from localStorage, preventing a flash of wrong theme (FOUC).
 *
 * Key precedence: per-UID (a real account) > guest > the global legacy key.
 * Semantics: a stored light/dark value is used directly; a stored 'system' follows the OS;
 * nothing stored at all (never set) falls back to the product default, dark.
 * data-palette is set only when darkPalette in the same preferences JSON is valid (inside DARK_PALETTE_IDS);
 * otherwise it is left unset and CSS falls back to the default dark section.
 * darkPalette = 'custom': when the seed (darkPaletteCustom uppercased if valid, else the default seed) matches
 * the seed in the localStorage cache oriveo.customPaletteVars and both the dark vars and the light lightVars
 * are present, the cached variables are written straight into a <style> holding the custom dark and light
 * sections and data-palette is set; with no cache, a mismatch, or an old cache without lightVars nothing is set,
 * the default sections apply first, and useTheme derives the palette after hydration.
 * Once the theme is decided, <meta name="theme-color"> is set to the light or default dark background
 * (the stylesheet may not have arrived yet, so CSS variables are not read);
 * a custom palette with a cache uses the cached bg; the bg of any other palette is filled in by useTheme after hydration.
 */
export function ThemeInitScript() {
  const script = `(function(){var d=document.documentElement;var bg=null;var ids=${JSON.stringify(DARK_PALETTE_IDS)};try{var stored=null;try{var legacy=null,guest=null,user=null;for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i)||'';if(k==='oriveo.preferences'){legacy=k}else if(k==='oriveo.guest.preferences'){guest=k}else if(k.indexOf('oriveo.')===0&&k.slice(-12)==='.preferences'){user=k}}var key=user||guest||legacy;if(key){var prefs=JSON.parse(localStorage.getItem(key))||{};var t=prefs.theme;if(t==='light'||t==='dark'||t==='system'){stored=t}var p=prefs.darkPalette;if(typeof p==='string'&&ids.indexOf(p)>=0){d.dataset.palette=p}else if(p===${JSON.stringify(CUSTOM_PALETTE_ID)}){var s=prefs.darkPaletteCustom;s=typeof s==='string'&&/^#[0-9A-Fa-f]{6}$/.test(s)?s.toUpperCase():${JSON.stringify(DEFAULT_CUSTOM_SEED)};var c=JSON.parse(localStorage.getItem(${JSON.stringify(CUSTOM_PALETTE_VARS_CACHE_KEY)}))||{};if(c.seed===s&&c.vars&&typeof c.vars==='object'&&c.lightVars&&typeof c.lightVars==='object'){var nr=${CUSTOM_PALETTE_VAR_NAME_PATTERN.toString()},vr=${CUSTOM_PALETTE_VAR_VALUE_PATTERN.toString()};var bd=function(o){var b='';for(var n in o){var v=o[n];if(nr.test(n)&&typeof v==='string'&&vr.test(v)){b+=n+':'+v+';'}}return b};var el=document.createElement('style');el.id=${JSON.stringify(CUSTOM_PALETTE_STYLE_ID)};el.textContent=${JSON.stringify(CUSTOM_PALETTE_SELECTOR)}+'{'+bd(c.vars)+'}'+${JSON.stringify(CUSTOM_PALETTE_LIGHT_SELECTOR)}+'{'+bd(c.lightVars)+'}';document.head.appendChild(el);d.dataset.palette=p;if(vr.test(c.vars['--o-bg']||'')){bg=c.vars['--o-bg']}}}}}catch(e){}if(stored==='light'||stored==='dark'){d.dataset.theme=stored;return}if(stored==='system'){d.dataset.theme=window.matchMedia('(prefers-color-scheme:light)').matches?'light':'dark';return}d.dataset.theme='dark'}catch(e){d.dataset.theme='dark'}finally{try{var m=document.querySelector(${JSON.stringify(THEME_COLOR_META_SELECTOR)});if(m){m.setAttribute('content',d.dataset.theme==='light'?${JSON.stringify(THEME_COLOR_LIGHT)}:(bg||${JSON.stringify(THEME_COLOR_DARK_DEFAULT)}))}}catch(e){}}})()`;

  return <script suppressHydrationWarning dangerouslySetInnerHTML={{ __html: script }} />;
}
