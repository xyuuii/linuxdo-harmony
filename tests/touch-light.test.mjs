import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
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
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/TouchLightState.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source.replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
  fileName: 'touch-light-production-extract.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const forbidden = () => { throw new Error('Touch tracking must not intercept gestures or use device/network I/O.'); };
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const module = { exports: {} };
new Function('module', 'exports', 'require', 'TouchType', compiled.outputText)
  (module, module.exports, forbidden, TouchType);
const { TouchLightState } = module.exports;

function point(id, windowX, windowY, x = 0, y = 0) {
  return { id, windowX, windowY, x, y, displayX: windowX + 1000, displayY: windowY + 2000 };
}
function event(type, touches = [], changedTouches = touches) {
  return { type, touches, changedTouches, stopPropagation: forbidden, preventDefault: forbidden,
    getHistoricalPoints: forbidden };
}
function state() {
  const light = new TouchLightState();
  light.setArea(320, 56, 20, 700);
  return light;
}
function dark(light) {
  assert.equal(light.active, false);
  assert.equal(light.x, 0);
  assert.equal(light.y, 0);
}

test('window coordinates keep the light continuous across differently positioned child buttons', () => {
  const light = state();
  light.update(event(TouchType.Down, [point(7, 55, 719, 35, 19)]), true);
  assert.equal(light.active, true);
  assert.equal(light.x, 35);
  assert.equal(light.y, 19);
  // The second child's local x restarts at 5; the common material still follows window x.
  light.update(event(TouchType.Move, [point(7, 105, 721, 5, 21)]), true);
  assert.equal(light.x, 85);
  assert.equal(light.y, 21);
  for (let windowX = 106; windowX <= 325; windowX++) {
    light.update(event(TouchType.Move, [point(7, windowX, 721, windowX % 80, 21)]), true);
    assert.equal(light.active, true);
    assert.equal(light.x, windowX - 20);
  }
});

test('the first finger retains ownership when other fingers arrive, move and lift', () => {
  const light = state();
  const first = point(3, 70, 720);
  const second = point(8, 280, 744);
  light.update(event(TouchType.Down, [first], [first]), true);
  light.update(event(TouchType.Down, [second, first], [second]), true);
  assert.equal(light.x, 50, 'Array reordering and a new Down cannot steal the light.');
  light.update(event(TouchType.Move, [point(8, 310, 750), point(3, 80, 728)], [point(8, 310, 750)]), true);
  assert.equal(light.x, 60);
  assert.equal(light.y, 28);
  light.update(event(TouchType.Up, [point(3, 80, 728)], [second]), true);
  assert.equal(light.active, true);
  assert.equal(light.x, 60);
  light.update(event(TouchType.Up, [second], [point(3, 80, 728)]), true);
  dark(light);
  light.update(event(TouchType.Move, [second], [second]), true);
  dark(light);
  light.update(event(TouchType.Down, [second], [second]), true);
  assert.equal(light.active, true, 'Only a new Down acquires a new primary finger.');
  assert.equal(light.x, 260);
});

test('Up, Cancel and disabling extinguish the light without touching event propagation', () => {
  const light = state();
  for (const end of [event(TouchType.Up, [], [point(1, 80, 725)]), event(TouchType.Up),
    event(TouchType.Cancel, [point(1, 80, 725)])]) {
    light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
    light.update(end, true);
    dark(light);
  }
  light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
  light.update(event(TouchType.Move, [point(1, 90, 725)]), false);
  dark(light);
  light.update(event(TouchType.Move, [point(1, 100, 725)]), true);
  dark(light);
});

test('a missing primary finger or empty point list cannot leave a stale light', () => {
  const light = state();
  for (const move of [event(TouchType.Move), event(TouchType.Move, [point(2, 200, 730)]),
    event(TouchType.Move, [], [point(1, 80, 725)])]) {
    light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
    light.update(move, true);
    dark(light);
  }
  light.update(event(TouchType.Down, [point(1, 80, 725)], []), true);
  dark(light);
  light.update(event(TouchType.Down, [], [point(1, 80, 725)]), true);
  dark(light);
});

test('out-of-surface points clamp to the capsule bounds while fractional vp remains precise', () => {
  const light = state();
  light.update(event(TouchType.Down, [point(1, -100, 900)]), true);
  assert.equal(light.x, 0);
  assert.equal(light.y, 56);
  light.update(event(TouchType.Move, [point(1, 900, -100)]), true);
  assert.equal(light.x, 320);
  assert.equal(light.y, 0);
  light.update(event(TouchType.Move, [point(1, 30.25, 704.75)]), true);
  assert.equal(light.x, 10.25);
  assert.equal(light.y, 4.75);
});

test('unchanged area retains the light, but resizing or moving invalidates its coordinates', () => {
  const light = state();
  light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
  light.setArea(320, 56, 20, 700);
  assert.equal(light.active, true);
  light.setArea(52, 52, 280, 700);
  dark(light);
  light.update(event(TouchType.Move, [point(1, 300, 725)]), true);
  dark(light);
  light.update(event(TouchType.Down, [point(1, 300, 725)]), true);
  assert.equal(light.x, 20);
  assert.equal(light.y, 25);
  light.setArea(52, 52, 280, 704);
  dark(light);
});

test('invalid area or non-finite touch coordinates never enter observable UI state', () => {
  const light = state();
  for (const args of [[0, 56, 20, 700], [-1, 56, 20, 700], [NaN, 56, 20, 700],
    [320, Infinity, 20, 700], [320, 56, Infinity, 700], [320, 56, 20, NaN]]) {
    light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
    light.setArea(...args);
    dark(light);
    light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
    dark(light);
    light.setArea(320, 56, 20, 700);
  }
  for (const invalid of [point(1, NaN, 720), point(1, 80, Infinity), point(Infinity, 80, 720),
    point(0.5, 80, 720)]) {
    light.update(event(TouchType.Down, [invalid]), true);
    dark(light);
  }
  light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
  light.update(event(TouchType.Move, [point(1, Infinity, 725)]), true);
  dark(light);
  light.setArea(320, 56, -Number.MAX_VALUE, 700);
  light.update(event(TouchType.Down, [point(1, Number.MAX_VALUE, 725)]), true);
  dark(light);
});

test('explicit clearing resets ownership and unknown event types fail closed', () => {
  const light = state();
  light.update(event(TouchType.Down, [point(1, 80, 725)]), true);
  light.clear();
  dark(light);
  light.update(event(TouchType.Down, [point(2, 100, 730)]), true);
  assert.equal(light.x, 80);
  light.update(event(999, [point(2, 110, 730)]), true);
  dark(light);
});
