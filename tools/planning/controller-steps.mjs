import { readFileSync, writeFileSync } from 'node:fs';
import { appendEvent } from './history.mjs';
import { hash, saveState } from './storage.mjs';
import { validateSpec } from './spec.mjs';
import { checkReady, loadTask } from './task.mjs';

export function acceptCritique(task, result, number) {
  const { report, reviewer } = result;
  if (!report.summary?.trim() || !reviewer?.trim()) throw new Error('Critique needs a summary and reviewer');
  if (typeof report.converged !== 'boolean' || typeof report.decision !== 'string') throw new Error('Malformed convergence or decision response');
  if (!Array.isArray(report.findings) || !Array.isArray(report.resolutions)) throw new Error('Critique needs findings and resolutions arrays');
  const round = { number, reviewer, summary: report.summary, converged: report.converged, decision: report.decision, resolutions: report.resolutions, findings: report.findings.map((finding) => ({ ...finding, status: 'open' })) };
  appendEvent(task.path, 'round', `round-${number}`, round);
  const updated = loadTask(task.slug);
  const unresolved = updated.state.rounds.flatMap((item) => item.findings).some((finding) => ['open', 'awaiting-user'].includes(finding.status));
  if (report.decision.trim()) {
    saveState(task.path, { status: 'needs-input' });
    return { phase: 'needs-input', question: report.decision };
  }
  if (report.converged && !unresolved) {
    saveState(task.path, { status: 'critique', convergenceRound: number });
    return { phase: 'synthesis' };
  }
  if (number >= 3) {
    saveState(task.path, { status: 'incomplete' });
    return { phase: 'incomplete', reason: 'Three critique rounds exhausted without convergence' };
  }
  return { phase: 'critique' };
}

export function acceptSynthesis(task, result) {
  const { report } = result;
  if (!report.summary?.trim() || typeof report.spec !== 'string') throw new Error('Malformed synthesis response');
  const parts = validateSpec(report.spec);
  if (parts.get('Original intent') !== validateSpec(task.original).get('Original intent')) throw new Error('Synthesis changed original intent');
  if (parts.get('Open decisions').toLowerCase() !== 'none') throw new Error('Synthesis left product decisions unresolved');
  appendEvent(task.path, 'synthesis', 'synthesis', { ...report, reviewer: result.reviewer });
  writeFileSync(`${task.path}/spec.md`, report.spec);
  return { phase: 'final-review', specSha256: hash(report.spec) };
}

export function acceptFinalReview(task, result) {
  const { report } = result;
  if (typeof report.passed !== 'boolean' || !report.summary?.trim() || !Array.isArray(report.findings)) throw new Error('Malformed final review');
  appendEvent(task.path, 'final-review', 'final-review', { ...report, reviewer: result.reviewer, specSha256: hash(task.spec) });
  const passed = report.passed && report.findings.length === 0;
  saveState(task.path, { finalReview: report.summary, finalReviewPassed: passed, finalReviewSpecSha256: hash(task.spec), status: passed ? 'critique' : 'incomplete' });
  if (!passed) return { phase: 'incomplete', reason: 'Final consistency review found unresolved problems; inspect feedback.md' };
  const ready = loadTask(task.slug);
  checkReady(ready);
  saveState(task.path, { status: 'prepared', preparedSpecSha256: hash(ready.spec) });
  return { phase: 'done' };
}

export function unchanged(task, expected) {
  for (const file of ['original.md', 'spec.md', 'feedback.md', 'state.json']) {
    if (hash(readFileSync(`${task.path}/${file}`)) !== expected[file]) throw new Error(`Task changed during agent call: ${file}`);
  }
}
export function fingerprint(task) {
  return Object.fromEntries(['original.md', 'spec.md', 'feedback.md', 'state.json'].map((file) => [file, hash(readFileSync(`${task.path}/${file}`))]));
}
