import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { hash, json, locked, saveState } from './storage.mjs';
import { validateRounds } from './reviews.mjs';

function render(event) {
  const title = event.kind === 'round' ? `Round ${event.data.number}` : `${event.kind} ${event.key}`;
  return `\n## ${title}\n\n\`\`\`json\n${JSON.stringify(event.data, null, 2)}\n\`\`\`\n`;
}
function apply(rounds, event) {
  if (event.kind === 'round') {
    if (event.data.number !== rounds.length + 1 || rounds.length >= 3) throw new Error('Expected the next round, with at most three rounds');
    rounds.push(structuredClone(event.data));
    if (event.data.resolutions) resolveFindings(rounds, event.data.resolutions);
  } else if (event.kind === 'resolution') {
    resolveFindings(rounds, event.data);
  } else if (!['decision', 'synthesis', 'final-review'].includes(event.kind)) {
    throw new Error('Unknown history event kind');
  }
}

function resolveFindings(rounds, updates) {
  for (const update of updates) {
    const finding = rounds.flatMap((round) => round.findings).find((item) => item.id === update.id);
    if (!finding || !['incorporated', 'rejected', 'awaiting-user'].includes(update.status) || !update.resolution?.trim()) throw new Error('Resolution needs an existing finding, disposition, and reason');
    Object.assign(finding, { status: update.status, resolution: update.resolution });
  }
}

export function ensureHistory(path) {
  if (existsSync(`${path}/history/baseline.json`)) return;
  const state = json(`${path}/state.json`);
  if (hash(readFileSync(`${path}/original.md`)) !== state.originalSha256) throw new Error('Original changed');
  const feedback = readFileSync(`${path}/feedback.md`, 'utf8');
  validateRounds(state.rounds, feedback);
  mkdirSync(`${path}/history`, { recursive: true });
  const baseline = { originalSha256: state.originalSha256, feedback, rounds: state.rounds };
  writeFileSync(`${path}/history/baseline.json`, `${JSON.stringify(baseline, null, 2)}\n`, { flag: 'wx' });
  const sha = hash(readFileSync(`${path}/history/baseline.json`));
  saveState(path, { historyBaselineSha256: sha, historyHeadSha256: sha });
}

function replay(path) {
  const state = json(`${path}/state.json`);
  const baselineBytes = readFileSync(`${path}/history/baseline.json`);
  const baseline = JSON.parse(baselineBytes);
  let head = hash(baselineBytes);
  if (state.historyBaselineSha256 && state.historyBaselineSha256 !== head) throw new Error('History baseline changed');
  if (baseline.originalSha256 !== state.originalSha256 || hash(readFileSync(`${path}/original.md`)) !== baseline.originalSha256) throw new Error('Original changed');
  const rounds = structuredClone(baseline.rounds);
  let feedback = baseline.feedback;
  const heads = [head];
  const variants = [JSON.stringify(rounds)];
  const events = [];
  const files = readdirSync(`${path}/history`).filter((name) => name !== 'baseline.json').sort();
  for (const [index, file] of files.entries()) {
    if (file !== `${String(index + 1).padStart(6, '0')}.json`) throw new Error('History sequence is incomplete or contains unexpected files');
    const bytes = readFileSync(`${path}/history/${file}`);
    const event = JSON.parse(bytes);
    if (event.previous !== head || events.some((item) => item.key === event.key)) throw new Error('History chain changed or duplicate event key');
    apply(rounds, event);
    feedback += render(event);
    validateRounds(rounds, feedback);
    events.push(event);
    head = hash(bytes);
    heads.push(head);
    variants.push(JSON.stringify(rounds));
  }
  if (state.historyHeadSha256 && !heads.includes(state.historyHeadSha256)) throw new Error('Recorded history changed');
  return { state, rounds, feedback, events, head, heads, variants };
}

export function checkHistory(path, state, feedback) {
  if (!existsSync(`${path}/history/baseline.json`)) {
    if (state.historyBaselineSha256) throw new Error('History baseline missing');
    return;
  }
  const result = replay(path);
  if (result.head !== state.historyHeadSha256 || feedback !== result.feedback || JSON.stringify(state.rounds) !== JSON.stringify(result.rounds)) throw new Error('History projection changed or interrupted; run history sync before continuing');
}

export function syncHistory(path) {
  ensureHistory(path);
  const result = replay(path);
  const current = readFileSync(`${path}/feedback.md`, 'utf8');
  if (!result.feedback.startsWith(current) || !result.variants.includes(JSON.stringify(result.state.rounds))) throw new Error('Feedback or round history was edited; restore it before continuing');
  appendFileSync(`${path}/feedback.md`, result.feedback.slice(current.length));
  saveState(path, { rounds: result.rounds, historyBaselineSha256: result.heads[0], historyHeadSha256: result.head });
  return result;
}

export function appendEvent(path, kind, key, data) {
  if (!key?.trim()) throw new Error('History event needs an idempotency key');
  const previous = syncHistory(path);
  const existing = previous.events.find((event) => event.key === key);
  if (existing) {
    if (existing.kind !== kind || JSON.stringify(existing.data) !== JSON.stringify(data)) throw new Error('Event key already used with different content');
    return;
  }
  const event = { previous: previous.head, kind, key, data };
  const rounds = structuredClone(previous.rounds);
  apply(rounds, event);
  validateRounds(rounds, previous.feedback + render(event));
  const file = `${String(previous.events.length + 1).padStart(6, '0')}.json`;
  writeFileSync(`${path}/history/${file}`, `${JSON.stringify(event, null, 2)}\n`, { flag: 'wx' });
  syncHistory(path);
}

async function main() {
  const [command, slug, source, ...extra] = process.argv.slice(2);
  if (extra.length || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? '')) throw new Error('Usage: history.mjs append <task> <event.json> | sync <task>');
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const path = `${root}/docs/tasks/${slug}`;
  await locked(path, () => {
    if (command === 'sync' && !source) return syncHistory(path);
    if (command !== 'append' || !source) throw new Error('Expected append with an event file, or sync');
    const event = json(resolve(source));
    appendEvent(path, event.kind, event.key, event.data);
  });
  console.log(`${slug}: history recorded without replacing earlier entries`);
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
