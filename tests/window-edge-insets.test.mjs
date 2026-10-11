import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/WindowEdgeInsets.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
}, reportDiagnostics: true });
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const insets = { exports: {} };
new Function('exports', 'require', 'module', compiled.outputText)(insets.exports,
  () => { throw new Error('Inset math must not load a native runtime.'); }, insets);
const { topWindowInset, bottomWindowInset } = insets.exports;

test('status and cutout overlap uses the larger top inset instead of adding them', () => {
  const info = { statusBar: { topRect: { height: 32 } }, cutout: { topRect: { height: 36 } } };
  assert.equal(topWindowInset(info), 36);
  assert.equal(topWindowInset({ ...info, cutout: { topRect: { height: 24 } } }), 32);
});

test('gesture, three-button system bar and bottom cutout overlap uses the maximum', () => {
  const info = { navigationIndicator: { bottomRect: { height: 24 } },
    statusBar: { bottomRect: { height: 48 } }, cutout: { bottomRect: { height: 30 } } };
  assert.equal(bottomWindowInset(info), 48);
  assert.equal(bottomWindowInset({ ...info, statusBar: { bottomRect: { height: 0 } } }), 30);
  assert.equal(bottomWindowInset({ ...info, statusBar: { bottomRect: { height: 0 } },
    cutout: { bottomRect: { height: 0 } } }), 24);
});

test('missing, invalid and hidden zero regions are stable zero, without a hardcoded minimum', () => {
  for (const info of [undefined, null, {}, { statusBar: {} },
    { statusBar: { topRect: { height: -1 }, bottomRect: { height: Infinity } },
      cutout: { topRect: { height: NaN }, bottomRect: { height: '24' } } },
    { statusBar: { topRect: { height: 0 }, bottomRect: { height: 0 } },
      navigationIndicator: { bottomRect: { height: 0 } } }]) {
    assert.equal(topWindowInset(info), 0);
    assert.equal(bottomWindowInset(info), 0);
  }
});

test('fractional vp survives unchanged and keyboard size cannot become a system-bar inset', () => {
  const info = { statusBar: { topRect: { height: 25.5 }, bottomRect: { height: 0 } },
    navigationIndicator: { bottomRect: { height: 8.25 } },
    keyboard: { topRect: { height: 600 }, bottomRect: { height: 400 } } };
  assert.equal(topWindowInset(info), 25.5);
  assert.equal(bottomWindowInset(info), 8.25);
});
