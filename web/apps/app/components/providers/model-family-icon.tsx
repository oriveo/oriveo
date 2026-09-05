'use client';

import type { LucideIcon } from 'lucide-react';
import {
  Brain,
  BrainCircuit,
  Sparkles,
  Diamond,
  Zap,
  Search,
  Leaf,
  Wind,
  MessageCircleQuestion,
  Moon,
  Hexagon,
  CircleDot,
  FunctionSquare,
  Cpu,
} from 'lucide-react';

// Shorten a raw model id or name into something readable on a hero card:
// drop the path prefix, the trailing date stamp and the version tail.
export function shortenedModelName(raw: string): string {
  let s = raw;
  const lastSlash = s.lastIndexOf('/');
  if (lastSlash >= 0) {
    s = s.slice(lastSlash + 1);
  }
  const datePatterns = [
    /[-_]\d{4}-\d{2}-\d{2}(-?(preview|exp|latest))?$/,
    /[-_]\d{8}(-?(preview|exp|latest))?$/,
    /[-_]\d{6}(-?(preview|exp|latest))?$/,
  ];
  for (const pattern of datePatterns) {
    const match = s.match(pattern);
    if (match) {
      s = s.slice(0, match.index);
      break;
    }
  }
  return s;
}

// Return a lucide icon component based on the model name prefix.
// The reasoning series (o1/o3/o4) is checked before gpt to avoid a mismatch.
export function modelFamilyIcon(modelName: string): LucideIcon {
  const lower = modelName.toLowerCase();
  if (lower.startsWith('o1') || lower.startsWith('o3') || lower.startsWith('o4')) return BrainCircuit;
  if (lower.startsWith('gpt')) return Brain;
  if (lower.startsWith('claude')) return Sparkles;
  if (lower.startsWith('gemini')) return Diamond;
  if (lower.startsWith('grok')) return Zap;
  if (lower.startsWith('deepseek')) return Search;
  if (lower.startsWith('llama')) return Leaf;
  if (lower.startsWith('mistral') || lower.startsWith('mixtral')) return Wind;
  if (lower.startsWith('qwen')) return MessageCircleQuestion;
  if (lower.startsWith('kimi') || lower.startsWith('moonshot')) return Moon;
  if (lower.startsWith('glm') || lower.startsWith('chatglm')) return Hexagon;
  if (lower.startsWith('yi-') || lower === 'yi') return CircleDot;
  if (lower.startsWith('phi')) return FunctionSquare;
  return Cpu;
}
