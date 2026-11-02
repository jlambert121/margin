import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { acquire, release, save, inputs } from './artifacts.mjs';
import { assertClean, assertInside, commonDirectory, digest, git, readJson, revision } from './git.mjs';

export function start(root, slug) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '')) throw new Error('Use a lowercase task slug with hyphens');
  assertClean(root);
  const task = resolve(root, 'docs/tasks', slug);
  assertInside(root, task);
  execFileSync(process.execPath, [`${root}/tools/planning/task.mjs`, 'validate', slug], { stdio: 'pipe' });
  const planning = readJson(`${task}/state.json`);
  if (planning.status !== 'prepared') throw new Error('Task must be prepared before execution');
  const id = `${new Date().toISOString().replace(/[^0-9]/g, '')}-${randomUUID().slice(0, 8)}`;
  const path = `${task}/execution/${id}`;
  const worktree = `${commonDirectory(root)}/worktrees/${id}`;
  const base = revision(root);
  acquire(root, path);
  const run = { path, state: { version: 1, slug, id, source: root, base, worktree, branch: `execute/${slug}/${id}`, status: 'implementing', inputs: {}, verifications: [], reviews: [] } };
  try {
    mkdirSync(`${path}/inputs`, { recursive: true });
    assertInside(root, path);
    for (const name of inputs) {
      const content = readFileSync(`${task}/${name}`);
      run.state.inputs[name] = digest(content);
      writeFileSync(`${path}/inputs/${name}`, content, { flag: 'wx' });
    }
    for (const name of ['logs', 'screenshots']) mkdirSync(`${path}/${name}`);
    writeFileSync(`${path}/evidence.md`, '# Acceptance evidence\n\nRecord criterion IDs, results, and links to run-local evidence.\n');
    writeFileSync(`${path}/reviews.md`, '# Review history\n');
    writeFileSync(`${path}/handoff.md`, '# Handoff\n\nExecution is not complete.\n');
    save(run);
    git(root, 'worktree', 'add', '-b', run.state.branch, worktree, run.state.base);
  } catch (error) {
    run.state.status = 'incomplete';
    run.state.reason = error.message;
    if (run.state.inputs['spec.md']) save(run);
    release(root, path);
    throw error;
  }
  return run;
}
