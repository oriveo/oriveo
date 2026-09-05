import type { SVGProps } from 'react';

/**
 * Hand-drawn bottom navigation icons, a 1:1 recreation of the matching SF Symbols, replacing lucide.
 * fill=currentColor, so the per-tab selected color from CSS drives the tint.
 *  - Home: bubble.left.and.bubble.right.fill
 *  - Providers: sparkles
 *  - Settings: slider.horizontal.3
 * Path data comes from the Android vector drawables (ic_tab_*.xml), viewBox 24x24.
 */
function TabIcon({ children, ...props }: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg" aria-hidden {...props}>
      {children}
    </svg>
  );
}

export function HomeTabIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <TabIcon {...props}>
      <path d="M 3.824,4.356 L 9.984,4.356 Q 12.672,4.356,12.672,7.044 L 12.672,11.3 Q 12.672,13.988,9.984,13.988 L 5.616,13.988 L 2.928,17.684 Q 3.04,13.988,3.824,13.988 Q 1.136,13.988,1.136,11.3 L 1.136,7.044 Q 1.136,4.356,3.824,4.356 Z" />
      <path d="M 13.624,8.164 L 20.176,8.164 Q 22.864,8.164,22.864,10.852 L 22.864,16.004 Q 22.864,18.692,20.176,18.692 L 19.616,18.692 L 21.52,22.164 Q 19.504,18.692,17.264,18.692 L 13.568,18.692 Q 10.88,18.692,10.88,16.004 L 10.88,14.716 A 3.64,3.64,0,0,0,13.624,11.3 L 13.624,8.164 Z" />
    </TabIcon>
  );
}

export function ProvidersTabIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <TabIcon {...props}>
      <path d="M 12.1,6.1 Q 13.514,11.188,19,12.5 Q 13.514,13.812,12.1,18.9 Q 10.685,13.812,5.2,12.5 Q 10.685,11.188,12.1,6.1 Z" />
      <path d="M 6.3,2.2 Q 6.915,4.664,9.3,5.3 Q 6.915,5.936,6.3,8.4 Q 5.685,5.936,3.3,5.3 Q 5.685,4.664,6.3,2.2 Z" />
      <path d="M 13.4,0.55 Q 13.779,2.1,15.25,2.5 Q 13.779,2.9,13.4,4.45 Q 13.021,2.9,11.55,2.5 Q 13.021,2.1,13.4,0.55 Z" />
    </TabIcon>
  );
}

export function SettingsTabIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <TabIcon {...props}>
      <path d="M3,4.7 L11.85,4.7 A1,1 0 0 1 11.85,6.7 L3,6.7 A1,1 0 0 1 3,4.7 Z" />
      <path d="M17.55,4.7 L21,4.7 A1,1 0 0 1 21,6.7 L17.55,6.7 A1,1 0 0 1 17.55,4.7 Z" />
      <path fillRule="evenodd" d="M11.85,5.7 A2.85,2.85 0 1 0 17.55,5.7 A2.85,2.85 0 1 0 11.85,5.7 Z M13.2,5.7 A1.5,1.5 0 1 0 16.2,5.7 A1.5,1.5 0 1 0 13.2,5.7 Z" />
      <path d="M3,11 L5.85,11 A1,1 0 0 1 5.85,13 L3,13 A1,1 0 0 1 3,11 Z" />
      <path d="M11.55,11 L21,11 A1,1 0 0 1 21,13 L11.55,13 A1,1 0 0 1 11.55,11 Z" />
      <path fillRule="evenodd" d="M5.85,12 A2.85,2.85 0 1 0 11.55,12 A2.85,2.85 0 1 0 5.85,12 Z M7.2,12 A1.5,1.5 0 1 0 10.2,12 A1.5,1.5 0 1 0 7.2,12 Z" />
      <path d="M3,17.3 L11.85,17.3 A1,1 0 0 1 11.85,19.3 L3,19.3 A1,1 0 0 1 3,17.3 Z" />
      <path d="M17.55,17.3 L21,17.3 A1,1 0 0 1 21,19.3 L17.55,19.3 A1,1 0 0 1 17.55,17.3 Z" />
      <path fillRule="evenodd" d="M11.85,18.3 A2.85,2.85 0 1 0 17.55,18.3 A2.85,2.85 0 1 0 11.85,18.3 Z M13.2,18.3 A1.5,1.5 0 1 0 16.2,18.3 A1.5,1.5 0 1 0 13.2,18.3 Z" />
    </TabIcon>
  );
}
