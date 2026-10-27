// The one helper behind `npm test`: bundle a TypeScript module of the app with esbuild (Vite's own
// bundler, already installed) and swap chosen imports for fakes — the database, mostly — so a
// test drives the real code with no browser and no network. Rendering uses react-dom/server.
import { build } from "esbuild";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "../..");
let n = 0;

/**
 * Load one bundle exporting everything from `entries` (paths relative to web/src), with `fakes`
 * keyed by what they replace: a path relative to web/src without its extension
 * ("features/board/api"), or a package name ("react-dom"). Modules in one bundle share state.
 */
export async function load(entries, fakes = {}) {
  const list = [entries].flat();
  const { outputFiles } = await build({
    stdin: { contents: list.map((e) => `export * from "./${e}";`).join("\n"), resolveDir: join(web, "src"), loader: "js" },
    bundle: true, write: false, format: "esm", platform: "node",
    jsx: "automatic", external: ["react", "react-dom/server", "react/jsx-runtime"], logLevel: "error",
    plugins: [{ name: "fakes", setup(b) {
      b.onResolve({ filter: /.*/ }, (a) => {
        const key = a.path.startsWith(".") ? relative(join(web, "src"), join(a.resolveDir, a.path)).replace(/\.[jt]sx?$/, "") : a.path;
        return key in fakes ? { path: key, namespace: "fake" } : undefined;
      });
      b.onLoad({ filter: /.*/, namespace: "fake" }, (a) => ({ contents: fakes[a.path], loader: "js" }));
    } }],
  });
  // written under web/node_modules so `import "react"` resolves against the app's own copy
  const file = join(web, "node_modules/.cache/testkit", `${list[0].replace(/\W/g, "_")}.${n++}.mjs`);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, outputFiles[0].text);
  return import(file);
}

// Fakes most component tests need: a database that refuses to be called, a portal that renders
// in place, and the one DOM object Modal reads.
export const NO_DB = `export const supabase = new Proxy({}, { get() { throw new Error("the test did not fake this query"); } });
  export const must = () => { throw new Error("the test did not fake this query"); };`;
export const PORTAL = `export const createPortal = (node) => node;`;
globalThis.document ??= { body: {}, documentElement: {} };
