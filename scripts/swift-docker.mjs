#!/usr/bin/env node
// Runs `swift test` for Packages/TeamTasksKit inside the official Linux Swift image, so the
// package (everything except the SwiftUI views) can be built and tested on Windows.
//
// Usage:
//   node scripts/swift-docker.mjs unit [extra swift test args]   unit tests only (integration tests skip themselves)
//   node scripts/swift-docker.mjs it   [extra swift test args]   + integration tests against the local Supabase
//                                                                (run `npx supabase start` first)
//   node scripts/swift-docker.mjs shell                            interactive shell in the container
//
// Env:
//   SWIFT_IMAGE          image (default swift:6.3-noble)
//   SWIFT_BUILD_VOLUME   named Docker volume holding .build (default equipe-swift-build). Use a distinct
//                        value per concurrent run to avoid SwiftPM lock conflicts.
//   SWIFT_BUILD_BIND     host directory to use for .build instead of a named volume (CI caching).
//   SWIFT_JOBS           parallel compile jobs (default 2 locally, unlimited on CI). The Docker VM of an 8 GB
//                        machine runs out of memory when swiftc uses every core next to the Supabase stack.
//   CI                   when set, uses --network host and 127.0.0.1 (GitHub Actions ubuntu runner).
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { localEnv } from './local-env.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = path.join(root, 'Packages', 'TeamTasksKit');
const image = process.env.SWIFT_IMAGE ?? 'swift:6.3-noble';
const buildVolume = process.env.SWIFT_BUILD_VOLUME ?? 'equipe-swift-build';
const [mode = 'unit', ...extra] = process.argv.slice(2);

if (!['unit', 'it', 'shell'].includes(mode)) {
  console.error(`Unknown mode "${mode}". Use unit | it | shell.`);
  process.exit(2);
}

const isCI = Boolean(process.env.CI);
const defaultVolume = 'equipe-swift-build';

// A new per-run volume is seeded from the default (warm) volume so dependencies are not rebuilt from scratch.
// Paths inside .build are absolute (/pkg/.build) and identical in every container, so a copy is valid.
if (!process.env.SWIFT_BUILD_BIND && buildVolume !== defaultVolume) {
  const exists = spawnSync('docker', ['volume', 'inspect', buildVolume], { stdio: 'ignore' }).status === 0;
  const warm = spawnSync('docker', ['volume', 'inspect', defaultVolume], { stdio: 'ignore' }).status === 0;
  if (!exists && warm) {
    console.log(`> seeding volume ${buildVolume} from ${defaultVolume}`);
    spawnSync('docker', ['run', '--rm', '-v', `${defaultVolume}:/from:ro`, '-v', `${buildVolume}:/to`, image, 'cp', '-a', '/from/.', '/to/'], {
      stdio: 'inherit',
    });
  }
}

const args = ['run', '--rm'];
if (mode === 'shell') args.push('-it');
// Bind-mount sources; keep .build in a named volume (fast, and never pollutes the Windows tree).
// SWIFT_BUILD_BIND (CI) bind-mounts a host directory instead, so actions/cache can persist it.
const buildMount = process.env.SWIFT_BUILD_BIND ? path.resolve(process.env.SWIFT_BUILD_BIND) : buildVolume;
args.push('-v', `${pkg.replaceAll('\\', '/')}:/pkg`, '-v', `${buildMount.replaceAll('\\', '/')}:/pkg/.build`, '-w', '/pkg');

if (mode === 'it') {
  const hostForContainer = isCI ? '127.0.0.1' : 'host.docker.internal';
  const env = localEnv({ hostForContainer });
  if (isCI) args.push('--network', 'host');
  else args.push('--add-host', 'host.docker.internal:host-gateway');
  args.push(
    '-e', `SUPABASE_URL=${env.apiUrl}`,
    '-e', `SUPABASE_KEY=${env.publishableKey}`,
    '-e', `MAILPIT_URL=${env.mailpitUrl}`,
    '-e', `REALTIME_IT=${process.env.REALTIME_IT ?? '1'}`,
  );
}

args.push(image);
const jobs = process.env.SWIFT_JOBS ?? (isCI ? '' : '2');
if (mode === 'shell') args.push('bash');
else args.push('swift', 'test', ...(jobs ? ['--jobs', jobs] : []), ...extra);

console.log(`> docker ${args.join(' ')}`);
const result = spawnSync('docker', args, { stdio: 'inherit' });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 1);
