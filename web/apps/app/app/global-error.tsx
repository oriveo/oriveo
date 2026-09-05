'use client';

import * as Sentry from "@sentry/nextjs";
import { useEffect } from "react";
import { consumeChunkReloadAttempt, isChunkLoadError } from "../lib/sentry/ignore-browser-noise";

/**
 * Global error boundary - catches rendering errors in the root layout itself.
 * The next-intl provider is unavailable at that point, so the translations are inlined.
 */

interface GlobalErrorProps {
  error: Error & { digest?: string };
  reset: () => void;
}

// Inline translations covering every supported language
const T: Record<string, { title: string; desc: string; retry: string; home: string; detail: string }> = {
  'en':      { title: 'Something went wrong', desc: 'An unexpected error occurred. Your data is safe.', retry: 'Try Again', home: 'Go to Home', detail: 'Technical Details' },
  'zh-Hans': { title: '出了点问题', desc: '发生了意外错误，您的数据是安全的。', retry: '重试', home: '返回首页', detail: '技术详情' },
  'zh-Hant': { title: '出了點問題', desc: '發生了意外錯誤，您的資料是安全的。', retry: '重試', home: '返回首頁', detail: '技術詳情' },
  'ja':      { title: '問題が発生しました', desc: '予期しないエラーが発生しました。データは安全です。', retry: '再試行', home: 'ホームに戻る', detail: '技術的な詳細' },
  'ko':      { title: '문제가 발생했습니다', desc: '예기치 않은 오류가 발생했습니다. 데이터는 안전합니다.', retry: '다시 시도', home: '홈으로 이동', detail: '기술적 세부 정보' },
  'es':      { title: 'Algo salió mal', desc: 'Se produjo un error inesperado. Tus datos están seguros.', retry: 'Reintentar', home: 'Ir al inicio', detail: 'Detalles técnicos' },
  'fr':      { title: 'Un problème est survenu', desc: "Une erreur inattendue s'est produite. Vos données sont en sécurité.", retry: 'Réessayer', home: "Retour à l'accueil", detail: 'Détails techniques' },
  'de':      { title: 'Etwas ist schiefgelaufen', desc: 'Ein unerwarteter Fehler ist aufgetreten. Ihre Daten sind sicher.', retry: 'Erneut versuchen', home: 'Zur Startseite', detail: 'Technische Details' },
  'pt-BR':   { title: 'Algo deu errado', desc: 'Ocorreu um erro inesperado. Seus dados estão seguros.', retry: 'Tentar novamente', home: 'Ir para o início', detail: 'Detalhes técnicos' },
  'ar':      { title: 'حدث خطأ ما', desc: 'حدث خطأ غير متوقع. بياناتك في أمان.', retry: 'إعادة المحاولة', home: 'العودة للرئيسية', detail: 'التفاصيل التقنية' },
  'hi':      { title: "कुछ गलत हो गया", desc: "एक अप्रत्याशित त्रुटि हुई। आपका डेटा सुरक्षित है.", retry: "पुनः प्रयास करें", home: "घर जाओ", detail: "टेक्निकल डिटेल" },
  'id':      { title: "Ada yang tidak beres", desc: "Terjadi kesalahan yang tidak terduga. Data Anda aman.", retry: "Coba Lagi", home: "Pergi ke Rumah", detail: "Detail Teknis" },
  'vi':      { title: "Đã xảy ra lỗi", desc: "Đã xảy ra lỗi không mong muốn. Dữ liệu của bạn được an toàn.", retry: "Thử lại", home: "Về Nhà", detail: "Chi tiết kỹ thuật" },
  'th':      { title: "มีบางอย่างผิดพลาด", desc: "เกิดข้อผิดพลาดที่ไม่คาดคิด ข้อมูลของคุณปลอดภัย", retry: "ลองอีกครั้ง", home: "ไปที่หน้าแรก", detail: "รายละเอียดทางเทคนิค" },
  'tr':      { title: "Bir şeyler ters gitti", desc: "Beklenmeyen bir hata oluştu. Verileriniz güvende.", retry: "Tekrar deneyin", home: "Ana Sayfaya Git", detail: "Teknik Detaylar" },
  'ru':      { title: "Что-то пошло не так", desc: "Произошла непредвиденная ошибка. Ваши данные в безопасности.", retry: "Попробуйте еще раз", home: "Перейти домой", detail: "Технические детали" },
};

function detectLocale(): string {
  if (typeof document === 'undefined') return 'en';
  const m = document.cookie.match(/(?:^|;\s*)NEXT_LOCALE=([^;]*)/);
  if (m && m[1] !== 'system' && T[m[1]]) return m[1];
  const langs = navigator.languages || [navigator.language || 'en'];
  for (const l of langs) {
    if (T[l]) return l;
    const p = l.split('-')[0];
    if (p === 'zh') return (l.includes('TW') || l.includes('Hant') || l.includes('HK')) ? 'zh-Hant' : 'zh-Hans';
    if (p === 'pt') return 'pt-BR';
    const match = Object.keys(T).find((k) => k.startsWith(p));
    if (match) return match;
  }
  return 'en';
}

export default function GlobalError({ error, reset }: GlobalErrorProps) {
  useEffect(() => {
    // A stale chunk (an older client referencing a hash that has since been replaced) cannot be
    // rescued by reset(), which only re-renders the same broken tree; a hard reload is needed to
    // fetch fresh HTML. At most once per session, with the sessionStorage gate preventing a reload
    // loop, and a self-healed case is not reported to Sentry.
    if (typeof window !== "undefined" && isChunkLoadError(error)) {
      if (consumeChunkReloadAttempt(window.sessionStorage)) {
        window.location.reload();
        return;
      }
    }
    Sentry.captureException(error);
  }, [error]);

  // Make sure the error stays observable
  if (typeof console !== 'undefined') {
    console.error('[GlobalError]', error);
  }

  const locale = detectLocale();
  const s = T[locale] || T['en'];
  const isRTL = locale === 'ar';

  return (
    <html lang={locale} dir={isRTL ? 'rtl' : 'ltr'}>
      <body style={{
        margin: 0,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: '100vh',
        padding: 24,
        background: '#fafafa',
        color: '#111',
      }}>
        <div style={{ maxWidth: 440, textAlign: 'center' }}>
          <div style={{ marginBottom: 24 }}>
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#ef4444" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="8" x2="12" y2="12" />
              <line x1="12" y1="16" x2="12.01" y2="16" />
            </svg>
          </div>

          <h1 style={{ fontSize: 20, fontWeight: 700, margin: '0 0 8px' }}>
            {s.title}
          </h1>

          <p style={{ fontSize: 14, color: '#666', margin: '0 0 24px', lineHeight: 1.5 }}>
            {s.desc}
          </p>

          <div style={{ display: 'flex', gap: 12, justifyContent: 'center', flexWrap: 'wrap' }}>
            <button
              onClick={reset}
              style={{
                padding: '10px 24px',
                borderRadius: 8,
                border: 'none',
                background: '#8B5CF6',
                color: '#fff',
                fontSize: 14,
                fontWeight: 600,
                cursor: 'pointer',
              }}
            >
              {s.retry}
            </button>
            <a
              href="/chat"
              style={{
                padding: '10px 24px',
                borderRadius: 8,
                border: '1px solid #e5e7eb',
                background: 'transparent',
                color: '#111',
                fontSize: 14,
                fontWeight: 600,
                textDecoration: 'none',
                display: 'inline-flex',
                alignItems: 'center',
              }}
            >
              {s.home}
            </a>
          </div>

          {error.message && (
            <details style={{ marginTop: 32, textAlign: 'start' }}>
              <summary style={{ fontSize: 12, color: '#999', cursor: 'pointer' }}>
                {s.detail}
              </summary>
              <pre style={{
                marginTop: 8,
                padding: 12,
                background: '#f3f4f6',
                border: '1px solid #e5e7eb',
                borderRadius: 6,
                fontSize: 12,
                color: '#666',
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
                maxHeight: 200,
                overflow: 'auto',
              }}>
                {error.message}
                {error.digest && `\n\nDigest: ${error.digest}`}
              </pre>
            </details>
          )}
        </div>
      </body>
    </html>
  );
}
