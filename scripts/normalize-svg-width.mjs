// Rewrite the width/height of committed SVGs so every figure in a post has the
// same display width. The viewBox is kept, so the drawing scales proportionally.
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
  const height = Math.round((target * h) / w);
  const out = svg.replace(/<svg([^>]*?)>/, (m, attrs) => {
    const cleaned = attrs
      .replace(/\swidth="[^"]*"/, "")
      .replace(/\sheight="[^"]*"/, "");
    return `<svg${cleaned} width="${target}" height="${height}">`;
  });
  writeFileSync(path, out);
  console.log(`${path}: ${target}x${height}`);
}
