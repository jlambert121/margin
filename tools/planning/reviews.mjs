export function validateRounds(rounds, feedback) {
  const seen = new Set();
  for (const [index, round] of rounds.entries()) {
    if (round.number !== index + 1 || !round.reviewer?.trim() || !round.summary?.trim() || !Array.isArray(round.findings)) throw new Error('Each round needs a sequential number, reviewer, summary, and findings array');
    if (!feedback.includes(`## Round ${round.number}\n`)) throw new Error(`Missing feedback for round ${round.number}`);
    validateFindings(round.findings, feedback, seen);
  }
}

function validateFindings(findings, feedback, seen) {
  for (const finding of findings) {
    if (!/^F-[1-9]\d*$/.test(finding.id) || seen.has(finding.id)) throw new Error('Finding IDs must be unique F-N IDs');
    seen.add(finding.id);
    if (!['blocking', 'minor'].includes(finding.severity) || !['open', 'incorporated', 'rejected', 'awaiting-user'].includes(finding.status)) throw new Error(`Invalid finding: ${finding.id}`);
    if (!finding.summary?.trim() || !finding.evidence?.trim() || !feedback.includes(finding.id)) throw new Error(`Missing finding evidence or feedback: ${finding.id}`);
    if (['incorporated', 'rejected'].includes(finding.status) && !finding.resolution?.trim()) throw new Error(`Missing resolution: ${finding.id}`);
  }
}
