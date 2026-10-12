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
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/NavigationMorphGeometry.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
}, reportDiagnostics: true });
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const geometry = { exports: {} };
new Function('exports', 'module', compiled.outputText)(geometry.exports, geometry);
const { navigationMorphFrame } = geometry.exports;
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8, `${actual} != ${expected}`);

test('expanded surface fills the available width with five equal icon hit areas', () => {
  for (let index = 0; index < 5; index++) {
    const frame = navigationMorphFrame(360, index, 0);
    assert.equal(frame.surfaceWidth, 360);
    assert.equal(frame.surfaceHeight, 56);
    assert.equal(frame.surfaceLeft, 0);
    assert.equal(frame.buttonWidth, 72);
    assert.equal(frame.buttonLeft, index * 72);
    assert.equal(frame.labelOpacity, 1);
  }
});

test('each selected icon ends at the center of the same 52 vp circle at the right edge', () => {
  for (let index = 0; index < 5; index++) {
    const frame = navigationMorphFrame(360, index, 1);
    assert.equal(frame.surfaceWidth, 52);
    assert.equal(frame.surfaceHeight, 52);
    assert.equal(frame.buttonWidth, 52);
    assert.equal(frame.surfaceLeft, 308);
    assert.equal(frame.buttonLeft, 0);
    assert.equal(frame.labelOpacity, 0);
    assert.equal(frame.surfaceLeft + frame.buttonLeft + frame.buttonWidth / 2, 334);
  }
});

test('surface and icon centers follow the same progress without leaving the moving surface', () => {
  for (const width of [288, 360, 480]) {
    for (let index = 0; index < 5; index++) {
      for (const progress of [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]) {
        const frame = navigationMorphFrame(width, index, progress);
        const originalCenter = (index + 0.5) * width / 5;
        near(frame.surfaceLeft + frame.buttonLeft + frame.buttonWidth / 2,
          originalCenter + (width - 26 - originalCenter) * progress);
        assert.ok(frame.buttonLeft >= -1e-8);
        assert.ok(frame.buttonLeft + frame.buttonWidth <= frame.surfaceWidth + 1e-8);
        near(frame.surfaceLeft + frame.surfaceWidth, width);
      }
    }
  }
});

test('malformed event and viewport values cannot produce invalid geometry or opacity', () => {
  for (const [width, index, value] of [[NaN, NaN, NaN], [-10, 99, Infinity], [360, -1, -1], [360, 9, 2]]) {
    const frame = navigationMorphFrame(width, index, value);
    for (const number of Object.values(frame)) assert.ok(Number.isFinite(number));
    assert.ok(frame.surfaceWidth >= 52);
    assert.ok(frame.labelOpacity >= 0 && frame.labelOpacity <= 1);
  }
});

test('left handed collapse keeps all icon hit areas inside the same left anchored surface', () => {
  for (let index = 0; index < 5; index++) {
    for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
      const frame = navigationMorphFrame(360, index, progress, true);
      assert.equal(frame.surfaceLeft, 0);
      near(frame.buttonLeft + frame.buttonWidth / 2,
        (index + 0.5) * 72 * (1 - progress) + 26 * progress);
      assert.ok(frame.buttonLeft >= 0);
      assert.ok(frame.buttonLeft + frame.buttonWidth <= frame.surfaceWidth + 1e-8);
    }
  }
});

test('the fifth profile position remains distinct from messages and indices outside the five entries stay bounded', () => {
  const messages = navigationMorphFrame(360, 3, 0);
  const profile = navigationMorphFrame(360, 4, 0);
  assert.equal(messages.buttonLeft + messages.buttonWidth, profile.buttonLeft);
  assert.equal(profile.buttonLeft + profile.buttonWidth, profile.surfaceWidth);
  assert.deepEqual(navigationMorphFrame(360, 99, 0), profile);
  assert.deepEqual(navigationMorphFrame(360, -1, 0), navigationMorphFrame(360, 0, 0));
});
