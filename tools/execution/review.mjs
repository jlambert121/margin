import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { checkEvidence } from './evidence.mjs';
import { digest } from './git.mjs';
import { verifiedRevision, save } from './artifacts.mjs';

export function unresolved(reports) {
  const pending = new Map();
  const seen = new Set();
  for (const report of reports) {
    for (const finding of report.findings) {
      if (seen.has(finding.id)) throw new Error(`Duplicate finding ID: ${finding.id}`);
      seen.add(finding.id);
      pending.set(finding.id, finding);
    }
    for (const resolution of report.resolutions) {
      if (!pending.has(resolution.id) || !resolution.summary?.trim()) throw new Error('Resolution must reference an existing finding and explain the fix or rejection');
      pending.delete(resolution.id);
    }
  }
  return [...pending.values()];
}

export function reportsFor(run) {
  return run.state.reviews.map((entry) => {
    const content = readFileSync(`${run.path}/${entry.file}`);
    if (digest(content) !== entry.sha256) throw new Error('Recorded review changed');
    return JSON.parse(content);
  });
}

export function recordReview(run, report) {
  const current = verifiedRevision(run);
  if (run.state.reviews.length >= 3) throw new Error('Three review rounds exhausted; stop this run as incomplete');
  if (report.revision !== current || !report.reviewer?.trim() || !report.summary?.trim()) throw new Error('Review needs the verified revision, fresh reviewer identity, and summary');
  if (!['pass', 'changes-requested'].includes(report.verdict) || !Array.isArray(report.findings) || !Array.isArray(report.resolutions)) throw new Error('Invalid review verdict or findings/resolutions');
  for (const finding of report.findings) {
    if (!/^F-[1-9]\d*$/.test(finding.id) || !['blocking', 'minor'].includes(finding.severity) || !finding.summary?.trim() || !finding.evidence?.trim()) throw new Error('Each finding needs a unique F-N ID, severity, summary, and evidence/consequence');
  }
  checkEvidence(run, report);
  const pending = unresolved([...reportsFor(run), report]);
  if (report.verdict === 'pass' && (pending.length || report.criteria.some((item) => item.result !== 'passed'))) throw new Error('Passing review requires all findings resolved and all criteria passed');
  report.evidenceSha256 = Object.fromEntries(report.criteria.flatMap((criterion) => criterion.evidence).map((file) => [file, digest(readFileSync(resolve(run.path, file)))]));
  const number = run.state.reviews.length + 1;
  const file = `review-${number}.json`;
  writeFileSync(`${run.path}/${file}`, `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' });
  run.state.reviews.push({ number, revision: current, file, sha256: digest(readFileSync(`${run.path}/${file}`)) });
  run.state.status = report.verdict === 'pass' ? 'reviewed' : 'implementing';
  appendFileSync(`${run.path}/reviews.md`, `\n## Round ${number}\n\n${report.summary}\n\nSee [full review](${file}).\n`);
  save(run);
}

export function finish(run) {
  const current = verifiedRevision(run);
  const reports = reportsFor(run);
  const last = reports.at(-1);
  if (!last || last.verdict !== 'pass' || last.revision !== current || unresolved(reports).length) throw new Error('A fresh passing review of the verified revision is required');
  checkEvidence(run, last);
  for (const [file, sha256] of Object.entries(last.evidenceSha256)) {
    if (digest(readFileSync(resolve(run.path, file))) !== sha256) throw new Error('Acceptance evidence changed');
  }
  const handoff = readFileSync(`${run.path}/handoff.md`, 'utf8');
  if (!handoff.trim() || handoff.includes('Execution is not complete.')) throw new Error('Complete the handoff before finishing');
  const verification = run.state.verifications.at(-1);
  for (const result of verification.results) {
    if (digest(readFileSync(`${run.path}/${result.log}`)) !== result.sha256) throw new Error('Verification log changed');
  }
  run.state.status = 'ready-for-review';
  run.state.completedRevision = current;
  save(run);
}
