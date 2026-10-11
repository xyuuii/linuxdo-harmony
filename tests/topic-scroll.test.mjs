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
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/TopicScrollPolicy.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
}, reportDiagnostics: true });
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const policy = { exports: {} };
new Function('exports', 'module', compiled.outputText)(policy.exports, policy);
const { TopicScrollPolicy, endPullProgress, canShowTopicEnd } = policy.exports;

test('continuous forward and backward reading use exact accumulated thresholds', () => {
  const scroll = new TopicScrollPolicy();
  assert.equal(scroll.update(15, true, false, false), undefined);
  assert.equal(scroll.update(16, true, false, false), undefined);
  assert.equal(scroll.update(0, true, false, false), undefined);
  assert.equal(scroll.update(1, true, false, false), false);
  assert.equal(scroll.update(-15, true, false, false), undefined);
  assert.equal(scroll.update(-1, true, false, false), true);
  assert.equal(scroll.update(50, true, false, false), false);
  assert.equal(scroll.update(-50, true, false, false), true);
});

test('reversing direction resets accumulation instead of cancelling the prior travel', () => {
  const scroll = new TopicScrollPolicy();
  assert.equal(scroll.update(31, true, false, false), undefined);
  assert.equal(scroll.update(-8, true, false, false), undefined);
  assert.equal(scroll.update(-8, true, false, false), true);
  assert.equal(scroll.update(-15, true, false, false), undefined);
  assert.equal(scroll.update(20, true, false, false), undefined);
  assert.equal(scroll.update(12, true, false, false), false);
});

test('programmatic jumps, blocked interactions and invalid deltas reset pending decisions', () => {
  for (const [offset, userDriven, blocked] of [[1000, false, false], [1000, true, true], [NaN, true, false]]) {
    const scroll = new TopicScrollPolicy();
    assert.equal(scroll.update(31, true, false, false), undefined);
    assert.equal(scroll.update(offset, userDriven, false, blocked), undefined);
    assert.equal(scroll.update(1, true, false, false), undefined);
    assert.equal(scroll.update(31, true, false, false), false);
  }
});

test('returning to the beginning reveals controls and explicit reset clears their pending threshold', () => {
  const scroll = new TopicScrollPolicy();
  assert.equal(scroll.update(31, true, false, false), undefined);
  assert.equal(scroll.update(-1, true, true, false), true);
  assert.equal(scroll.update(1, true, false, false), undefined);
  scroll.reset();
  assert.equal(scroll.update(31, true, false, false), undefined);
  assert.equal(scroll.update(1, true, false, false), false);
  assert.equal(scroll.update(10, true, true, true), undefined, 'A modal remains blocked even at the beginning.');
  assert.equal(scroll.update(10, false, true, false), undefined, 'A programmatic jump cannot decide toolbar visibility.');
});

test('end pull shows proportional short feedback and saturates at 64 vp', () => {
  assert.equal(endPullProgress(-20), 0);
  assert.equal(endPullProgress(0), 0);
  assert.equal(endPullProgress(8), 0.125);
  assert.equal(endPullProgress(32), 0.5);
  assert.equal(endPullProgress(64), 1);
  assert.equal(endPullProgress(200), 1);
  assert.equal(endPullProgress(NaN), 0);
  assert.equal(endPullProgress(Infinity), 1);
});

test('end hint requires a real loaded topic with no remaining page, loading or error', () => {
  assert.equal(canShowTopicEnd(true, 1, 0, false, false), true);
  assert.equal(canShowTopicEnd(false, 1, 0, false, false), false);
  assert.equal(canShowTopicEnd(true, 0, 0, false, false), false);
  assert.equal(canShowTopicEnd(true, 20, 3, false, false), false);
  assert.equal(canShowTopicEnd(true, 20, 0, true, false), false);
  assert.equal(canShowTopicEnd(true, 20, 0, false, true), false);
  assert.equal(canShowTopicEnd(true, NaN, 0, false, false), false);
  assert.equal(canShowTopicEnd(true, 20, -1, false, false), false);
});
