import { mkdirSync, readFileSync, writeFileSync, renameSync, unlinkSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { assertClean, assertInside, runtimeDirectory, digest, readJson, revision } from './git.mjs';

export const inputs = ['original.md', 'spec.md', 'feedback.md', 'state.json'];
export const terminal = ['ready-for-review', 'incomplete'];
export function writeJson(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}

export function acquire(root, path) {
  const directory = runtimeDirectory(root);
  mkdirSync(directory, { recursive: true });
  const lock = `${directory}/active.json`;
  if (existsSync(lock)) {
    if (readJson(lock).path === path) return;
    throw new Error(`Another execution is active: ${readJson(lock).path}`);
  }
  writeFileSync(lock, `${JSON.stringify({ path })}\n`, { flag: 'wx' });
}

export function release(root, path) {
  const lock = `${runtimeDirectory(root)}/active.json`;
  if (existsSync(lock) && readJson(lock).path === path) unlinkSync(lock);
}

export function loadRun(root, slug, id) {
  for (const name of [slug, id]) {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name ?? '')) throw new Error('Use lowercase task and run IDs with hyphens');
  }
  const path = resolve(root, 'docs/tasks', slug, 'execution', id);
  assertInside(root, path);
  const state = readJson(`${path}/state.json`);
  if (state.version !== 1 || state.source !== root || state.slug !== slug || state.id !== id) throw new Error('Run identity mismatch');
  return { path, state };
}

export function save(run) {
  writeJson(`${run.path}/state.json`, run.state);
}

export function assertInputs(run) {
  const { state, path } = run;
  for (const name of inputs) {
    const current = readFileSync(`${state.source}/docs/tasks/${state.slug}/${name}`);
    const snapshot = readFileSync(`${path}/inputs/${name}`);
    if (digest(current) !== state.inputs[name] || digest(snapshot) !== state.inputs[name]) throw new Error(`Planning input changed: ${name}; stop and prepare a new run`);
  }
}

export function assertActive(run) {
  assertClean(run.state.source);
  assertInputs(run);
  if (revision(run.state.source) !== run.state.base) throw new Error('Source base revision changed; stop and start a new run');
  if (terminal.includes(run.state.status)) throw new Error(`Run is terminal: ${run.state.status}`);
  acquire(run.state.source, run.path);
}

export function verifiedRevision(run) {
  assertClean(run.state.worktree);
  const current = revision(run.state.worktree);
  const verification = run.state.verifications.at(-1);
  if (!verification || verification.status !== 'passed' || verification.revision !== current) throw new Error('Run verification on this exact committed revision first');
  return current;
}
