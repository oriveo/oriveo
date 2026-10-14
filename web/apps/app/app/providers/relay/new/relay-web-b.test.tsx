import 'fake-indexeddb/auto';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { formatApiKeyPreview, makeRelayRequested } from '@oriveo/shared';
import { networkError, toProviderError } from '@oriveo/core/providers/errors';
import { RelaySettingsFailureCard } from '../../[providerId]/components/RelaySettingsFailureCard';
import { relayWebTemplateText } from '../../[providerId]/relay-web-search-board';
import { VendorIdentity, vendorMonogram } from '../../../../components/VendorIdentity';
import { getApiKeyInputProps } from '../../../../lib/forms/api-key-input-props';
import { RelaySetupStepTwo } from './RelaySetupStepTwo';

// Behavior / text (RL2-FAILCOPY-01 / SECRET-02 / MASK-01 / WEBTPL-01 / MONOGRAM-01 / MANUALADD-01).

const ROOT = process.cwd();
const MESSAGES_DIR = path.join(ROOT, 'messages');
const loadMessages = (locale: string) => JSON.parse(readFileSync(path.join(MESSAGES_DIR, `${locale}.json`), 'utf8')) as Record<string, unknown>;
const EN = loadMessages('en');

function lookup(messages: Record<string, unknown>, dotted: string): unknown {
  return dotted.split('.').reduce<unknown>((node, part) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[part] : undefined), messages);
}

// Real en copy: what the component receives is the sentence from the production copy resources.
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string) => {
    const value = lookup(EN, namespace ? `${namespace}.${key}` : key);
    return typeof value === 'string' ? value : key;
  },
  useLocale: () => 'en',
}));

vi.mock('../../../../lib/hooks/useIsDarkTheme', () => ({
  useIsDarkTheme: () => false,
}));

type FailKind = 'invalidKey' | 'rateLimited' | 'network' | 'upstream';

// iOS ProviderServiceError.messageKey original sentences in 16 languages (exported, verbatim).
const IOS_FAIL_COPY: Record<string, Record<FailKind, string>> = {
  "en": {
    invalidKey: "The API key could not be validated. Check the value or generate a new key.",
    rateLimited: "The provider is temporarily rate limiting this request. Please wait a moment and try again.",
    network: "The request did not complete successfully. Please check your network and try again.",
    upstream: "The provider returned an error for this request. Please retry or switch models.",
  },
  "ar": {
    invalidKey: "تعذر التحقق من مفتاح API. تحقق من القيمة أو أنشئ مفتاحًا جديدًا.",
    rateLimited: "المزود يقيّد هذا الطلب مؤقتًا. يرجى الانتظار لحظة والمحاولة مرة أخرى.",
    network: "لم يكتمل الطلب بنجاح. يرجى التحقق من الشبكة والمحاولة مرة أخرى.",
    upstream: "أعاد المزود خطأ لهذا الطلب. يرجى إعادة المحاولة أو تبديل النماذج.",
  },
  "de": {
    invalidKey: "Der API-Schlüssel konnte nicht validiert werden. Überprüfe den Wert oder erstelle einen neuen Schlüssel.",
    rateLimited: "Der Anbieter begrenzt diese Anfrage vorübergehend. Bitte warte einen Moment und versuche es erneut.",
    network: "Die Anfrage wurde nicht erfolgreich abgeschlossen. Bitte überprüfe deine Netzwerkverbindung und versuche es erneut.",
    upstream: "Der Anbieter hat einen Fehler für diese Anfrage zurückgegeben. Bitte versuche es erneut oder wechsle das Modell.",
  },
  "es": {
    invalidKey: "No se pudo validar la clave API. Verifica el valor o genera una nueva clave.",
    rateLimited: "El proveedor está limitando temporalmente esta solicitud. Espera un momento e inténtalo de nuevo.",
    network: "La solicitud no se completó correctamente. Verifica tu conexión de red e inténtalo de nuevo.",
    upstream: "El proveedor devolvió un error para esta solicitud. Reintenta o cambia de modelo.",
  },
  "fr": {
    invalidKey: "La clé API n'a pas pu être validée. Vérifiez la valeur ou générez une nouvelle clé.",
    rateLimited: "Le fournisseur limite temporairement cette requête. Veuillez patienter un instant et réessayer.",
    network: "La requête n'a pas abouti. Veuillez vérifier votre réseau et réessayer.",
    upstream: "Le fournisseur a renvoyé une erreur pour cette requête. Veuillez réessayer ou changer de modèle.",
  },
  "hi": {
    invalidKey: "API key को सत्यापित नहीं किया जा सका। मान जाँचें या नई कुंजी बनाएँ।",
    rateLimited: "प्रोवाइडर इस अनुरोध को अस्थायी रूप से सीमित कर रहा है। कृपया एक क्षण प्रतीक्षा करें और पुनः प्रयास करें।",
    network: "अनुरोध सफलतापूर्वक पूरा नहीं हुआ. कृपया अपना नेटवर्क जांचें और पुनः प्रयास करें।",
    upstream: "प्रोवाइडर ने इस अनुरोध के लिए एक त्रुटि लौटा दी। कृपया पुनः प्रयास करें या मॉडल बदलें।",
  },
  "id": {
    invalidKey: "API key tidak dapat divalidasi. Periksa nilainya atau buat kunci baru.",
    rateLimited: "Penyedia untuk sementara membatasi tarif permintaan ini. Harap tunggu sebentar dan coba lagi.",
    network: "Permintaan tidak berhasil diselesaikan. Silakan periksa jaringan Anda dan coba lagi.",
    upstream: "Penyedia mengembalikan kesalahan untuk permintaan ini. Silakan coba lagi atau ganti model.",
  },
  "ja": {
    invalidKey: "APIキーを\u691c\u8a3cできませんでした。\u5024を\u78ba\u8a8dするか、\u65b0しいキーを\u751f\u6210してください。",
    rateLimited: "プロバイダーがこのリクエストを\u4e00\u6642\u7684にレート\u5236\u9650しています。しばらく\u5f85ってから\u518d\u8a66\u884cしてください。",
    network: "リクエストが\u6b63\u5e38に\u5b8c\u4e86しませんでした。ネットワークを\u78ba\u8a8dして\u518d\u8a66\u884cしてください。",
    upstream: "プロバイダーがこのリクエストでエラーを\u8fd4しました。\u518d\u8a66\u884cするか、モデルを\u5207り\u66ffえてください。",
  },
  "ko": {
    invalidKey: "API 키를 검증할 수 없습니다. 값을 확인하거나 새 키를 생성하세요.",
    rateLimited: "제공업체가 이 요청을 일시적으로 제한하고 있습니다. 잠시 후 다시 시도하세요.",
    network: "요청이 성공적으로 완료되지 않았습니다. 네트워크를 확인하고 다시 시도하세요.",
    upstream: "제공업체가 이 요청에 대해 오류를 반환했습니다. 다시 시도하거나 모델을 변경하세요.",
  },
  "pt-BR": {
    invalidKey: "A chave da API não pôde ser validada. Verifique o valor ou gere uma nova chave.",
    rateLimited: "O provedor está limitando temporariamente esta solicitação. Aguarde um momento e tente novamente.",
    network: "A solicitação não foi concluída com sucesso. Verifique sua rede e tente novamente.",
    upstream: "O provedor retornou um erro para esta solicitação. Tente novamente ou troque de modelo.",
  },
  "ru": {
    invalidKey: "Не удалось проверить API-ключ. Проверьте значение или сгенерируйте новый ключ.",
    rateLimited: "Провайдер временно ограничивает скорость этого запроса. Пожалуйста, подождите немного и повторите попытку.",
    network: "Запрос не был выполнен успешно. Пожалуйста, проверьте свою сеть и повторите попытку.",
    upstream: "Провайдер вернул ошибку на этот запрос. Пожалуйста, повторите попытку или смените модель.",
  },
  "th": {
    invalidKey: "ไม่สามารถตรวจสอบคีย์ API ได้ ตรวจสอบค่าหรือสร้างคีย์ใหม่",
    rateLimited: "ผู้ให้บริการกำลังจำกัดอัตราคำขอนี้เป็นการชั่วคราว กรุณารอสักครู่แล้วลองอีกครั้ง",
    network: "คำขอไม่เสร็จสมบูรณ์ โปรดตรวจสอบเครือข่ายของคุณแล้วลองอีกครั้ง",
    upstream: "ผู้ให้บริการส่งคืนข้อผิดพลาดสำหรับคำขอนี้ โปรดลองอีกครั้งหรือเปลี่ยนรุ่น",
  },
  "tr": {
    invalidKey: "API anahtarı doğrulanamadı. Değeri kontrol edin veya yeni bir anahtar oluşturun.",
    rateLimited: "Sağlayıcı bu isteği geçici olarak hız sınırlıyor. Lütfen biraz bekleyip tekrar deneyin.",
    network: "İstek başarıyla tamamlanmadı. Lütfen ağınızı kontrol edip tekrar deneyin.",
    upstream: "Sağlayıcı bu istek için bir hata döndürdü. Lütfen yeniden deneyin veya modelleri değiştirin.",
  },
  "vi": {
    invalidKey: "Không thể xác thực khóa API. Kiểm tra giá trị hoặc tạo khóa mới.",
    rateLimited: "Nhà cung cấp đang tạm thời giới hạn mức độ yêu cầu này. Vui lòng đợi một lát và thử lại.",
    network: "Yêu cầu không hoàn tất thành công. Vui lòng kiểm tra mạng của bạn và thử lại.",
    upstream: "Nhà cung cấp đã trả lại lỗi cho yêu cầu này. Vui lòng thử lại hoặc chuyển đổi mô hình.",
  },
  "zh-Hans": {
    invalidKey: "API \u5bc6\u94a5\u9a8c\u8bc1\u5931\u8d25。\u8bf7\u68c0\u67e5\u5bc6\u94a5\u6216\u751f\u6210\u65b0\u5bc6\u94a5。",
    rateLimited: "\u4f9b\u5e94\u5546\u6682\u65f6\u9650\u5236\u4e86\u6b64\u8bf7\u6c42\u7684\u9891\u7387，\u8bf7\u7a0d\u5019\u518d\u8bd5。",
    network: "\u8bf7\u6c42\u672a\u6210\u529f\u5b8c\u6210。\u8bf7\u68c0\u67e5\u7f51\u7edc\u540e\u91cd\u8bd5。",
    upstream: "\u4f9b\u5e94\u5546\u5bf9\u6b64\u8bf7\u6c42\u8fd4\u56de\u4e86\u9519\u8bef。\u8bf7\u91cd\u8bd5\u6216\u5207\u6362\u6a21\u578b。",
  },
  "zh-Hant": {
    invalidKey: "API \u91d1\u9470\u9a57\u8b49\u5931\u6557。\u8acb\u6aa2\u67e5\u91d1\u9470\u6216\u7522\u751f\u65b0\u91d1\u9470。",
    rateLimited: "\u4f9b\u61c9\u5546\u66ab\u6642\u9650\u5236\u4e86\u6b64\u8acb\u6c42\u7684\u983b\u7387，\u8acb\u7a0d\u5019\u518d\u8a66。",
    network: "\u8acb\u6c42\u672a\u6210\u529f\u5b8c\u6210。\u8acb\u6aa2\u67e5\u7db2\u8def\u5f8c\u91cd\u8a66。",
    upstream: "\u4f9b\u61c9\u5546\u5c0d\u6b64\u8acb\u6c42\u50b3\u56de\u4e86\u932f\u8aa4。\u8acb\u91cd\u8a66\u6216\u5207\u63db\u6a21\u578b。",
  },
};

describe('RL2-FAILCOPY-01 failure card body = the same sentence as iOS (16 languages verbatim)', () => {
  it('errors.<kind>.message in 16 languages is verbatim identical to the iOS original', () => {
    const locales = readdirSync(MESSAGES_DIR).filter((file) => /^[a-zA-Z-]+\.json$/.test(file)).map((file) => file.slice(0, -5)).sort();
    expect(locales).toEqual(Object.keys(IOS_FAIL_COPY).sort());
    for (const locale of locales) {
      const messages = loadMessages(locale);
      for (const kind of Object.keys(IOS_FAIL_COPY[locale]!) as FailKind[]) {
        expect(lookup(messages, `errors.${kind}.message`), `${locale} ${kind}`).toBe(IOS_FAIL_COPY[locale]![kind]);
      }
    }
  });

  it.each([
    ['invalidKey', () => toProviderError(401, '{"error":{"message":"Invalid API key provided."}}', 'https://api.myrelay.dev/v1/chat/completions')],
    ['rateLimited', () => toProviderError(429, '{"error":{"message":"Too many requests"}}', 'https://api.myrelay.dev/v1/chat/completions')],
    ['upstream', () => toProviderError(502, '{"error":{"message":"Bad gateway"}}', 'https://api.myrelay.dev/v1/chat/completions')],
    ['network', () => networkError(new TypeError('Failed to fetch'))],
  ] as const)('production error object %s -> card body = iOS English sentence', (kind, make) => {
    const error = make();
    expect(error.kind).toBe(kind);
    render(
      <RelaySettingsFailureCard
        error={error}
        canSaveUnverified={false}
        apiKey=""
        connectionKeySecrets={[]}
        relayRequested={makeRelayRequested('openai_compatible')}
        showRetry
        onRetry={() => undefined}
        onSaveUnverified={() => undefined}
      />,
    );
    const card = screen.getByRole('alert');
    expect(card.querySelector('p')!.textContent).toBe(IOS_FAIL_COPY.en![kind]);
  });
});

describe('RL2-SECRET-02 key field = native password + password-manager ignore marker', () => {
  it('masked is type=password, the eye switches to type=text, other attributes unchanged', () => {
    const masked = getApiKeyInputProps('relay-api-key', 'masked');
    expect(masked).toMatchObject({
      type: 'password',
      autoComplete: 'off',
      'data-1p-ignore': '',
      'data-lpignore': 'true',
      'data-bwignore': '',
    });
    expect(getApiKeyInputProps('relay-api-key', 'visible')).toEqual({ ...masked, type: 'text', 'data-secret-visibility': 'visible' });
  });

  it('the three stylesheets no longer have a -webkit-text-security mask class', () => {
    for (const file of [
      'app/providers/new/ProviderSetup.module.css',
      'app/providers/relay/new/RelaySetup.module.css',
      'app/providers/[providerId]/components/RelayDetailBoard.module.css',
    ]) {
      const css = readFileSync(path.join(ROOT, file), 'utf8');
      expect(css, file).not.toMatch(/secretMasked|text-security/);
    }
  });
});

describe('RL2-MASK-01 mask = first 4 + U+2026 + last 4', () => {
  it('a long key uses the single-character ellipsis; <= 12 chars gives 8 dots; an empty string returns an empty string', () => {
    expect(formatApiKeyPreview('sk-relay-secret-0123456789')).toBe('sk-r…6789');
    expect(formatApiKeyPreview('1234567890abc')).toBe('1234…0abc');
    expect(formatApiKeyPreview('exactly12chr')).toBe('••••••••');
    expect(formatApiKeyPreview('')).toBe('');
  });
});

describe('RL2-WEBTPL-01 web search template = compact single-line JSON', () => {
  it('the four protocol templates verbatim', () => {
    expect(relayWebTemplateText('openai_responses')).toBe('{"tools":[{"type":"web_search"}]}');
    expect(relayWebTemplateText('openai_chat_completions')).toBe('{"web_search_options":{}}');
    expect(relayWebTemplateText('anthropic_messages')).toBe('{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}');
    expect(relayWebTemplateText('gemini_generate_content')).toBe('{"tools":[{"googleSearch":{}}]}');
  });
});

describe('RL2-MONOGRAM-01 vendor letter avatar without an icon', () => {
  it('>= 2 words take the first letters of the first two words, otherwise the first 2 characters of the first word, uppercase; no name gives AI', () => {
    expect(vendorMonogram('Other')).toBe('OT');
    // Name = localized group display name (decided): split words by Unicode letters / digits.
    expect(vendorMonogram('Sonstige')).toBe('SO');
    expect(vendorMonogram('その\u4ed6')).toBe('その');
    expect(vendorMonogram('—')).toBe('AI');
    // Take by character cluster without splitting combining marks (iOS uses Character).
    expect(vendorMonogram('अन्य')).toBe('अन्य');
    expect(vendorMonogram('อื่นๆ')).toBe('อื่น');
    expect(vendorMonogram('Totally Unknown')).toBe('TU');
    expect(vendorMonogram('my-relay vendor x')).toBe('MR');
    expect(vendorMonogram('')).toBe('AI');
    expect(vendorMonogram('  ')).toBe('AI');
  });

  it('group avatar "Other" renders OT', () => {
    render(<VendorIdentity groupId="other" title="Other" small density="compact" />);
    expect(screen.getByText('OT').parentElement?.getAttribute('data-has-logo')).toBe('false');
  });
});

describe('RL2-MANUALADD-01 step 2 manual add = dialog', () => {
  function renderStepTwo(onAddManual: (id: string) => void) {
    render(
      <RelaySetupStepTwo
        host="myrelay.dev"
        keyCount={1}
        totalCount={0}
        query=""
        onQueryChange={() => undefined}
        groups={[]}
        fullGroups={[]}
        selected={new Set()}
        isExpanded={() => false}
        onToggleGroup={() => undefined}
        onToggleModel={() => undefined}
        onSelectGroup={() => undefined}
        protocolOf={() => 'Chat'}
        keyChips={{}}
        onAddManual={onAddManual}
        onOpenAddManual={() => undefined}
        addManualHint={false}
        saving={false}
        saveFailure={null}
        onSave={() => undefined}
        onBack={() => undefined}
      />,
    );
  }

  it('title = same sentence as the button, input + Cancel / Add; an empty value disables Add; Add hands over the trimmed ID and closes; Cancel closes without adding', () => {
    const added: string[] = [];
    renderStepTwo((id) => added.push(id));
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
    const dialog = screen.getByRole('dialog', { name: 'Add model ID manually' });
    expect(within(dialog).getByRole('heading', { name: 'Add model ID manually' })).toBeTruthy();
    const input = within(dialog).getByRole('textbox') as HTMLInputElement;
    const add = within(dialog).getByRole('button', { name: 'Add' }) as HTMLButtonElement;
    expect(within(dialog).getAllByRole('button').map((button) => button.textContent)).toEqual(['Cancel', 'Add']);
    expect(add.disabled).toBe(true);
    fireEvent.change(input, { target: { value: '   ' } });
    expect(add.disabled).toBe(true);
    fireEvent.change(input, { target: { value: ' my-model ' } });
    expect(add.disabled).toBe(false);
    fireEvent.click(add);
    expect(added).toEqual(['my-model']);
    expect(screen.queryByRole('dialog')).toBeNull();

    fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
    const reopened = screen.getByRole('dialog', { name: 'Add model ID manually' });
    expect((within(reopened).getByRole('textbox') as HTMLInputElement).value).toBe('');
    fireEvent.change(within(reopened).getByRole('textbox'), { target: { value: 'other-model' } });
    fireEvent.click(within(reopened).getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(added).toEqual(['my-model']);
    // The page no longer has an inline input.
    expect(document.querySelector('form input')).toBeNull();
  });
});
