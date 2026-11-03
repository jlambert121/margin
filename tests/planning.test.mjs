import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, cpSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const draft = `# Test task

## Original intent
Preserve document edits when navigating.
## Proposed behavior
Navigation retains the document text.
## Non-goals
Changing save behavior.
## Acceptance criteria
- AC-1: Navigation preserves unsaved text.
## Validation
- AC-1: Native desktop test navigates away and back; assert identical text.
## Code references and assumptions
Sources/EditorWindow.swift owns document switching.
## Open decisions
None
`;

function fixture(t) {
  const root = mkdtempSync(resolve(tmpdir(), 'margin-planning-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(`${root}/tools/planning/templates`, { recursive: true });
  cpSync('tools/planning', `${root}/tools/planning`, { recursive: true });
  copyFileSync('tools/planning/templates/spec.md', `${root}/tools/planning/templates/spec.md`);
  writeFileSync(`${root}/draft.md`, draft);
  const run = (...args) => spawnSync(process.execPath, [`${root}/tools/planning/task.mjs`, ...args], { cwd: root, encoding: 'utf8' });
  const path = `${root}/docs/tasks/example`;
  assert.equal(run('init', 'example', '--from', 'draft.md').status, 0);
  const state = () => JSON.parse(readFileSync(`${path}/state.json`, 'utf8'));
  const save = (value) => writeFileSync(`${path}/state.json`, JSON.stringify(value));
  const reviewed = () => {
    const value = state();
    value.status = 'critique';
    value.rounds = [{ number: 1, reviewer: 'fresh test reviewer', summary: 'No blockers found.', findings: [] }];
    value.finalReview = 'Checked final criteria and validation against original intent.';
    writeFileSync(`${path}/feedback.md`, '# Critique history\n\n## Round 1\nNo blockers found.\n');
    save(value);
    return value;
  };
  return { root, run, path, state, save, reviewed };
}

test('initialization preserves input, refuses overwrite, and rejects path traversal', (t) => {
  const f = fixture(t);
  assert.equal(readFileSync(`${f.path}/original.md`, 'utf8'), draft);
  assert.equal(f.run('validate', 'example').status, 0);
  assert.notEqual(f.run('init', 'example', '--from', 'draft.md').status, 0);
  assert.notEqual(f.run('init', '../escape', '--from', 'draft.md').status, 0);
  assert.notEqual(f.run('prepare', 'example').status, 0);
});

test('every criterion requires exactly one validation mapping', (t) => {
  const f = fixture(t);
  for (const spec of [draft.replace('- AC-1: Native', '- AC-2: Native'), draft.replace('## Validation', '- AC-1: Duplicate criterion.\n## Validation')]) {
    writeFileSync(`${f.path}/spec.md`, spec);
    assert.notEqual(f.run('validate', 'example').status, 0);
  }
});

test('original edits and intent drift fail integrity validation', (t) => {
  const f = fixture(t);
  writeFileSync(`${f.path}/spec.md`, draft.replace('Preserve document edits when navigating.', 'Change save behavior.'));
  assert.notEqual(f.run('validate', 'example').status, 0);
  writeFileSync(`${f.path}/spec.md`, draft);
  writeFileSync(`${f.path}/original.md`, `${draft}\nChanged`);
  assert.notEqual(f.run('validate', 'example').status, 0);
});

test('prepared evidence is tied to the reviewed spec', (t) => {
  const f = fixture(t);
  f.reviewed();
  assert.equal(f.run('prepare', 'example').status, 0);
  assert.equal(f.run('validate', 'example').status, 0);
  assert.equal(f.state().status, 'prepared');
  writeFileSync(`${f.path}/spec.md`, `${draft}\nAnother behavior.\n`);
  assert.notEqual(f.run('validate', 'example').status, 0);
  assert.notEqual(f.run('prepare', 'example').status, 0);
});

test('unresolved findings, missing resolutions, and open decisions prevent readiness', (t) => {
  const f = fixture(t);
  const state = f.reviewed();
  const finding = { id: 'F-1', severity: 'blocking', summary: 'Unclear behavior', evidence: 'Source contradicts proposal', status: 'open' };
  state.rounds[0].findings.push(finding);
  writeFileSync(`${f.path}/feedback.md`, '## Round 1\nF-1: Unclear behavior\n');
  f.save(state);
  assert.notEqual(f.run('prepare', 'example').status, 0);
  finding.status = 'rejected';
  f.save(state);
  assert.notEqual(f.run('prepare', 'example').status, 0);
  finding.resolution = 'Source supports original behavior; evidence was incorrect.';
  f.save(state);
  writeFileSync(`${f.path}/spec.md`, draft.replace('## Open decisions\nNone', '## Open decisions\nChoose whether navigation saves.'));
  assert.notEqual(f.run('prepare', 'example').status, 0);
  writeFileSync(`${f.path}/spec.md`, draft);
  assert.equal(f.run('prepare', 'example').status, 0);
});

test('exhausted or stopped reviews cannot become prepared', (t) => {
  const f = fixture(t);
  const state = f.reviewed();
  state.status = 'incomplete';
  f.save(state);
  assert.notEqual(f.run('prepare', 'example').status, 0);
  state.status = 'critique';
  state.rounds = Array.from({ length: 4 }, (_, index) => ({ ...state.rounds[0], number: index + 1 }));
  f.save(state);
  assert.notEqual(f.run('prepare', 'example').status, 0);
});


async function modules(f) {
  const history = await import(pathToFileURL(`${f.root}/tools/planning/history.mjs`));
  const controller = await import(pathToFileURL(`${f.root}/tools/planning/controller.mjs`));
  return { ...history, ...controller };
}
const round = { number: 1, reviewer: 'fresh fixture reviewer', summary: 'Found a scope ambiguity.', findings: [{ id: 'F-1', severity: 'blocking', summary: 'Unclear scope', evidence: 'Criterion does not name the surface.', status: 'open' }] };
const clean = { summary: 'No unresolved findings remain.', converged: true, decision: '', findings: [], resolutions: [] };
const synthesis = { spec: draft, summary: 'Preserved all criteria and validation.' };
const finalReview = { passed: true, summary: 'Compared original intent, accepted feedback, criteria, and code references.', findings: [] };
function agentQueue(reports) {
  const stages = [];
  const ask = async (_root, stage) => {
    stages.push(stage);
    const report = reports.shift();
    if (report instanceof Error) throw report;
    assert.ok(report, `Unexpected agent call: ${stage}`);
    return { reviewer: `fresh fixture session ${stages.length}`, report };
  };
  return { ask, stages };
}

test('history appends idempotently, preserves raw findings, and records dispositions separately', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  h.appendEvent(f.path, 'round', 'first', round);
  const bytes = readFileSync(`${f.path}/history/000001.json`, 'utf8');
  h.appendEvent(f.path, 'round', 'first', round);
  assert.equal(f.state().rounds.length, 1);
  h.appendEvent(f.path, 'resolution', 'resolve-first', [{ id: 'F-1', status: 'incorporated', resolution: 'Specify the document switch surface.' }]);
  assert.equal(f.state().rounds[0].findings[0].status, 'incorporated');
  assert.equal(readFileSync(`${f.path}/history/000001.json`, 'utf8'), bytes);
  assert.match(bytes, /"status": "open"/);
  assert.equal(f.run('validate', 'example').status, 0);
  assert.throws(() => h.appendEvent(f.path, 'round', 'first', { ...round, summary: 'replacement' }), /different content/);
});

test('history refuses edited feedback and tampered event files', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  h.appendEvent(f.path, 'round', 'first', round);
  const feedback = readFileSync(`${f.path}/feedback.md`, 'utf8');
  writeFileSync(`${f.path}/feedback.md`, 'replacement');
  assert.throws(() => h.syncHistory(f.path), /edited/);
  assert.equal(readFileSync(`${f.path}/feedback.md`, 'utf8'), 'replacement');
  writeFileSync(`${f.path}/feedback.md`, feedback);
  const file = `${f.path}/history/000001.json`;
  writeFileSync(file, readFileSync(file, 'utf8').replace('Found a scope ambiguity.', 'Changed history.'));
  assert.throws(() => h.syncHistory(f.path), /history changed/);
  assert.notEqual(f.run('validate', 'example').status, 0);
});

test('interrupted history projection recovers without replacing feedback or duplicating rounds', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  h.ensureHistory(f.path);
  const oldState = f.state();
  const oldFeedback = readFileSync(`${f.path}/feedback.md`, 'utf8');
  h.appendEvent(f.path, 'round', 'first', round);
  writeFileSync(`${f.path}/feedback.md`, oldFeedback);
  f.save(oldState);
  h.syncHistory(f.path);
  assert.equal(f.state().rounds.length, 1);
  assert.equal(readFileSync(`${f.path}/feedback.md`, 'utf8').split('## Round 1').length, 2);
  assert.equal(f.run('validate', 'example').status, 0);
});

test('controller runs fresh critique, resolution, synthesis and final review before preparation', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([
    { ...clean, converged: false, findings: round.findings.map(({ status, ...finding }) => finding) },
    { ...clean, resolutions: [{ id: 'F-1', status: 'incorporated', resolution: 'The final spec will explicitly retain document text.' }] },
    synthesis, finalReview,
  ]);
  const result = await h.runController(f.root, 'example', undefined, queue.ask);
  assert.equal(result.phase, 'done');
  assert.deepEqual(queue.stages, ['critique', 'critique', 'synthesis', 'final-review']);
  assert.equal(f.state().status, 'prepared');
  assert.equal(f.state().rounds.length, 2);
  assert.equal(f.state().convergenceRound, 2);
  assert.equal(f.state().finalReviewPassed, true);
  assert.equal(readFileSync(`${f.path}/original.md`, 'utf8'), draft);
  assert.equal(f.run('validate', 'example').status, 0);
});

test('controller waits for a recorded user decision and does not treat elapsed time as an answer', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([{ ...clean, converged: false, decision: 'Include export as well as editing?' }, clean, synthesis, finalReview]);
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'needs-input');
  assert.equal(f.state().status, 'needs-input');
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'needs-input');
  assert.equal(queue.stages.length, 1);
  assert.equal((await h.runController(f.root, 'example', 'Editing only.', queue.ask)).phase, 'done');
  assert.match(readFileSync(`${f.path}/feedback.md`, 'utf8'), /Editing only/);
});

test('controller stops after three unconverged rounds and cannot mark the task prepared', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue(Array.from({ length: 3 }, () => ({ ...clean, converged: false })));
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'incomplete');
  assert.equal(queue.stages.length, 3);
  assert.equal(f.state().status, 'incomplete');
  assert.notEqual(f.run('prepare', 'example').status, 0);
  await h.runController(f.root, 'example', undefined, queue.ask);
  assert.equal(queue.stages.length, 3);
});

test('failed agent call resumes the current stage without rerunning completed critique', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([clean, new Error('rate limit'), synthesis, finalReview]);
  await assert.rejects(h.runController(f.root, 'example', undefined, queue.ask), /rate limit/);
  assert.equal(f.state().rounds.length, 1);
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'done');
  assert.deepEqual(queue.stages, ['critique', 'synthesis', 'synthesis', 'final-review']);
});

test('invalid synthesis cannot change intent or publish a spec and can be retried', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([clean, { ...synthesis, spec: draft.replace('Preserve document edits when navigating.', 'Rewrite the application.') }, synthesis, finalReview]);
  await assert.rejects(h.runController(f.root, 'example', undefined, queue.ask), /original intent/);
  assert.equal(readFileSync(`${f.path}/spec.md`, 'utf8'), draft);
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'done');
});

test('a failed final review prevents preparation and remains in history', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([clean, synthesis, { passed: false, summary: 'Criterion remains ambiguous.', findings: [{ id: 'F-1', severity: 'blocking', summary: 'Ambiguous behavior', evidence: 'Spec does not identify the active document.' }] }]);
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'incomplete');
  assert.notEqual(f.run('prepare', 'example').status, 0);
  assert.match(readFileSync(`${f.path}/feedback.md`, 'utf8'), /Criterion remains ambiguous/);
});

test('agent adapter requests a fresh read-only structured session and saves raw output locally', async (t) => {
  const f = fixture(t);
  const { askAgent } = await import(pathToFileURL(`${f.root}/tools/planning/agent.mjs`));
  const { loadTask } = await import(pathToFileURL(`${f.root}/tools/planning/task.mjs`));
  const result = await askAgent(f.root, 'critique', loadTask('example'), {}, async (command, args, options) => {
    assert.equal(command, 'codex');
    assert.ok(args.includes('--ephemeral'));
    assert.ok(args.includes('read-only'));
    assert.ok(args.includes('never'));
    assert.equal(args.includes('resume'), false);
    assert.match(options.input, /Preserve document edits/);
    writeFileSync(args[args.indexOf('--output-last-message') + 1], JSON.stringify(clean));
  });
  assert.equal(result.report.converged, true);
});


test('history imports existing manual rounds without replacing their feedback', async (t) => {
  const f = fixture(t);
  f.reviewed();
  const existing = readFileSync(`${f.path}/feedback.md`, 'utf8');
  const h = await modules(f);
  h.appendEvent(f.path, 'round', 'second', { number: 2, reviewer: 'fresh session', summary: 'No new findings', findings: [] });
  assert.ok(readFileSync(`${f.path}/feedback.md`, 'utf8').startsWith(existing));
  assert.equal(f.state().rounds.length, 2);
  assert.equal(f.state().rounds[0].reviewer, 'fresh test reviewer');
});

test('controller rejects invalid dispositions atomically and allows a fresh retry', async (t) => {
  const f = fixture(t);
  const h = await modules(f);
  const queue = agentQueue([{ ...clean, resolutions: [{ id: 'F-99', status: 'incorporated', resolution: 'Invented resolution' }] }, clean, synthesis, finalReview]);
  await assert.rejects(h.runController(f.root, 'example', undefined, queue.ask), /existing finding/);
  assert.equal(f.state().rounds.length, 0);
  assert.equal((await h.runController(f.root, 'example', undefined, queue.ask)).phase, 'done');
});

test('planning subprocess logs output and terminates on timeout', async (t) => {
  const f = fixture(t);
  const { launch } = await import(pathToFileURL(`${f.root}/tools/planning/agent.mjs`));
  const options = { cwd: f.root, input: 'fixture input', stdout: `${f.root}/out.log`, stderr: `${f.root}/err.log` };
  await launch(process.execPath, ['-e', "process.stdin.on('data', b => console.log(b.toString()));"], options, 2000);
  assert.match(readFileSync(options.stdout, 'utf8'), /fixture input/);
  await assert.rejects(launch(process.execPath, ['-e', 'setTimeout(() => {}, 5000)'], options, 100), /timeout/);
});
