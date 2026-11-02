const headings = ['Original intent', 'Proposed behavior', 'Non-goals', 'Acceptance criteria', 'Validation', 'Code references and assumptions', 'Open decisions'];

function sections(text) {
  const result = new Map();
  for (const match of text.matchAll(/^## (.+)\r?\n([\s\S]*?)(?=^## |$(?![\s\S]))/gm)) {
    if (result.has(match[1])) throw new Error(`Duplicate section: ${match[1]}`);
    result.set(match[1], match[2].trim());
  }
  return result;
}

export function validateSpec(text) {
  const parts = sections(text);
  for (const heading of headings) {
    if (!parts.get(heading)) throw new Error(`Missing or empty section: ${heading}`);
  }
  if (/<!--[\s\S]*?-->|\bTBD\b/i.test(text)) throw new Error('Remove template comments and unresolved placeholders');
  const ids = (heading) => [...parts.get(heading).matchAll(/^- (AC-[1-9]\d*):\s*(\S.*)$/gm)].map((match) => match[1]);
  const criteria = ids('Acceptance criteria');
  const mappings = ids('Validation');
  if (!criteria.length) throw new Error('No acceptance criteria; use - AC-1: behavior');
  for (const [label, values] of [['criteria', criteria], ['validation mappings', mappings]]) {
    if (new Set(values).size !== values.length) throw new Error(`Duplicate IDs in ${label}`);
  }
  if (criteria.some((id) => !mappings.includes(id)) || mappings.some((id) => !criteria.includes(id))) {
    throw new Error('Validation must map every acceptance criterion exactly once, with no extra IDs');
  }
  return parts;
}

