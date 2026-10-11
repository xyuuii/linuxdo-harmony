import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [
  process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required; set DEVECO_TYPESCRIPT_PATH for another installation.');
const ts = require(compiler);
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'EntryAbility.ts',
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((success, failure) => { resolve = success; reject = failure; });
  return { promise, resolve, reject };
}

// Load the complete production ability through allowlisted native-module mocks.
// No startup method is copied or replaced; native window geometry still needs
// a device. Unexpected modules fail instead of reaching network or native I/O.
function startupRuntime(getWindow) {
  const calls = [];
  const logs = [];
  const loaded = deferred();
  const hilog = Object.fromEntries(['info', 'warn', 'error'].map(level => [level,
    (...args) => { logs.push({ level, args }); }
  ]));
  const native = {
    '@kit.AbilityKit': {
      UIAbility: class {},
      ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: 0 } }
    },
    '@kit.PerformanceAnalysisKit': { hilog },
    '@kit.ArkUI': { window: {} },
    '@kit.BasicServicesKit': {}
  };
  const module = { exports: {} };
  const nativeRequire = name => {
    assert.ok(Object.hasOwn(native, name), `Native I/O is prohibited: ${name}`);
    return native[name];
  };
  new Function('require', 'module', 'exports', compiled.outputText)(nativeRequire, module, module.exports);
  const ability = new module.exports.default();
  const stage = {
    getMainWindow() { calls.push(['getMainWindow']); return getWindow(calls); },
    loadContent(route, callback) {
      calls.push(['loadContent', route]);
      callback({ code: 0 });
      loaded.resolve();
    }
  };
  return { ability, stage, calls, logs, loaded: loaded.promise };
}

function assertSafeFallback(logs, expectedCode) {
  const warnings = logs.filter(log => log.level === 'warn');
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].args.at(-1), expectedCode);
  assert.ok(warnings[0].args.every(value => ['number', 'string'].includes(typeof value)),
    'Window fallback logging must not receive the error object.');
  assert.ok(!JSON.stringify(logs).includes('fixture-private-window-details'),
    'Exception text, paths or native response details must not enter startup logs.');
}

test('startup waits for the main window and full-window layout to finish before loading production content', async () => {
  const getting = deferred();
  const layout = deferred();
  const { ability, stage, calls, logs, loaded } = startupRuntime(() => getting.promise);
  ability.onWindowStageCreate(stage);
  assert.deepEqual(calls, [['getMainWindow']]);
  getting.resolve({
    setWindowLayoutFullScreen(enabled) {
      calls.push(['setWindowLayoutFullScreen', enabled]);
      return layout.promise;
    }
  });
  await Promise.resolve();
  assert.deepEqual(calls, [['getMainWindow'], ['setWindowLayoutFullScreen', true]]);
  assert.ok(!calls.some(call => call[0] === 'loadContent'), 'Resolving the main window is not enough to load the page.');
  layout.resolve();
  await loaded;
  assert.deepEqual(calls, [
    ['getMainWindow'], ['setWindowLayoutFullScreen', true], ['loadContent', 'pages/Index']
  ]);
  assert.equal(logs.filter(log => log.level === 'warn' || log.level === 'error').length, 0);
});

test('failure to obtain the main window still loads content and logs only a safe numeric error code', async () => {
  for (const code of [801, undefined]) {
    const error = {
      code,
      message: 'fixture-private-window-details',
      toJSON() { throw new Error('The production fallback must never serialize the native error.'); }
    };
    const { ability, stage, calls, logs, loaded } = startupRuntime(async () => { throw error; });
    ability.onWindowStageCreate(stage);
    await loaded;
    assert.deepEqual(calls, [['getMainWindow'], ['loadContent', 'pages/Index']]);
    assertSafeFallback(logs, code === undefined ? -1 : code);
  }
});

test('failure to apply full-window layout still loads content and never logs the rejected error payload', async () => {
  const error = {
    code: 201,
    message: 'fixture-private-window-details',
    details: { path: 'fixture-private-window-details' },
    toJSON() { throw new Error('The production fallback must never serialize the native error.'); }
  };
  const { ability, stage, calls, logs, loaded } = startupRuntime(async () => ({
    async setWindowLayoutFullScreen(enabled) {
      calls.push(['setWindowLayoutFullScreen', enabled]);
      throw error;
    }
  }));
  ability.onWindowStageCreate(stage);
  await loaded;
  assert.deepEqual(calls, [
    ['getMainWindow'], ['setWindowLayoutFullScreen', true], ['loadContent', 'pages/Index']
  ]);
  assertSafeFallback(logs, 201);
});
