import { DARK_PALETTE_IDS } from '@oriveo/shared';
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
 * Once the theme is decided, <meta name="theme-color"> is set to the light or default dark background
 * (the stylesheet may not have arrived yet, so CSS variables are not read);
 * the bg of a specific palette is filled in by useTheme after hydration.
 */
export function ThemeInitScript() {
  const script = `(function(){var d=document.documentElement;var ids=${JSON.stringify(DARK_PALETTE_IDS)};try{var stored=null;try{var legacy=null,guest=null,user=null;for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i)||'';if(k==='oriveo.preferences'){legacy=k}else if(k==='oriveo.guest.preferences'){guest=k}else if(k.indexOf('oriveo.')===0&&k.slice(-12)==='.preferences'){user=k}}var key=user||guest||legacy;if(key){var prefs=JSON.parse(localStorage.getItem(key))||{};var t=prefs.theme;if(t==='light'||t==='dark'||t==='system'){stored=t}var p=prefs.darkPalette;if(typeof p==='string'&&ids.indexOf(p)>=0){d.dataset.palette=p}}}catch(e){}if(stored==='light'||stored==='dark'){d.dataset.theme=stored;return}if(stored==='system'){d.dataset.theme=window.matchMedia('(prefers-color-scheme:light)').matches?'light':'dark';return}d.dataset.theme='dark'}catch(e){d.dataset.theme='dark'}})();(function(){try{var m=document.querySelector(${JSON.stringify(THEME_COLOR_META_SELECTOR)});if(m){m.setAttribute('content',document.documentElement.dataset.theme==='light'?${JSON.stringify(THEME_COLOR_LIGHT)}:${JSON.stringify(THEME_COLOR_DARK_DEFAULT)})}}catch(e){}})()`;

  return <script suppressHydrationWarning dangerouslySetInnerHTML={{ __html: script }} />;
}
