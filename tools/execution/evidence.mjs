import { readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { validateSpec } from '../planning/spec.mjs';
import { assertInside } from './git.mjs';

export function checkEvidence(run, report) {
  const parts = validateSpec(readFileSync(`${run.path}/inputs/spec.md`, 'utf8'));
  const ids = [...parts.get('Acceptance criteria').matchAll(/^- (AC-[1-9]\d*):/gm)].map((match) => match[1]);
  if (!Array.isArray(report.criteria) || report.criteria.length !== ids.length) throw new Error('Review must assess every acceptance criterion exactly once');
  const seen = new Set();
  for (const criterion of report.criteria) {
    if (!ids.includes(criterion.id) || seen.has(criterion.id)) throw new Error('Unknown or duplicate criterion ID');
    seen.add(criterion.id);
    if (!['passed', 'failed', 'unavailable'].includes(criterion.result) || !criterion.summary?.trim()) throw new Error('Each criterion needs a result and evidence summary');
    if (!Array.isArray(criterion.evidence) || !criterion.evidence.length) throw new Error('Each criterion needs run-local evidence files');
    for (const file of criterion.evidence) {
      checkFile(run, report.revision, file);
    }
  }
}

function checkFile(run, revision, file) {
  const generated = /^(?:logs\/verification-(\d+)\/|screenshots\/verification-(\d+)\.png$)/.exec(file);
  if (generated) {
    const attempt = Number(generated[1] ?? generated[2]);
    const verification = run.state.verifications.find((item) => item.attempt === attempt);
    if (!verification || verification.revision !== revision) throw new Error('Evidence belongs to another code revision');
  }
  const path = resolve(run.path, file);
  assertInside(run.path, path);
  if (!statSync(path).isFile() || !statSync(path).size) throw new Error(`Evidence file is empty: ${file}`);
}
