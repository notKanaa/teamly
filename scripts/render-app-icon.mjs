#!/usr/bin/env node
// Renders the app icons from their sources in design/ (full-bleed 1024×1024 squares: iOS applies its own mask), with
// headless Microsoft Edge, into App/Resources/Assets.xcassets:
//   B « Carte cochée », the primary icon (design/app-icon.svg):
//     AppIcon.appiconset/AppIcon.png                          (1024×1024, opaque RGB)
//     AppLogo.imageset/AppLogo.png                            (same image, drawn in the app, e.g. onboarding)
//   A « Trio » and C « Monogramme », the alternate icons of Réglages › Apparence (design/app-icon-trio.svg,
//   design/app-icon-monogramme.svg):
//     AppIconTrio.appiconset/AppIconTrio.png, AppIconMonogramme.appiconset/AppIconMonogramme.png   (1024×1024, RGB)
//   The small previews of the icon picker (180×180, drawn in the app):
//     AppIconPreviewTrio.imageset, AppIconPreviewCarte.imageset, AppIconPreviewMonogramme.imageset
// Usage (Windows): node scripts/render-app-icon.mjs [path to msedge.exe]
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const edge = process.argv[2] ?? String.raw`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`;
const assets = path.join(root, 'App', 'Resources', 'Assets.xcassets');
const previewSize = 180;

const icons = [
  { source: 'app-icon.svg', iconSet: 'AppIcon', preview: 'AppIconPreviewCarte', logo: 'AppLogo' },
  { source: 'app-icon-trio.svg', iconSet: 'AppIconTrio', preview: 'AppIconPreviewTrio' },
  { source: 'app-icon-monogramme.svg', iconSet: 'AppIconMonogramme', preview: 'AppIconPreviewMonogramme' },
];

/// The PNG's width, height and color type (2: RGB without alpha).
function pngInfo(file) {
  const png = readFileSync(file);
  return { width: png.readUInt32BE(16), height: png.readUInt32BE(20), colorType: png[25] };
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/// Edge may exit before its browser process has written the screenshot: waits until the file exists with the same
/// size twice in a row.
function waitForFile(file, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let lastSize = -1;
  while (Date.now() < deadline) {
    const size = existsSync(file) ? statSync(file).size : -1;
    if (size > 0 && size === lastSize) return true;
    lastSize = size;
    sleep(250);
  }
  return false;
}

/// Screenshots `svg` drawn at `size` × `size` CSS pixels into `output` (a `size` × `size` PNG).
function render(work, svg, size, output) {
  const page = path.join(work, `icon-${size}.html`);
  // The SVGs declare 1024×1024: drawn at `size` by CSS (their viewBox scales the drawing).
  writeFileSync(page, `<!doctype html><html><head><style>html,body{margin:0;padding:0;overflow:hidden}svg{display:block;width:${size}px;height:${size}px}</style></head><body>${svg}</body></html>`);
  rmSync(output, { force: true });
  const result = spawnSync(edge, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    `--window-size=${size},${size}`, `--screenshot=${output}`, pathToFileURL(page).href,
  ], { stdio: 'inherit', timeout: 60_000 });
  if (result.status !== 0 || !waitForFile(output)) {
    console.error(`Edge failed (${result.error?.message ?? `exit ${result.status}`}). Pass the path to msedge.exe.`);
    process.exit(1);
  }
  const { width, height, colorType } = pngInfo(output);
  // The App Store icons must be opaque RGB (PNG color type 2).
  if (width !== size || height !== size || colorType !== 2) {
    console.error(`Unexpected ${path.basename(output)}: ${width}×${height}, PNG color type ${colorType} (expected ${size}×${size}, type 2).`);
    process.exit(1);
  }
}

const work = mkdtempSync(path.join(os.tmpdir(), 'app-icon-'));
try {
  for (const icon of icons) {
    const svg = readFileSync(path.join(root, 'design', icon.source), 'utf8');
    const iconPath = path.join(assets, `${icon.iconSet}.appiconset`, `${icon.iconSet}.png`);
    const previewPath = path.join(assets, `${icon.preview}.imageset`, `${icon.preview}.png`);
    render(work, svg, 1024, iconPath);
    render(work, svg, previewSize, previewPath);
    console.log(`Wrote ${path.relative(root, iconPath)} and ${path.relative(root, previewPath)}`);
    if (icon.logo) {
      const logoPath = path.join(assets, `${icon.logo}.imageset`, `${icon.logo}.png`);
      copyFileSync(iconPath, logoPath);
      console.log(`Wrote ${path.relative(root, logoPath)}`);
    }
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
