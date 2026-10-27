// Lint for mistakes, not style — Prettier owns the style.
import js from "@eslint/js";
import ts from "typescript-eslint";
import hooks from "eslint-plugin-react-hooks";
import globals from "globals";

export default ts.config(
  { ignores: ["dist", "node_modules"] },
  js.configs.recommended,
  ...ts.configs.recommended,
  {
    files: ["src/**/*.{ts,tsx}"],
    languageOptions: { globals: globals.browser },
    plugins: { "react-hooks": hooks },
    rules: {
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
      // the database's errors arrive as `any` from supabase-js; catching them as such is the norm here
      "@typescript-eslint/no-explicit-any": "off",
    },
  },
  { files: ["**/*.{js,mjs}"], languageOptions: { globals: { ...globals.node, ...globals.browser } } },
);
