import { build } from 'esbuild';
import { polyfillNode } from 'esbuild-plugin-polyfill-node';
import path from 'node:path';

await build({
  entryPoints: ['entry.js'], bundle: true, platform: 'browser', format: 'iife',
  target: 'es2020', outfile: '../Generated/WebSigner.js',
  plugins: [
    { name: 'crypto-shim', setup(builder) {
      builder.onResolve({ filter: /^node:crypto$/ }, () => ({ path: path.resolve('crypto-shim.js') }));
    } },
    polyfillNode({ polyfills: { crypto: true, zlib: true } }),
  ],
});
