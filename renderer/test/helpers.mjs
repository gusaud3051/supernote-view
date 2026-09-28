// Shared test helpers.
//
// The representative fixtures live in a Syncthing-managed tree and are used
// strictly read-only.  Anything that needs to observe a *change* to a source
// copies a fixture into a temporary directory first.

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const HERE = dirname(fileURLToPath(import.meta.url));
export const PACKAGE_ROOT = resolve(HERE, '..');
export const CLI = join(PACKAGE_ROOT, 'bin', 'supernote-render.mjs');

// Optional private corpus: JSON mapping topology, realAnalysis and mldl to
// local paths.  Neither the corpus nor its mapping belongs in this repository.
export const FIXTURES = process.env.SUPERNOTE_TEST_FIXTURES
  ? JSON.parse(readFileSync(process.env.SUPERNOTE_TEST_FIXTURES, 'utf8')) : {};
export const fixturesAvailable = ['topology', 'realAnalysis', 'mldl']
  .every(key => typeof FIXTURES[key] === 'string');

/** Known-good values, measured against the live corpus. */
export const EXPECTED = {
  pageWidth: 1920,
  pageHeight: 2560,
  signature: 'noteSN_FILE_VER_20260016',
  equipment: 'N5',
  pageCounts: { topology: 2, realAnalysis: 5, mldl: 3 },
  titleCounts: { topology: 0, realAnalysis: 1, mldl: 0 },
  realAnalysisTitleId: 'TITLE_000102700138',
  realAnalysisTitleSize: { width: 208, height: 73 },
  /** Real Analysis page index 4 has no decodable stroke data. */
  realAnalysisRasterPageIndex: 4,
};

/**
 * Run the CLI.
 *
 * Arguments are passed as a real argv list, never through a shell, which is
 * also what the Emacs side does; a quoting bug therefore cannot hide here.
 */
export async function run(args, { expectFailure = false, cli = CLI, env = null } = {}) {
  let stdout = '';
  let stderr = '';
  let code = 0;
  try {
    const result = await execFileAsync(process.execPath, [cli, ...args], {
      maxBuffer: 64 * 1024 * 1024,
      cwd: PACKAGE_ROOT,
      env: env ? { ...process.env, ...env } : process.env,
    });
    stdout = result.stdout;
    stderr = result.stderr;
  } catch (error) {
    stdout = error.stdout ?? '';
    stderr = error.stderr ?? '';
    code = typeof error.code === 'number' ? error.code : 1;
    if (!expectFailure) {
      throw new Error(`CLI unexpectedly failed (exit ${code}): ${stderr || stdout}`);
    }
  }
  let json = null;
  let parseError = null;
  try {
    json = JSON.parse(stdout);
  } catch (error) {
    parseError = error;
  }
  return { code, stdout, stderr, json, parseError };
}

/** Make a temporary directory that is removed when the process exits. */
export function makeTempDir(prefix = 'supernote-test-') {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  process.on('exit', () => {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      // Best effort; the OS reclaims the temporary directory regardless.
    }
  });
  return dir;
}

export const sha256File = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
