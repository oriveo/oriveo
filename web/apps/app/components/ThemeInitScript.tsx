/**
 * Inline script that runs before hydration to set the theme
 * from localStorage, preventing a flash of wrong theme (FOUC).
 *
 * Key precedence: per-UID (a real account) > guest > the global legacy key.
 * Semantics: a stored light/dark value is used directly; a stored 'system' follows the OS;
 * nothing stored at all (never set) falls back to the product default, dark.
 */
export function ThemeInitScript() {
  const script = `(function(){var d=document.documentElement;try{var stored=null;try{var legacy=null,guest=null,user=null;for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i)||'';if(k==='oriveo.preferences'){legacy=k}else if(k==='oriveo.guest.preferences'){guest=k}else if(k.indexOf('oriveo.')===0&&k.slice(-12)==='.preferences'){user=k}}var key=user||guest||legacy;if(key){var t=JSON.parse(localStorage.getItem(key)).theme;if(t==='light'||t==='dark'||t==='system'){stored=t}}}catch(e){}if(stored==='light'||stored==='dark'){d.dataset.theme=stored;return}if(stored==='system'){d.dataset.theme=window.matchMedia('(prefers-color-scheme:light)').matches?'light':'dark';return}d.dataset.theme='dark'}catch(e){d.dataset.theme='dark'}})()`;

  return <script suppressHydrationWarning dangerouslySetInnerHTML={{ __html: script }} />;
}
