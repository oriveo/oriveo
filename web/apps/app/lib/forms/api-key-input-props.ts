interface ApiKeyInputProps {
  autoCapitalize: 'off';
  autoComplete: 'new-password';
  autoCorrect: 'off';
  'data-secret-visibility': 'masked' | 'visible';
  name: string;
  spellCheck: false;
  type: 'text';
}

export function getApiKeyInputProps(
  name: string,
  visibility: 'masked' | 'visible',
): ApiKeyInputProps {
  return {
    name,
    type: 'text',
    autoComplete: 'new-password',
    autoCapitalize: 'off',
    autoCorrect: 'off',
    spellCheck: false,
    'data-secret-visibility': visibility,
  };
}
