import nextPlugin from "@next/eslint-plugin-next";
import reactHooks from "eslint-plugin-react-hooks";
import tseslint from "typescript-eslint";

const nextCoreWebVitals = nextPlugin.configs["core-web-vitals"];

export default tseslint.config(
  {
    ignores: [
      "**/node_modules/**",
      "**/.next/**",
      "**/.next-dev/**",
      "**/dist/**",
      "**/__tests__/**",
      "**/*.test.ts",
      "**/*.test.tsx",
      "**/vitest.config.*",
    ],
  },
  {
    ...nextCoreWebVitals,
    settings: {
      next: {
        rootDir: ["apps/app/"],
      },
    },
    rules: {
      ...nextCoreWebVitals.rules,
      "@next/next/no-html-link-for-pages": "off",
    },
  },
  {
    files: ["apps/**/*.{ts,tsx}", "packages/**/*.{ts,tsx}"],
    plugins: {
      "@typescript-eslint": tseslint.plugin,
      "react-hooks": reactHooks,
    },
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/no-deprecated": "warn",
    },
  },
  {
    files: ["packages/core/src/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-globals": [
        "error",
        { name: "window", message: "Core must stay runtime-agnostic. Use an injected port." },
        { name: "document", message: "Core must not depend on the DOM." },
        { name: "localStorage", message: "Core must not depend on renderer storage." },
        { name: "sessionStorage", message: "Core must not depend on renderer storage." },
        { name: "indexedDB", message: "Core must not depend on renderer storage." },
        { name: "fetch", message: "Core must use TransportPort instead of global fetch." },
        { name: "crypto", message: "Core must use CryptoPort instead of global crypto." },
      ],
      "no-restricted-imports": [
        "error",
        {
          paths: [
            {
              name: "@oriveo/shared",
              message: "Core may only import @oriveo/shared/pure-types. The shared root can pull runtime telemetry.",
            },
            "assert",
            "buffer",
            "crypto",
            "dgram",
            "dns",
            "events",
            "fs",
            "http",
            "https",
            "module",
            "net",
            "os",
            "path",
            "perf_hooks",
            "process",
            "querystring",
            "readline",
            "stream",
            "string_decoder",
            "timers",
            "tls",
            "tty",
            "url",
            "util",
            "v8",
            "vm",
            "zlib",
            "child_process",
            "worker_threads",
            "next",
            "react",
          ],
          patterns: [
            {
              group: [
                "node:*",
                "assert/*",
                "buffer/*",
                "crypto/*",
                "dgram/*",
                "dns/*",
                "events/*",
                "fs/*",
                "http/*",
                "https/*",
                "module/*",
                "net/*",
                "os/*",
                "path/*",
                "perf_hooks/*",
                "process/*",
                "querystring/*",
                "readline/*",
                "stream/*",
                "string_decoder/*",
                "timers/*",
                "tls/*",
                "tty/*",
                "url/*",
                "util/*",
                "v8/*",
                "vm/*",
                "zlib/*",
                "child_process/*",
                "worker_threads/*",
                "next/*",
                "react/*",
                "../apps/*",
                "../../apps/*",
                "../../../apps/*",
                "../../../../apps/*",
                "**/apps/*",
              ],
            },
          ],
        },
      ],
    },
  },
);
