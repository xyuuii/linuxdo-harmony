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
const source = name => readFileSync(fileURLToPath(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url)), 'utf8');
function load(value, bindings) {
  const compiled = ts.transpileModule(value.replace(/^import .*;\n/gm, '').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

// SDK enum values from @ohos.multimodalAwareness.motion, including UNKNOWN=16.
const HoldingHandStatus = { NOT_HELD: 0, LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2, BOTH_HANDS_HELD: 3, UNKNOWN_STATUS: 16 };
function runtime(options = {}) {
  const subscriptions = []; const unsubscriptions = [];
  const logs = [];
  const motion = { HoldingHandStatus,
    on(type, callback) { if (options.onError) { throw { code: options.onError }; } subscriptions.push({ type, callback }); },
    off(type, callback) { unsubscriptions.push({ type, callback }); if (options.offError) { throw { code: options.offError }; } }
  };
  const exports = load(source('services/HandednessState'), {
    motion, hilog: { info: (...values) => logs.push(values) },
    canIUse: capability => { assert.equal(capability, 'SystemCapability.MultimodalAwareness.Motion'); return options.supported !== false; }
  });
  return { ...exports, state: exports.handednessState, subscriptions, unsubscriptions, options, logs };
}

test('only actual left/right holding states move the collapsed side; uncertain states preserve the previous side', () => {
  const { sideLeftForHolding } = runtime();
  assert.equal(sideLeftForHolding(false, HoldingHandStatus.LEFT_HAND_HELD), true);
  assert.equal(sideLeftForHolding(true, HoldingHandStatus.RIGHT_HAND_HELD), false);
  for (const previous of [false, true]) {
    for (const status of [HoldingHandStatus.NOT_HELD, HoldingHandStatus.BOTH_HANDS_HELD, HoldingHandStatus.UNKNOWN_STATUS, 99, NaN]) {
      assert.equal(sideLeftForHolding(previous, status), previous);
    }
  }
});

test('foreground subscription is idempotent and background removal uses the exact callback', () => {
  const { state, subscriptions, unsubscriptions, HandednessAvailability } = runtime();
  state.start(); state.start();
  assert.equal(subscriptions.length, 1); assert.equal(subscriptions[0].type, 'holdingHandChanged');
  assert.equal(state.availability, HandednessAvailability.Listening);
  subscriptions[0].callback(HoldingHandStatus.LEFT_HAND_HELD); assert.equal(state.sideLeft, true);
  state.stop(); state.stop();
  assert.equal(unsubscriptions.length, 1);
  assert.equal(unsubscriptions[0].type, 'holdingHandChanged');
  assert.equal(unsubscriptions[0].callback, subscriptions[0].callback);
  subscriptions[0].callback(HoldingHandStatus.RIGHT_HAND_HELD);
  assert.equal(state.sideLeft, true, 'A queued native callback after background must not update layout.');
  assert.equal(state.availability, HandednessAvailability.Idle);
});

test('resuming allows new true sensor results while rejecting callbacks from a previous foreground generation', () => {
  const { state, subscriptions } = runtime();
  state.start(); subscriptions[0].callback(HoldingHandStatus.LEFT_HAND_HELD);
  state.stop(); state.start(); assert.equal(subscriptions.length, 2);
  subscriptions[1].callback(HoldingHandStatus.RIGHT_HAND_HELD); assert.equal(state.sideLeft, false);
  subscriptions[0].callback(HoldingHandStatus.LEFT_HAND_HELD); assert.equal(state.sideLeft, false);
  subscriptions[1].callback(HoldingHandStatus.BOTH_HANDS_HELD); assert.equal(state.sideLeft, false);
  state.stop();
});

test('missing syscap, unsupported 801 and permission 201 keep the safe default without active registrations', () => {
  for (const options of [{ supported: false }, { onError: 801 }, { onError: 201 }]) {
    const { state, subscriptions, unsubscriptions, HandednessAvailability } = runtime(options);
    state.start(); state.start();
    assert.equal(state.sideLeft, false); assert.equal(subscriptions.length, 0);
    assert.equal(state.lastErrorCode, options.onError || 801);
    assert.equal(state.availability, options.onError === 201 ? HandednessAvailability.Unavailable : HandednessAvailability.Unsupported);
    state.stop(); assert.equal(unsubscriptions.length, 0);
  }
});

test('an unsubscribe failure does not create duplicate registrations and late callbacks stay ignored', () => {
  const { state, subscriptions, unsubscriptions, options } = runtime({ offError: 31500003 });
  state.start(); subscriptions[0].callback(HoldingHandStatus.LEFT_HAND_HELD); state.stop();
  subscriptions[0].callback(HoldingHandStatus.RIGHT_HAND_HELD); assert.equal(state.sideLeft, true);
  state.start(); assert.equal(subscriptions.length, 1, 'A lingering registration must be removed before creating another.');
  assert.equal(unsubscriptions.length, 2); assert.equal(state.lastErrorCode, 31500003);
  options.offError = 0; state.stop(); state.start();
  assert.equal(subscriptions.length, 2); assert.equal(state.lastErrorCode, 0);
  state.stop();
});

test('EntryAbility starts in foreground and stops on background, stage destruction and ability destruction', () => {
  const events = [];
  const exports = load(source('entryability/EntryAbility'), {
    UIAbility: class {}, handednessState: { start: () => events.push('start'), stop: () => events.push('stop') },
    hilog: { info() {} }, forumApi: { setForeground: active => events.push(active ? 'network-foreground' : 'network-background') }
  });
  const ability = new exports.default();
  ability.onForeground(); ability.onBackground(); ability.onWindowStageDestroy(); ability.onDestroy();
  assert.deepEqual(events, ['network-foreground', 'start', 'network-background', 'stop', 'stop', 'stop']);
});

test('diagnostic status reports current real callback separately from a retained button side', () => {
  const { state, subscriptions } = runtime();
  assert.equal(state.diagnosticText(), '等待应用前台连接');
  state.start();
  assert.equal(state.diagnosticText(), '已连接系统，等待握持');
  const callback = subscriptions[0].callback;
  callback(HoldingHandStatus.LEFT_HAND_HELD);
  assert.equal(state.diagnosticText(), '当前左手握持');
  callback(HoldingHandStatus.BOTH_HANDS_HELD);
  assert.equal(state.diagnosticText(), '双手握持，保持按钮位置');
  assert.equal(state.sideLeft, true);
  callback(HoldingHandStatus.UNKNOWN_STATUS);
  assert.equal(state.diagnosticText(), '未识别握持，保持按钮位置');
  callback(HoldingHandStatus.NOT_HELD);
  assert.equal(state.diagnosticText(), '未握持，保持按钮位置');
  callback(HoldingHandStatus.RIGHT_HAND_HELD);
  assert.equal(state.diagnosticText(), '当前右手握持');
  callback(HoldingHandStatus.LEFT_HAND_HELD);
  state.stop(); state.start();
  assert.equal(state.sideLeft, true, 'Keep the safe layout choice while awaiting the new foreground result.');
  assert.equal(state.holdingStatus, HoldingHandStatus.UNKNOWN_STATUS);
  assert.equal(state.diagnosticText(), '已连接系统，等待握持');
});

test('diagnostic errors and logs expose status codes without messages or account data', () => {
  const unsupported = runtime({ onError: 801 });
  unsupported.state.start();
  assert.equal(unsupported.state.diagnosticText(), '当前设备暂不支持（801）');
  const denied = runtime({ onError: 201 });
  denied.state.start();
  assert.equal(denied.state.diagnosticText(), '暂不可用（201）');
  const { state, subscriptions, logs } = runtime();
  state.start();
  subscriptions[0].callback(HoldingHandStatus.LEFT_HAND_HELD);
  state.stop();
  const count = logs.length;
  subscriptions[0].callback(HoldingHandStatus.RIGHT_HAND_HELD);
  assert.equal(logs.length, count, 'Ignore stale callbacks in observation as well as layout.');
  assert.deepEqual(logs.map(values => values[3]), ['subscribe', 'event', 'unsubscribe', 'stop']);
  for (const values of [...logs, ...unsupported.logs, ...denied.logs]) {
    assert.equal(values[1], 'LinuxDoGrip');
    assert.equal(values.length, 8);
    assert.equal(typeof values[5], 'number');
    assert.equal(typeof values[6], 'number');
    assert.ok(['left', 'right'].includes(values[7]));
  }
});
