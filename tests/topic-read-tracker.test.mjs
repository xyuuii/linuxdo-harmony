import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = readFileSync(new URL('../app/entry/src/main/ets/services/TopicReadTracker.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
}, reportDiagnostics: true });
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const module = { exports: {} };
new Function('module', 'exports', compiled.outputText)(module, module.exports);
const { TopicReadTracker } = module.exports;
const context = overrides => ({ ownerId: 8, sessionGeneration: 1, topicId: 42, foreground: true, visible: true, ...overrides });
function start(overrides) {
  const tracker = new TopicReadTracker(); tracker.setContext(context(overrides), 0); return tracker;
}
function seconds(tracker, first, last) { for (let now = first; now <= last; now += 1000) { tracker.tick(now); } }

test('only an authenticated foreground visible reader with actual visible rows accrues time', () => {
  for (const state of [{ ownerId: 0 }, { foreground: false }, { visible: false }]) {
    const tracker = start(state); tracker.setPostVisible(1, true, 0); seconds(tracker, 1000, 15000);
    assert.equal(tracker.takeBatch(15000, true), undefined);
  }
  const withoutRows = start(); seconds(withoutRows, 1000, 15000);
  assert.equal(withoutRows.takeBatch(15000, true), undefined);
});

test('wall-clock topic time is counted once while each actually visible post receives its own duration', () => {
  const tracker = start(); tracker.setPostVisible(1, true, 0); tracker.setPostVisible(2, true, 0);
  seconds(tracker, 1000, 14000); assert.equal(tracker.takeBatch(14000), undefined);
  const batch = tracker.takeBatch(15000);
  assert.equal(batch.topicTimeMs, 15000);
  assert.deepEqual(batch.postTimings, [{ postNumber: 1, milliseconds: 15000 }, { postNumber: 2, milliseconds: 15000 }]);
  assert.equal(tracker.takeBatch(15000, true), undefined, 'Taking consumes the batch exactly once; failed writes are not replayed.');
});

test('native visibility transitions credit the former floor only until its actual exit', () => {
  const tracker = start(); tracker.setPostVisible(5, true, 0); tracker.tick(1000);
  tracker.setPostVisible(5, false, 2000); tracker.setPostVisible(9, true, 2000); tracker.tick(3000);
  const batch = tracker.takeBatch(4000, true);
  assert.deepEqual(batch.postTimings, [{ postNumber: 5, milliseconds: 2000 }, { postNumber: 9, milliseconds: 2000 }]);
  assert.equal(batch.topicTimeMs, 4000);
  assert.ok(!batch.postTimings.some(post => [6, 7, 8].includes(post.postNumber)), 'Skipped floors are never fabricated.');
});

test('brief fling appearances, missing rows and long timer gaps never become synthetic reads', () => {
  const tracker = start(); tracker.setPostVisible(1, true, 0); tracker.setPostVisible(1, false, 300);
  assert.equal(tracker.takeBatch(300, true), undefined);
  tracker.setPostVisible(2, true, 300); tracker.tick(20000);
  assert.equal(tracker.takeBatch(20000, true), undefined, 'A delayed callback is not evidence of twenty seconds on screen.');
  tracker.tick(21000); const batch = tracker.takeBatch(21000, true);
  assert.equal(batch.topicTimeMs, 1000); assert.deepEqual(batch.postTimings, [{ postNumber: 2, milliseconds: 1000 }]);
});

test('background and covered intervals stop immediately and resume without backfilling', () => {
  const tracker = start(); tracker.setPostVisible(1, true, 0); tracker.tick(1000);
  tracker.setContext(context({ foreground: false }), 2000); seconds(tracker, 3000, 10000);
  tracker.setContext(context({ foreground: true }), 10000); tracker.tick(11000);
  tracker.setContext(context({ visible: false }), 12000); seconds(tracker, 13000, 20000);
  const batch = tracker.takeBatch(20000, true);
  assert.equal(batch.topicTimeMs, 4000); assert.equal(batch.postTimings[0].milliseconds, 4000);
});

test('account, session generation and topic changes discard former private batches and visible rows', () => {
  for (const change of [{ ownerId: 9 }, { sessionGeneration: 2 }, { topicId: 43 }]) {
    const tracker = start(); tracker.setPostVisible(1, true, 0); tracker.tick(1000);
    const old = tracker.takeBatch(1000, true); assert.equal(tracker.isCurrent(old), true);
    tracker.tick(2000); tracker.setContext(context(change), 2000); tracker.tick(3000);
    assert.equal(tracker.isCurrent(old), false); assert.equal(tracker.takeBatch(3000, true), undefined);
    tracker.setPostVisible(7, true, 3000); tracker.tick(4000);
    const current = tracker.takeBatch(4000, true);
    assert.equal(current.topicTimeMs, 1000); assert.deepEqual(current.postTimings, [{ postNumber: 7, milliseconds: 1000 }]);
  }
});

test('three minutes without actual interaction stop accrual and a new interaction restarts without catch-up', () => {
  const tracker = start(); tracker.setPostVisible(1, true, 0);
  let observed = 0;
  for (let now = 1000; now <= 200000; now += 1000) {
    tracker.tick(now);
    const batch = tracker.takeBatch(now); if (batch) { observed += batch.topicTimeMs; }
  }
  assert.equal(observed, 180000); assert.equal(tracker.takeBatch(200000, true), undefined);
  tracker.recordInteraction(200000); tracker.tick(201000);
  assert.equal(tracker.takeBatch(201000, true).topicTimeMs, 1000);
});

test('per-post six-minute and per-batch sixty-second limits bound legitimate accumulated time', () => {
  const tracker = start(); tracker.setPostVisible(1, true, 0);
  let observed = 0;
  for (let now = 1000; now <= 400000; now += 1000) {
    tracker.recordInteraction(now);
    const batch = tracker.takeBatch(now);
    if (batch) { assert.ok(batch.topicTimeMs <= 60000); observed += batch.postTimings[0].milliseconds; }
  }
  assert.equal(observed, 360000); assert.equal(tracker.takeBatch(400000, true), undefined);
  tracker.setPostVisible(2, true, 400000); tracker.tick(401000);
  assert.deepEqual(tracker.takeBatch(401000, true).postTimings, [{ postNumber: 2, milliseconds: 1000 }]);
});

test('clearing rebuilt rows and reset remove stale floors, timers and consumed identity', () => {
  const tracker = start(); tracker.setPostVisible(4, true, 0); tracker.tick(1000);
  tracker.clearVisiblePosts(2000); tracker.tick(3000);
  const batch = tracker.takeBatch(3000, true); assert.equal(batch.topicTimeMs, 2000);
  tracker.reset(); assert.equal(tracker.isCurrent(batch), false); assert.equal(tracker.takeBatch(4000, true), undefined);
  tracker.setContext(context({ ownerId: NaN }), 4000); assert.equal(tracker.takeBatch(5000, true), undefined);
});
