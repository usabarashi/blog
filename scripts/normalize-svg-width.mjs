// Rewrite the width/height of committed SVGs so a wide drawing fits the text
// column. Narrow drawings keep their natural width: stretching them to 672px
// would enlarge the 14px labels, so a figure with fewer nodes would read louder
// than the prose. The viewBox is kept, so the drawing scales proportionally.
//
// Usage: node scripts/normalize-svg-width.mjs [targetWidth]
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = "assets/images";
const target = Number(process.argv[2] ?? 672); // 42rem, the width of the text column

for (const name of readdirSync(dir).filter((f) => f.endsWith(".svg"))) {
  const path = join(dir, name);
  const svg = readFileSync(path, "utf8");
  const viewBox = svg.match(/viewBox="([-\d.]+) ([-\d.]+) ([\d.]+) ([\d.]+)"/);
  if (!viewBox) {
    console.warn(`${path}: no viewBox, skipped`);
    continue;
  }
  const [, , , w, h] = viewBox.map(Number);
  const width = Math.min(target, Math.round(w));
  const height = Math.round((width * h) / w);
  const out = svg.replace(/<svg([^>]*?)>/, (m, attrs) => {
    const cleaned = attrs
      .replace(/\swidth="[^"]*"/, "")
      .replace(/\sheight="[^"]*"/, "");
    return `<svg${cleaned} width="${width}" height="${height}">`;
  });
  writeFileSync(path, out);
  console.log(`${path}: ${width}x${height}`);
}
