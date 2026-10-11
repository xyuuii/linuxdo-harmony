import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/ImageViewerGeometry.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const geometry = { exports: {} };
new Function('exports', 'require', 'module', compiled)(geometry.exports, require, geometry);
const { containViewerSize, constrainViewerOffset, zoomViewerOffset, viewerScale, viewerIndex } = geometry.exports;

test('contain shows a complete portrait or landscape image without cropping', () => {
  const viewport = { width: 400, height: 800 };
  assert.deepEqual(containViewerSize(viewport, { width: 1600, height: 900 }), { width: 400, height: 225 });
  assert.deepEqual(containViewerSize(viewport, { width: 400, height: 1600 }), { width: 200, height: 800 });
  assert.deepEqual(containViewerSize(viewport, { width: 0, height: 10 }), { width: 0, height: 0 });
});

test('an unzoomed image remains centered when dragged, including letterboxed images', () => {
  for (const image of [{ width: 1600, height: 900 }, { width: 400, height: 1600 }]) {
    const offset = constrainViewerOffset({ width: 400, height: 800 }, image, 1, { x: 999, y: -999 });
    assert.equal(Math.abs(offset.x), 0);
    assert.equal(Math.abs(offset.y), 0);
  }
});

test('zoomed landscape pans only horizontally until its actual image exceeds viewport height', () => {
  const viewport = { width: 400, height: 800 };
  const image = { width: 1600, height: 900 };
  const offset = constrainViewerOffset(viewport, image, 2.5, { x: 999, y: 999 });
  assert.deepEqual(offset, { x: 300, y: 0 });
  assert.deepEqual(constrainViewerOffset(viewport, image, 5, { x: -9999, y: 9999 }), { x: -800, y: 162.5 });
});

test('a tall image can reach both ends without being dragged into empty space', () => {
  const viewport = { width: 400, height: 800 };
  const image = { width: 400, height: 1600 };
  assert.deepEqual(constrainViewerOffset(viewport, image, 2.5, { x: 999, y: -9999 }), { x: 50, y: -600 });
});

test('double-tap zoom keeps the tapped image point beneath the finger', () => {
  const viewport = { width: 400, height: 800 };
  const image = { width: 400, height: 800 };
  const focus = { x: 300, y: 500 };
  const result = zoomViewerOffset(viewport, image, 1, 2.5, { x: 0, y: 0 }, focus, focus);
  assert.deepEqual(result, { x: -150, y: -150 });
  assert.equal((300 - 200) * 2.5 + result.x + 200, 300);
  assert.equal((500 - 400) * 2.5 + result.y + 400, 500);
});

test('pinch center movement pans while scaling, and reset returns to center', () => {
  const viewport = { width: 400, height: 800 };
  const image = { width: 400, height: 800 };
  assert.deepEqual(zoomViewerOffset(viewport, image, 1, 2.5, { x: 0, y: 0 },
    { x: 200, y: 400 }, { x: 240, y: 450 }), { x: 40, y: 50 });
  const reset = zoomViewerOffset(viewport, image, 2.5, 1, { x: 200, y: -200 },
    { x: 200, y: 400 }, { x: 200, y: 400 });
  assert.equal(Math.abs(reset.x), 0);
  assert.equal(Math.abs(reset.y), 0);
});

test('indices and scales tolerate empty galleries and malformed event values', () => {
  assert.equal(viewerIndex(-2, 3), 0);
  assert.equal(viewerIndex(20, 3), 2);
  assert.equal(viewerIndex(2.8, 3), 2);
  assert.equal(viewerIndex(2, 0), 0);
  assert.equal(viewerIndex(Number.NaN, 3), 0);
  assert.equal(viewerScale(Number.NaN), 1);
  assert.equal(viewerScale(Number.POSITIVE_INFINITY), 1);
  assert.equal(viewerScale(0.25), 1);
  assert.equal(viewerScale(8), 5);
});
