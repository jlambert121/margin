import fs from 'node:fs';
import path from 'node:path';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import terser from '@rollup/plugin-terser';

// Writes the license of every package that ends up in the bundle next to it.
function bundledLicenses(file) {
  return {
    name: 'bundled-licenses',
    generateBundle(_, bundle) {
      const roots = new Set();
      for (const chunk of Object.values(bundle)) {
        for (const id of Object.keys(chunk.modules ?? {})) {
          const match = id.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//);
          if (match) roots.add(match[1]);
        }
      }
      const sections = [...roots].sort().map(root => {
        const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
        const license = fs.readdirSync(root).find(name => /^licen[cs]e/i.test(name));
        if (!license) throw new Error(`No license file in ${pkg.name}`);
        return `${pkg.name}@${pkg.version} (${pkg.license})\n\n${fs.readFileSync(path.join(root, license), 'utf8').trim()}\n`;
      });
      this.emitFile({ type: 'asset', fileName: file, source: sections.join('\n' + '-'.repeat(72) + '\n\n') });
    },
  };
}

export default {
  input: 'tools/editor-bundle/entry.js',
  output: { dir: 'web/vendor', entryFileNames: 'codemirror.bundle.js', format: 'iife', name: 'MarginEditor', inlineDynamicImports: true },
  plugins: [nodeResolve(), terser({ format: { comments: false } }), bundledLicenses('codemirror.bundle.LICENSES.txt')],
};
