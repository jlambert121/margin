import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';

export const digest = (value) => createHash('sha256').update(value).digest('hex');
export const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
export function git(root, ...args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' });
}

export function dirtyPaths(root) {
  const entries = git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none').split('\0');
  const paths = [];
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    if (!entry) continue;
    paths.push(entry.slice(3));
    if (/[RC]/.test(entry.slice(0, 2))) paths.push(entries[++index]);
  }
  return paths;
}

function isAllowedChange(path) {
  return path.startsWith('docs/tasks/')
    || /\.(?:md|markdown|mdown|mkdn|mkd|mdx)$/i.test(path)
    || path.split('/').some((part) => part.startsWith('.'));
}

export function assertClean(root) {
  const dirty = dirtyPaths(root).filter((path) => !isAllowedChange(path));
  if (dirty.length) throw new Error(`Working tree has blocking changes; stop without stashing or committing:\n${dirty.map((path) => JSON.stringify(path)).join('\n')}`);
}

export function commonDirectory(root) {
  return resolve(root, git(root, 'rev-parse', '--git-common-dir').trim(), 'margin-execution');
}

export function assertInside(parent, path) {
  if (!realpathSync(path).startsWith(`${realpathSync(parent)}/`)) throw new Error(`Path escapes its artifact directory: ${path}`);
}

export function revision(root) {
  return git(root, 'rev-parse', 'HEAD').trim();
}
