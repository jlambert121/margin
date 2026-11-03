import { validateSpec } from './spec.mjs';
import { validateRounds } from './reviews.mjs';
import { checkHistory } from './history.mjs';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const hash = (text) => createHash('sha256').update(text).digest('hex');
const usage = 'Usage: node tools/planning/task.mjs template | init <slug> --from <file> | validate <slug> | status <slug> | prepare <slug>';

function taskPath(slug) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '')) throw new Error('Use a lowercase task slug with hyphens');
  return resolve(root, 'docs/tasks', slug);
}

export function loadTask(slug) {
  const path = taskPath(slug);
  const original = readFileSync(`${path}/original.md`, 'utf8');
  const spec = readFileSync(`${path}/spec.md`, 'utf8');
  const feedback = readFileSync(`${path}/feedback.md`, 'utf8');
  const state = JSON.parse(readFileSync(`${path}/state.json`, 'utf8'));
  if (state.version !== 1 || state.originalSha256 !== hash(original)) throw new Error('Original changed or unsupported state version');
  if (!['draft', 'critique', 'needs-input', 'incomplete', 'prepared'].includes(state.status)) throw new Error('Invalid task status');
  if (!Array.isArray(state.rounds) || state.rounds.length > 3) throw new Error('Expected at most three critique rounds');
  const originalParts = validateSpec(original);
  const parts = validateSpec(spec);
  if (parts.get('Original intent') !== originalParts.get('Original intent')) throw new Error('Spec changed the original intent');
  validateRounds(state.rounds, feedback);
  checkHistory(path, state, feedback);
  if (state.status === 'prepared' && state.preparedSpecSha256 !== hash(spec)) throw new Error('Prepared spec changed; review and prepare it again');
  return { slug, path, original, spec, parts, state };
}

export function checkReady(task) {
  const { state, parts } = task;
  if (!state.rounds.length) throw new Error('At least one fresh critique round is required');
  if (state.rounds.some((round) => round.findings.some((finding) => ['open', 'awaiting-user'].includes(finding.status)))) throw new Error('Resolve all findings before preparation');
  if (parts.get('Open decisions').toLowerCase() !== 'none') throw new Error('Resolve Open decisions and write None');
  if (state.controllerManaged && (!state.convergenceRound || !state.finalReviewPassed || state.finalReviewSpecSha256 !== hash(task.spec))) throw new Error('Controller convergence and final review of this exact spec are required');
  if (!state.finalReview?.trim()) throw new Error('Record a final consistency review in finalReview');
  if (state.status === 'needs-input' || state.status === 'incomplete') throw new Error('Resolve the stopped task and set status to critique before preparation');
}

function main() {
  const [command, slug, flag, source, ...extra] = process.argv.slice(2);
  if (command === 'template' && !slug) {
    process.stdout.write(readFileSync(`${root}/tools/planning/templates/spec.md`, 'utf8'));
    return;
  }
  if (extra.length || !['init', 'validate', 'status', 'prepare'].includes(command)) throw new Error(usage);
  const path = taskPath(slug);
  if (command === 'init') {
    if (flag !== '--from' || !source) throw new Error(usage);
    const original = readFileSync(resolve(source), 'utf8');
    validateSpec(original);
    mkdirSync(dirname(path), { recursive: true });
    mkdirSync(path); // Never overwrite an existing task.
    writeFileSync(`${path}/original.md`, original);
    writeFileSync(`${path}/spec.md`, original);
    writeFileSync(`${path}/feedback.md`, '# Critique history\n\nAppend rounds and resolutions here. Preserve earlier entries.\n');
    writeFileSync(`${path}/state.json`, `${JSON.stringify({ version: 1, status: 'draft', originalSha256: hash(original), rounds: [], finalReview: '' }, null, 2)}\n`);
    console.log(`Created ${path}`);
    return;
  }
  if (flag || source) throw new Error(usage);
  // Require an explicit review transition before replacing prepared evidence.
  if (command === 'prepare') {
    const state = JSON.parse(readFileSync(`${path}/state.json`, 'utf8'));
    if (state.status === 'prepared' && state.preparedSpecSha256 !== hash(readFileSync(`${path}/spec.md`, 'utf8'))) {
      throw new Error('Set status to critique and record a new finalReview before re-preparing an edited spec');
    }
  }
  const task = loadTask(slug);
  if (command === 'prepare') {
    checkReady(task);
    task.state.status = 'prepared';
    task.state.preparedSpecSha256 = hash(task.spec);
    writeFileSync(`${path}/state.json`, `${JSON.stringify(task.state, null, 2)}\n`);
  }
  if (task.state.status === 'prepared') checkReady(task);
  if (command === 'status') {
    console.log(JSON.stringify({ status: task.state.status, rounds: task.state.rounds.length, unresolved: task.state.rounds.flatMap((round) => round.findings).filter((finding) => ['open', 'awaiting-user'].includes(finding.status)) }, null, 2));
  } else {
    console.log(`${slug}: ${task.state.status}; structural validation passed (not a judgment of spec quality)`);
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
