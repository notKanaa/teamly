#!/usr/bin/env node
// Renders the app icon from its source, design/app-icon.svg (a full-bleed 1024×1024 square: iOS applies its own mask),
// with headless Microsoft Edge, into:
//   App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png   (1024×1024, opaque RGB)
//   App/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png     (same image, drawn in the app, e.g. onboarding)
// Usage (Windows): node scripts/render-app-icon.mjs [path to msedge.exe]
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const edge = process.argv[2] ?? String.raw`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`;
const svg = readFileSync(path.join(root, 'design', 'app-icon.svg'), 'utf8');
const assets = path.join(root, 'App', 'Resources', 'Assets.xcassets');
const iconPath = path.join(assets, 'AppIcon.appiconset', 'AppIcon.png');
const logoPath = path.join(assets, 'AppLogo.imageset', 'AppLogo.png');

const work = mkdtempSync(path.join(os.tmpdir(), 'app-icon-'));
try {
  const page = path.join(work, 'icon.html');
  writeFileSync(page, `<!doctype html><html><head><style>html,body{margin:0;padding:0;overflow:hidden}svg{display:block}</style></head><body>${svg}</body></html>`);
  const result = spawnSync(edge, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--window-size=1024,1024', `--screenshot=${iconPath}`, pathToFileURL(page).href,
  ], { stdio: 'inherit', timeout: 60_000 });
  if (result.status !== 0) {
    console.error(`Edge failed (${result.error?.message ?? `exit ${result.status}`}). Pass the path to msedge.exe.`);
    process.exit(1);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

// Sanity check: a 1024×1024 PNG without alpha (color type 2), as the App Store icon requires.
const png = readFileSync(iconPath);
const [width, height, colorType] = [png.readUInt32BE(16), png.readUInt32BE(20), png[25]];
if (width !== 1024 || height !== 1024 || colorType !== 2) {
  console.error(`Unexpected icon: ${width}×${height}, PNG color type ${colorType} (expected 1024×1024, type 2).`);
  process.exit(1);
}
copyFileSync(iconPath, logoPath);
console.log(`Wrote ${path.relative(root, iconPath)} and ${path.relative(root, logoPath)}`);
