import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
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
  for (const file of ['task.mjs', 'spec.mjs', 'reviews.mjs']) {
    copyFileSync(`tools/planning/${file}`, `${root}/tools/planning/${file}`);
  }
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
  return { run, path, state, save, reviewed };
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
