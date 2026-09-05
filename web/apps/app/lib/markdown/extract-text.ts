import { isValidElement, type ReactNode } from 'react';

// Recursion depth cap: normal markdown nests shallowly, so this only defends against pathological or malicious deep nesting blowing the stack.
const MAX_EXTRACT_DEPTH = 100;

/** Extract plain text from a React children tree for clipboard copy */
export function extractText(node: ReactNode, depth = 0): string {
  if (depth > MAX_EXTRACT_DEPTH) return '';
  if (node == null || typeof node === 'boolean') return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map((child) => extractText(child, depth + 1)).join('');
  if (isValidElement(node)) {
    return extractText((node.props as { children?: ReactNode }).children, depth + 1);
  }
  // Handle HAST-like objects that rehype may produce
  if (typeof node === 'object' && node !== null) {
    const obj = node as unknown as Record<string, unknown>;
    if (typeof obj.value === 'string') return obj.value;
    if (Array.isArray(obj.children)) return (obj.children as ReactNode[]).map((child) => extractText(child, depth + 1)).join('');
  }
  return '';
}
