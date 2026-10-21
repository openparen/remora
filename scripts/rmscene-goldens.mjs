// Render .rm files with rm2agent and write <name>.svg beside each, as goldens
// for RMKit's port. usage: node scripts/rmscene-goldens.mjs <rm2agent checkout> <file.rm>...
// The rm2agent checkout must be built (npm run build).
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const [rm2agent, ...files] = process.argv.slice(2);
const { parseRm } = await import(join(rm2agent, "node_modules/rmapi-js/dist/raw.js"));
const { normalizePage } = await import(join(rm2agent, "dist/render/strokes.js"));
const { pageGeometry, portraitSize } = await import(join(rm2agent, "dist/render/geometry.js"));
const { renderSvg } = await import(join(rm2agent, "dist/render/svg.js"));

for (const file of files) {
  const page = parseRm(new Uint8Array(await readFile(file)));
  const size = portraitSize(page.version === 6 ? page.paperSize : undefined);
  const geometry = pageGeometry(size, "portrait");
  const { strokes } = normalizePage(page, geometry);
  await writeFile(file.replace(/\.rm$/, ".svg"), renderSvg(strokes, geometry));
  console.log(`${file}: ${strokes.length} strokes`);
}
