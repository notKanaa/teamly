#!/usr/bin/env node
// Reads the local Supabase stack settings (`supabase status -o json`) and exposes them to other scripts.
// Usage as CLI: node scripts/local-env.mjs   → prints JSON { apiUrl, publishableKey, mailpitUrl, dbUrl }
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function pick(obj, keys) {
  for (const key of keys) if (obj[key]) return obj[key];
  return undefined;
}

/** @param {{hostForContainer?: string}} [options] replaces 127.0.0.1/localhost in URLs (for Docker containers). */
export function localEnv(options = {}) {
  let raw;
  try {
    const cli = process.env.CI ? 'supabase' : 'npx supabase';
    raw = execSync(`${cli} status -o json`, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) {
    throw new Error(`Local Supabase is not running. Start it with "npx supabase start".\n${error.stderr ?? error.message}`);
  }
  // The CLI may print notices before the JSON document.
  const status = JSON.parse(raw.slice(raw.indexOf('{')));
  const apiUrl = pick(status, ['API_URL', 'api_url']);
  const publishableKey = pick(status, ['PUBLISHABLE_KEY', 'publishable_key', 'ANON_KEY', 'anon_key']);
  const mailpitUrl = pick(status, ['MAILPIT_URL', 'INBUCKET_URL', 'mailpit_url', 'inbucket_url']) ?? 'http://127.0.0.1:54324';
  const dbUrl = pick(status, ['DB_URL', 'db_url']);
  if (!apiUrl || !publishableKey) throw new Error(`Unexpected "supabase status" output:\n${raw}`);

  const rewrite = (url) =>
    options.hostForContainer ? url.replace(/\/\/(127\.0\.0\.1|localhost)(?=[:/]|$)/, `//${options.hostForContainer}`) : url;
  return { apiUrl: rewrite(apiUrl), publishableKey, mailpitUrl: rewrite(mailpitUrl), dbUrl };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  console.log(JSON.stringify(localEnv(), null, 2));
}
