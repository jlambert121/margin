import { closeSync, openSync, readFileSync, realpathSync, unlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { git, assertClean } from './git.mjs';
import { assertActive, loadRun, release, save } from './artifacts.mjs';
import { start } from './start.mjs';
import { verify } from './verify.mjs';
import { recordReview, finish } from './review.mjs';

const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
const usage = 'Usage: node tools/execution/task.mjs gate | start <task> | status|resume|verify|finish <task> <run> | review <task> <run> <report.json> | stop <task> <run> <reason>';

function dispatch(command, run, argument) {
  if (command === 'resume') return console.log(JSON.stringify(run.state, null, 2));
  if (command === 'verify') {
    const result = verify(run);
    console.log(JSON.stringify(result, null, 2));
    if (result.status !== 'passed') process.exitCode = 1;
    return;
  }
  if (command === 'review') return recordReview(run, JSON.parse(readFileSync(resolve(argument), 'utf8')));
  if (command === 'finish') {
    finish(run);
    release(root, run.path);
    return;
  }
  if (command === 'stop') {
    if (!argument?.trim()) throw new Error('Provide the reason for stopping');
    run.state.status = 'incomplete';
    run.state.reason = argument;
    save(run);
    release(root, run.path);
  }
}

function main() {
  const [command, slug, id, argument, ...extra] = process.argv.slice(2);
  if (extra.length) throw new Error(usage);
  if (command === 'gate' && !slug) {
    assertClean(root);
    console.log('Working tree is clean except task artifacts, Markdown, and dotfiles.');
    return;
  }
  if (command === 'start' && slug && !id) {
    console.log(JSON.stringify(start(root, slug).state, null, 2));
    return;
  }
  if (!['status', 'resume', 'verify', 'review', 'finish', 'stop'].includes(command) || !slug || !id) throw new Error(usage);
  if (['review', 'stop'].includes(command) !== Boolean(argument)) throw new Error(usage);
  const run = loadRun(root, slug, id);
  if (command === 'status') return console.log(JSON.stringify(run.state, null, 2));
  const lock = `${run.path}/operation.lock`;
  const fd = openSync(lock, 'wx');
  try {
    if (command !== 'stop') assertActive(run);
    if (command !== 'stop' && git(run.state.worktree, 'rev-parse', '--show-toplevel').trim() !== run.state.worktree) throw new Error('Execution worktree missing or moved');
    dispatch(command, run, argument);
  } finally {
    closeSync(fd);
    unlinkSync(lock);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
