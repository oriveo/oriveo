interface ApiKeyInputProps {
  autoCapitalize: 'off';
  autoComplete: 'off';
  autoCorrect: 'off';
  'data-1p-ignore': '';
  'data-bwignore': '';
  'data-lpignore': 'true';
  'data-secret-visibility': 'masked' | 'visible';
  name: string;
  spellCheck: false;
  type: 'password' | 'text';
}

// Masking is left to the native type=password; autocomplete=off (new-password is exactly what asks Safari for a strong-password suggestion) + the ignore markers of three password managers suppress save / autofill prompts.
export function getApiKeyInputProps(
  name: string,
  visibility: 'masked' | 'visible',
): ApiKeyInputProps {
  return {
    name,
    type: visibility === 'masked' ? 'password' : 'text',
    autoComplete: 'off',
    autoCapitalize: 'off',
    autoCorrect: 'off',
    spellCheck: false,
    'data-1p-ignore': '',
    'data-lpignore': 'true',
    'data-bwignore': '',
    'data-secret-visibility': visibility,
  };
}
