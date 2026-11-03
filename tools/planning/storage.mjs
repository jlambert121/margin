import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync, openSync, closeSync, unlinkSync } from 'node:fs';

export const hash = (value) => createHash('sha256').update(value).digest('hex');
export const json = (path) => JSON.parse(readFileSync(path, 'utf8'));
export function writeJson(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}
export function saveState(path, updates) {
  writeJson(`${path}/state.json`, { ...json(`${path}/state.json`), ...updates });
}
export async function locked(path, action) {
  mkdirSync(`${path}/planning`, { recursive: true });
  const lock = `${path}/planning/operation.lock`;
  const fd = openSync(lock, 'wx');
  try {
    return await action();
  } finally {
    closeSync(fd);
    unlinkSync(lock);
  }
}
