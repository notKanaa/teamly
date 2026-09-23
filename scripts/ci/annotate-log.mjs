#!/usr/bin/env node
// Turns the interesting lines of a build/test log into ONE GitHub Actions error annotation.
// Job logs of a public repository need authentication to download, but annotations are public
// (check-runs API), so failures can be diagnosed without a GitHub token.
//
// Usage (in a step with `if: failure()`): node scripts/ci/annotate-log.mjs <log file> "<title>"
import { existsSync, readFileSync } from 'node:fs';

const [file, title = 'Build log'] = process.argv.slice(2);
if (!file || !existsSync(file)) {
  console.log(`annotate-log: no log at ${file}`);
  process.exit(0);
}

// Compiler diagnostics, Swift Testing / XCTest failures, crashes, xcodebuild and pgTAP failures.
const interesting = [
  /\berror:/i,
  /\bwarning: .*(deprecated|unavailable|concurrency|sendable)/i,
  /✘/,
  /recorded an issue/,
  /Expectation failed/,
  /XCTAssert|XCTFail|failed \(\d/,
  /fatal error|Fatal error|Crash|signal (SIGABRT|SIGSEGV|SIGILL)/i,
  /\*\* (BUILD|TEST|ARCHIVE) FAILED \*\*/,
  /The following build commands failed/,
  /^not ok /,
];
const seen = new Set();
const picked = [];
for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
  const line = raw.replace(/\x1b\[[0-9;]*m/g, '').trim();
  if (!line || !interesting.some((re) => re.test(line))) continue;
  // Shorten absolute paths of the runner workspace.
  const short = line.replace(/\/(Users|home)\/runner\/work\/[^/]+\/[^/]+\//g, '').replace(/\/pkg\//g, 'Packages/TeamTasksKit/');
  if (seen.has(short)) continue;
  seen.add(short);
  picked.push(short.length > 600 ? `${short.slice(0, 600)}…` : short);
  if (picked.length >= 120) break;
}
if (picked.length === 0) {
  // Nothing matched: keep the tail so the failure is still visible.
  picked.push(...readFileSync(file, 'utf8').trim().split(/\r?\n/).slice(-40));
}
const escape = (s) => s.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
const safeTitle = title.replace(/[,:\r\n%]/g, ' ');
console.log(`::error title=${safeTitle}::${escape(picked.join('\n'))}`);
