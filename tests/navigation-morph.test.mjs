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
const { navigationMorphFrame, navigationBarHeight, navigationCircleSize, navigationBarMaxWidth, navigationIconSize } = geometry.exports;
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8, `${actual} != ${expected}`);

test('expanded navigation is centered and capped at 280 vp while five equal hit areas still fit a 240 vp viewport', () => {
  assert.deepEqual([navigationBarHeight, navigationCircleSize, navigationBarMaxWidth, navigationIconSize], [52, 48, 280, 21]);
  for (const width of [240, 280, 360, 408, 480]) {
    for (const sideLeft of [false, true]) {
      for (let index = 0; index < 5; index++) {
        const frame = navigationMorphFrame(width, index, 0, sideLeft);
        const expandedWidth = Math.min(width, 280);
        assert.equal(frame.surfaceWidth, expandedWidth);
        assert.equal(frame.surfaceHeight, 52);
        assert.equal(frame.surfaceLeft, (width - expandedWidth) / 2);
        assert.equal(frame.buttonWidth, expandedWidth / 5);
        assert.equal(frame.buttonLeft, index * expandedWidth / 5);
        assert.ok(frame.buttonWidth >= 48);
        assert.equal(frame.iconTop, 5);
        assert.equal(frame.labelOpacity, 1);
      }
    }
  }
});

test('every selected icon collapses to a 48 vp circle anchored to the full viewport hand edge', () => {
  for (const width of [240, 280, 360, 408, 480]) {
    for (const sideLeft of [false, true]) {
      for (let index = 0; index < 5; index++) {
        const frame = navigationMorphFrame(width, index, 1, sideLeft);
        assert.equal(frame.surfaceWidth, 48);
        assert.equal(frame.surfaceHeight, 48);
        assert.equal(frame.buttonWidth, 48);
        assert.equal(frame.surfaceLeft, sideLeft ? 0 : width - 48);
        assert.equal(frame.buttonLeft, 0);
        assert.equal(frame.iconTop, 13.5);
        assert.equal(frame.labelOpacity, 0);
        assert.equal(frame.surfaceLeft + frame.buttonLeft + frame.buttonWidth / 2, sideLeft ? 24 : width - 24);
      }
    }
  }
});

test('surface and icon centers follow the same progress without leaving the moving surface', () => {
  for (const width of [240, 280, 288, 360, 408, 480]) {
    for (const sideLeft of [false, true]) {
      for (let index = 0; index < 5; index++) {
        for (const progress of [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]) {
          const frame = navigationMorphFrame(width, index, progress, sideLeft);
          const expandedWidth = Math.min(width, 280);
          const originalCenter = (width - expandedWidth) / 2 + (index + 0.5) * expandedWidth / 5;
          const collapsedCenter = sideLeft ? 24 : width - 24;
          near(frame.surfaceLeft + frame.buttonLeft + frame.buttonWidth / 2,
            originalCenter + (collapsedCenter - originalCenter) * progress);
          assert.ok(frame.surfaceLeft >= -1e-8);
          assert.ok(frame.surfaceLeft + frame.surfaceWidth <= width + 1e-8);
          assert.ok(frame.buttonLeft >= -1e-8);
          assert.ok(frame.buttonLeft + frame.buttonWidth <= frame.surfaceWidth + 1e-8);
          assert.ok(frame.buttonWidth >= 48);
          assert.ok(frame.surfaceHeight >= 48 && frame.surfaceHeight <= 52);
          assert.ok(frame.iconTop >= 0 && frame.iconTop + 21 <= frame.surfaceHeight);
          near(frame.labelOpacity, 1 - progress);
        }
      }
    }
  }
});

test('malformed event and viewport values cannot produce invalid geometry or opacity', () => {
  for (const [width, index, value] of [[NaN, NaN, NaN], [-10, 99, Infinity], [360, -1, -1], [360, 9, 2],
    [0, 1, 0.5], [47, 2, 0.25], [Infinity, -Infinity, -Infinity]]) {
    const frame = navigationMorphFrame(width, index, value);
    for (const number of Object.values(frame)) assert.ok(Number.isFinite(number));
    assert.ok(frame.surfaceWidth >= 48 && frame.surfaceWidth <= 280);
    assert.ok(frame.surfaceHeight >= 48 && frame.surfaceHeight <= 52);
    assert.ok(frame.labelOpacity >= 0 && frame.labelOpacity <= 1);
  }
  assert.deepEqual(navigationMorphFrame(NaN, NaN, NaN), navigationMorphFrame(328, 0, 0));
  assert.deepEqual(navigationMorphFrame(-10, 99, Infinity), navigationMorphFrame(328, 4, 0));
  assert.deepEqual(navigationMorphFrame(408, 3.9, -1), navigationMorphFrame(408, 3, 0));
  assert.deepEqual(navigationMorphFrame(408, 9, 2), navigationMorphFrame(408, 4, 1));
});

test('hand preference preserves the same centered expanded layout and mirrored circle anchors', () => {
  for (let index = 0; index < 5; index++) {
    for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
      const left = navigationMorphFrame(408, index, progress, true);
      const right = navigationMorphFrame(408, index, progress, false);
      near(left.surfaceLeft, 64 * (1 - progress));
      near(right.surfaceLeft + right.surfaceWidth, 408 - left.surfaceLeft);
      assert.equal(left.buttonLeft, right.buttonLeft);
      assert.equal(left.buttonWidth, right.buttonWidth);
      if (progress === 0) { assert.deepEqual(left, right); }
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
