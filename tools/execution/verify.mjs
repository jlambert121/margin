import { spawnSync } from 'node:child_process';
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { assertClean, digest, git, revision } from './git.mjs';
import { save, writeJson } from './artifacts.mjs';

export function execute(command, args, options) {
  const fd = openSync(options.log, 'w');
  try {
    const result = spawnSync(command, args, { detached: process.platform !== 'win32', cwd: options.cwd, env: options.env, stdio: ['ignore', fd, fd], timeout: 600000 });
    if (result.error?.code === 'ETIMEDOUT' && result.pid && process.platform !== 'win32') {
      try { process.kill(-result.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    return { command: [command, ...args], code: result.status, error: result.error?.message ?? null, signal: result.signal };
  } finally {
    closeSync(fd);
  }
}

function commands(root, base) {
  const changed = git(root, 'diff', '--name-only', '-z', '--diff-filter=ACMR', base, 'HEAD').split('\0').filter(Boolean);
  const steps = [];
  if (changed.length) steps.push(['format', 'mise', ['exec', '--', 'qlty', 'fmt', ...changed]]);
  steps.push(
    ['tests', 'npm', ['test']],
    ['native-ui', 'npm', ['run', 'test:native']],
    ['build', 'npm', ['run', 'build']],
    ['smells', 'mise', ['exec', '--', 'qlty', 'smells', '--all']],
    ['check', 'mise', ['exec', '--', 'qlty', 'check', '--all']],
  );
  return steps;
}

function runSteps(run, attempt, runner, results) {
  const directory = `${run.path}/logs/verification-${attempt}`;
  mkdirSync(directory);
  const home = `${directory}/test-home`;
  const temporary = `${directory}/tmp`;
  mkdirSync(home);
  mkdirSync(temporary);
  const env = { ...process.env, CFFIXED_USER_HOME: home, TMPDIR: `${temporary}/` };
  const screenshot = `${run.state.worktree}/build/editor-screenshot.png`;
  if (existsSync(screenshot)) unlinkSync(screenshot);
  for (const [name, command, args] of commands(run.state.worktree, run.state.base)) {
    const log = `${directory}/${name}.log`;
    const result = runner(command, args, { cwd: run.state.worktree, env, log });
    results.push({ name, ...result, log: log.slice(run.path.length + 1), sha256: digest(readFileSync(log)) });
    if (name === 'format') {
      // Formatting can change tracked source; review and commit it before testing.
      assertClean(run.state.worktree);
    }
  }
  if (existsSync(screenshot)) copyFileSync(screenshot, `${run.path}/screenshots/verification-${attempt}.png`);
  return results;
}

export function verify(run, runner = execute, lock = resolve(tmpdir(), 'margin-desktop-verification.lock')) {
  if (run.state.reviews.length >= 3) throw new Error('Three review rounds exhausted; stop this run or finish its passing review');
  assertClean(run.state.worktree);
  const current = revision(run.state.worktree);
  if (current === run.state.base) throw new Error('Commit the implementation in the execution worktree before verification');
  writeFileSync(lock, `${run.path}\n`, { flag: 'wx' });
  const attempt = run.state.verifications.length + 1;
  const result = { attempt, revision: current, status: 'running', results: [] };
  run.state.verifications.push(result);
  run.state.status = 'verifying';
  try {
    save(run);
    runSteps(run, attempt, runner, result.results);
    assertClean(run.state.worktree);
    if (revision(run.state.worktree) !== current) throw new Error('Code revision changed during verification');
    result.status = result.results.every((step) => step.code === 0 && !step.error && !step.signal) ? 'passed' : 'failed';
  } catch (error) {
    result.status = 'failed';
    result.error = error.message;
  } finally {
    unlinkSync(lock);
  }
  if (existsSync(`${run.path}/logs/verification-${attempt}`)) writeJson(`${run.path}/logs/verification-${attempt}/result.json`, result);
  run.state.status = result.status === 'passed' ? 'awaiting-review' : 'implementing';
  save(run);
  return result;
}
