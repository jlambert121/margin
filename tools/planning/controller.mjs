import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadTask } from './task.mjs';
import { appendEvent, syncHistory } from './history.mjs';
import { hash, json, locked, saveState, writeJson } from './storage.mjs';
import { askAgent } from './agent.mjs';
import { acceptCritique, acceptSynthesis, acceptFinalReview, fingerprint, unchanged } from './controller-steps.mjs';

function checkpointFor(task) {
  const file = `${task.path}/planning/controller.json`;
  if (existsSync(file)) return json(file);
  return { version: 1, phase: 'critique', round: task.state.rounds.length + 1, draftSha256: hash(task.spec) };
}
function assertSpec(task, checkpoint) {
  const expected = checkpoint.specSha256 ?? checkpoint.draftSha256;
  const pendingSynthesis = checkpoint.phase === 'synthesis' && checkpoint.result?.report.spec;
  if (hash(task.spec) !== expected && (!pendingSynthesis || hash(task.spec) !== hash(pendingSynthesis))) throw new Error('Working spec changed outside the controller; inspect the task before continuing');
}

async function response(root, task, checkpoint, ask, persist) {
  if (checkpoint.result) return checkpoint.result;
  const expected = fingerprint(task);
  const pending = ask(root, checkpoint.phase, task, checkpoint);
  persist();
  const result = await pending;
  unchanged(task, expected);
  checkpoint.result = result;
  persist();
  return result;
}

async function advance(root, slug, checkpoint, ask, persist) {
  const task = { ...loadTask(slug), slug };
  assertSpec(task, checkpoint);
  if (checkpoint.phase === 'critique' && checkpoint.round > 3) {
    saveState(task.path, { status: 'incomplete' });
    return { phase: 'incomplete', reason: 'Three critique rounds exhausted' };
  }
  console.log(`${slug}: ${checkpoint.phase}${checkpoint.phase === 'critique' ? ` round ${checkpoint.round}/3` : ''}`);
  const result = await response(root, task, checkpoint, ask, persist);
  if (checkpoint.phase === 'critique') return acceptCritique(task, result, checkpoint.round);
  if (checkpoint.phase === 'synthesis') return acceptSynthesis(task, result);
  if (checkpoint.phase === 'final-review') return acceptFinalReview(task, result);
  throw new Error(`Unknown controller phase: ${checkpoint.phase}`);
}

export async function runController(root, slug, decision, ask = askAgent) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '')) throw new Error('Invalid task slug');
  const path = `${root}/docs/tasks/${slug}`;
  if (json(`${path}/state.json`).status === 'prepared') {
    loadTask(slug);
    return { phase: 'done', message: 'Already prepared' };
  }
  return locked(path, async () => {
    syncHistory(path);
    const task = { ...loadTask(slug), slug };
    const checkpoint = checkpointFor(task);
    const persist = () => writeJson(`${task.path}/planning/controller.json`, checkpoint);
    if (checkpoint.phase === 'needs-input') {
      if (!decision?.trim()) return checkpoint;
      appendEvent(task.path, 'decision', `decision-after-round-${checkpoint.round - 1}`, { answer: decision });
      checkpoint.phase = 'critique';
      delete checkpoint.question;
    } else if (decision) throw new Error('This task is not waiting for a user decision');
    if (checkpoint.phase === 'incomplete') return checkpoint;
    saveState(task.path, { controllerManaged: true, status: 'critique' });
    try {
      while (!['done', 'needs-input', 'incomplete'].includes(checkpoint.phase)) {
        const next = await advance(root, slug, checkpoint, ask, persist);
        Object.assign(checkpoint, next);
        delete checkpoint.result;
        delete checkpoint.error;
        checkpoint.round = json(`${task.path}/state.json`).rounds.length + 1;
        persist();
      }
      return checkpoint;
    } catch (error) {
      const key = checkpoint.phase === 'critique' ? `round-${checkpoint.round}` : checkpoint.phase;
      if (!syncHistory(task.path).events.some((event) => event.key === key)) delete checkpoint.result;
      checkpoint.error = error.message;
      persist();
      saveState(task.path, { status: 'incomplete' });
      throw error;
    }
  });
}

async function main() {
  const [slug, flag, file, ...extra] = process.argv.slice(2);
  if (extra.length || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '') || (flag && (flag !== '--decision' || !file))) throw new Error('Usage: controller.mjs <task> [--decision <answer-file>]');
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const result = await runController(root, slug, file ? readFileSync(resolve(file), 'utf8') : undefined);
  console.log(JSON.stringify(result.phase === 'done' ? { phase: result.phase, message: 'Specification prepared; implementation has not started' } : { phase: result.phase, question: result.question, reason: result.reason }, null, 2));
  if (result.phase !== 'done') process.exitCode = 1;
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
