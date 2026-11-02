import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { start } from '../tools/execution/start.mjs';
import { assertActive, release } from '../tools/execution/artifacts.mjs';
import { assertClean, commonDirectory, git, revision } from '../tools/execution/git.mjs';
import { execute, verify as verifyRun } from '../tools/execution/verify.mjs';

const verificationLock = (run) => `${commonDirectory(run.state.source)}/desktop-test.lock`;
const verify = (run, runner) => verifyRun(run, runner, verificationLock(run));
import { recordReview, finish } from '../tools/execution/review.mjs';

const draft = `# Preserve text
## Original intent
Preserve text when switching documents.
## Proposed behavior
Switching retains text.
## Non-goals
Changing persistence.
## Acceptance criteria
- AC-1: Switching preserves unsaved text.
## Validation
- AC-1: Native test; switch away and back; assert identical text.
## Code references and assumptions
source.txt represents implementation in this test repository.
## Open decisions
None
`;

function fixture(t) {
  const root = realpathSync(mkdtempSync(resolve(tmpdir(), 'margin-execution-')));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(`${root}/tools`);
  cpSync('tools/planning', `${root}/tools/planning`, { recursive: true });
  cpSync('tools/execution', `${root}/tools/execution`, { recursive: true });
  writeFileSync(`${root}/source.txt`, 'initial\n');
  writeFileSync(`${root}/.gitignore`, 'build/\n');
  git(root, 'init', '-q');
  git(root, 'config', 'commit.gpgsign', 'false');
  git(root, 'config', 'user.name', 'Execution Tests');
  git(root, 'config', 'user.email', 'execution@example.invalid');
  git(root, 'add', '.');
  git(root, 'commit', '-qm', 'Fixture base');
  writeFileSync(`${root}/draft.md`, draft);
  const planning = (...args) => execFileSync(process.execPath, [`${root}/tools/planning/task.mjs`, ...args], { stdio: 'pipe' });
  planning('init', 'example', '--from', `${root}/draft.md`);
  rmSync(`${root}/draft.md`);
  const task = `${root}/docs/tasks/example`;
  const state = JSON.parse(readFileSync(`${task}/state.json`));
  state.rounds = [{ number: 1, reviewer: 'Fresh reviewer', summary: 'No findings', findings: [] }];
  state.finalReview = 'Criteria and validation match intent.';
  writeFileSync(`${task}/feedback.md`, '## Round 1\nNo findings.\n');
  writeFileSync(`${task}/state.json`, JSON.stringify(state));
  planning('prepare', 'example');
  const cli = (...args) => spawnSync(process.execPath, [`${root}/tools/execution/task.mjs`, ...args], { encoding: 'utf8' });
  return { root, task, cli };
}

function implement(run, text = 'implemented\n') {
  writeFileSync(`${run.state.worktree}/source.txt`, text);
  git(run.state.worktree, 'add', 'source.txt');
  git(run.state.worktree, 'commit', '-qm', 'Implement fixture behavior');
}

function successful(command, args, options) {
  assert.ok(options.env.CFFIXED_USER_HOME.endsWith('/test-home'));
  assert.ok(options.env.TMPDIR.endsWith('/tmp/'));
  assert.ok(existsSync(options.env.CFFIXED_USER_HOME));
  writeFileSync(options.log, `${command} ${args.join(' ')} passed\n`);
  return { command: [command, ...args], code: 0, error: null, signal: null };
}

function report(run, overrides = {}) {
  return {
    revision: revision(run.state.worktree), reviewer: 'Independent fixture reviewer', summary: 'Verified behavior and original intent.', verdict: 'pass', findings: [], resolutions: [],
    criteria: [{ id: 'AC-1', result: 'passed', summary: 'Observed fixture behavior; fake commands are test-only.', evidence: ['logs/verification-1/tests.log'] }],
    ...overrides,
  };
}

test('gate allows task artifacts but rejects tracked, untracked, and renamed source paths', (t) => {
  const f = fixture(t);
  assert.doesNotThrow(() => assertClean(f.root));
  writeFileSync(`${f.root}/new file\n.txt`, 'untracked');
  assert.throws(() => assertClean(f.root), /blocking changes/);
  rmSync(`${f.root}/new file\n.txt`);
  git(f.root, 'mv', 'source.txt', 'docs/tasks/example/moved.txt');
  assert.throws(() => assertClean(f.root), /source.txt/);
  assert.notEqual(f.cli('start', 'example').status, 0);
  assert.equal(existsSync(`${commonDirectory(f.root)}/active.json`), false);
});

test('start snapshots uncommitted prepared inputs, isolates code, and enforces one active run', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  assert.equal(readFileSync(`${run.path}/inputs/spec.md`, 'utf8'), draft);
  assert.equal(readFileSync(`${run.state.worktree}/source.txt`, 'utf8'), 'initial\n');
  assert.throws(() => start(f.root, 'example'), /Another execution/);
  assert.doesNotThrow(() => assertActive(run));
  writeFileSync(`${f.root}/source.txt`, 'unexpected');
  assert.throws(() => assertActive(run), /blocking changes/);
  writeFileSync(`${f.root}/source.txt`, 'initial\n');
  writeFileSync(`${f.task}/spec.md`, `${draft}\nChanged\n`);
  assert.throws(() => assertActive(run), /Planning input changed/);
  assert.equal(f.cli('stop', 'example', run.state.id, 'Inputs changed').status, 0);
  assert.equal(existsSync(`${commonDirectory(f.root)}/active.json`), false);
  assert.ok(existsSync(run.state.worktree));
});

test('verification requires committed work and records isolated sequential command results', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  assert.throws(() => verify(run, successful), /Commit the implementation/);
  implement(run);
  const result = verify(run, successful);
  assert.equal(result.status, 'passed');
  assert.deepEqual(result.results.map((step) => step.name), ['format', 'tests', 'native-ui', 'build', 'smells', 'check']);
  assert.equal(result.revision, revision(run.state.worktree));
  recordReview(run, report(run));
  writeFileSync(`${run.path}/handoff.md`, '# Handoff\nFixture behavior delivered; no workflow improvements.\n');
  assert.doesNotThrow(() => finish(run));
  assert.equal(run.state.status, 'ready-for-review');
  release(f.root, run.path);
});

test('failed commands and formatting edits cannot produce passing verification', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  const failed = verify(run, (command, args, options) => ({ ...successful(command, args, options), code: 1 }));
  assert.equal(failed.status, 'failed');
  assert.throws(() => recordReview(run, report(run)), /verification/);
  const edited = verify(run, (command, args, options) => {
    const result = successful(command, args, options);
    writeFileSync(`${run.state.worktree}/source.txt`, 'formatter edit\n');
    return result;
  });
  assert.equal(edited.status, 'failed');
  assert.equal(edited.results.length, 1);
  assert.match(edited.error, /blocking changes/);
});

test('review requires real evidence paths, complete criteria, and the verified revision', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  verify(run, successful);
  assert.throws(() => recordReview(run, report(run, { revision: run.state.base })), /revision/);
  assert.throws(() => recordReview(run, report(run, { criteria: [] })), /every acceptance/);
  const unavailable = [{ id: 'AC-1', result: 'unavailable', summary: 'Desktop missing', evidence: ['logs/verification-1/tests.log'] }];
  assert.throws(() => recordReview(run, report(run, { criteria: unavailable })), /all criteria passed/);
  const escaped = [{ ...unavailable[0], result: 'passed', evidence: ['../../spec.md'] }];
  assert.throws(() => recordReview(run, report(run, { criteria: escaped })), /escapes/);
  const missing = [{ ...unavailable[0], result: 'passed', evidence: ['missing.png'] }];
  assert.throws(() => recordReview(run, report(run, { criteria: missing })), /ENOENT/);
  implement(run, 'later code\n');
  assert.throws(() => recordReview(run, report(run)), /exact committed revision/);
  verify(run, successful);
  assert.throws(() => recordReview(run, report(run)), /another code revision/);
});

test('three unresolved review rounds cannot finish or create a fourth round', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  verify(run, successful);
  recordReview(run, report(run, { verdict: 'changes-requested', findings: [{ id: 'F-1', severity: 'blocking', summary: 'Missing behavior', evidence: 'Observed failure in fixture.' }] }));
  assert.throws(() => recordReview(run, report(run)), /all findings resolved/);
  for (let round = 2; round <= 3; round += 1) recordReview(run, report(run, { verdict: 'changes-requested' }));
  assert.throws(() => recordReview(run, report(run)), /Three review rounds exhausted/);
  assert.throws(() => finish(run), /passing review/);
});

test('resolved findings can pass but edited logs or review files invalidate completion', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  verify(run, successful);
  recordReview(run, report(run, { verdict: 'changes-requested', findings: [{ id: 'F-1', severity: 'minor', summary: 'Missing explanation', evidence: 'Fixture output is ambiguous.' }] }));
  recordReview(run, report(run, { resolutions: [{ id: 'F-1', summary: 'Confirmed existing output matches intended behavior.' }] }));
  writeFileSync(`${run.path}/handoff.md`, '# Handoff\nCompleted fixture task.\n');
  writeFileSync(`${run.path}/logs/verification-1/tests.log`, 'altered evidence');
  assert.throws(() => finish(run), /evidence changed|log changed/);
  writeFileSync(`${run.path}/review-2.json`, '{}');
  assert.throws(() => finish(run), /review changed/);
});

test('desktop lock prevents concurrent validation without consuming an attempt', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  const lock = verificationLock(run);
  writeFileSync(lock, 'another desktop validation\n', { flag: 'wx' });
  try {
    assert.throws(() => verify(run, successful), /EEXIST/);
    assert.equal(run.state.verifications.length, 0);
  } finally {
    rmSync(lock);
  }
  assert.equal(run.state.status, 'implementing');
});


test('command runner logs actual process output and preserves nonzero exit status', (t) => {
  const root = realpathSync(mkdtempSync(resolve(tmpdir(), 'margin-execution-process-')));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const log = `${root}/command.log`;
  const result = execute(process.execPath, ['-e', "console.log('observed output'); process.exitCode = 7"], { cwd: root, env: process.env, log });
  assert.equal(result.code, 7);
  assert.match(readFileSync(log, 'utf8'), /observed output/);
});

test('interrupted verification attempts retain logs and use a new attempt on retry', (t) => {
  const f = fixture(t);
  const run = start(f.root, 'example');
  implement(run);
  run.state.verifications.push({ attempt: 1, revision: revision(run.state.worktree), status: 'running', results: [] });
  mkdirSync(`${run.path}/logs/verification-1`);
  writeFileSync(`${run.path}/logs/verification-1/partial.log`, 'interrupted attempt');
  const result = verify(run, successful);
  assert.equal(result.attempt, 2);
  assert.equal(result.status, 'passed');
  assert.equal(readFileSync(`${run.path}/logs/verification-1/partial.log`, 'utf8'), 'interrupted attempt');
});


test('gate excludes Markdown and dotfile changes in all Git states', (t) => {
  const f = fixture(t);
  mkdirSync(`${f.root}/docs/guides`, { recursive: true });
  mkdirSync(`${f.root}/.config`);
  writeFileSync(`${f.root}/README.md`, 'original docs');
  writeFileSync(`${f.root}/docs/guides/start.MARKDOWN`, 'original guide');
  writeFileSync(`${f.root}/.config/settings.json`, '{}');
  writeFileSync(`${f.root}/.envrc`, 'original config');
  git(f.root, 'add', 'README.md', 'docs/guides/start.MARKDOWN', '.config/settings.json', '.envrc');
  git(f.root, 'commit', '-qm', 'Track documentation and dotfiles');
  git(f.root, 'mv', 'README.md', 'RENAMED.md');
  rmSync(`${f.root}/docs/guides/start.MARKDOWN`);
  writeFileSync(`${f.root}/.config/settings.json`, '{"changed":true}');
  writeFileSync(`${f.root}/.envrc`, 'changed config');
  git(f.root, 'add', '.envrc');
  writeFileSync(`${f.root}/docs/new.MDX`, 'untracked Markdown');
  writeFileSync(`${f.root}/docs/.local.json`, '{}');
  mkdirSync(`${f.root}/.agents`);
  writeFileSync(`${f.root}/.agents/helper.js`, 'untracked dot-directory file');
  assert.doesNotThrow(() => assertClean(f.root));
  assert.equal(f.cli('gate').status, 0);
  git(f.root, 'mv', 'source.txt', '.config/hidden.txt');
  assert.throws(() => assertClean(f.root), /source.txt/);
});
