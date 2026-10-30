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

function load(name, bindings = {}) {
  const compiled = ts.transpileModule(source(name).replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
    fileName: 'reading-preferences-production.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  const nativeRequire = moduleName => {
    assert.ok(Object.hasOwn(bindings, moduleName), `Unmocked native or network boundary: ${moduleName}`);
    return bindings[moduleName];
  };
  new Function('require', 'module', 'exports', compiled.outputText)(nativeRequire, module, module.exports);
  return module.exports;
}

const models = load('models/ForumModels');
const policy = load('services/ReadingPreferences', { '../models/ForumModels': models });

function settingsRuntime(restored, { unavailable = false, throws = false } = {}) {
  let connectedKey;
  let onError;
  let created;
  const exports = load('models/AppearanceSettings', {
    '../services/ReadingPreferences': policy,
    '@kit.ArkUI': { PersistenceV2: {
      notifyOnError(handler) { onError = handler; },
      globalConnect(options) {
        connectedKey = options.key;
        if (throws) { throw new Error('Fixture storage failure.'); }
        if (unavailable) { return undefined; }
        created = options.defaultCreator();
        return restored ?? created;
      }
    } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } }
  });
  return { ...exports, key: () => connectedKey, created: () => created,
    persistenceError: key => onError(key, 'fixture error') };
}

test('all five persisted feed names round-trip independently of visible labels', () => {
  for (const [index, value] of ['latest', 'new', 'unread', 'hot', 'top'].entries()) {
    assert.equal(policy.defaultTopicFeedIndex(value), index);
    assert.equal(policy.defaultTopicFeedValue(index), value);
  }
  for (const value of ['', undefined, null, 'popular', 'LATEST', 'invalid']) {
    assert.equal(policy.defaultTopicFeedIndex(value), 0);
  }
  for (const index of [-1, 5, 1.5, NaN, Infinity, undefined]) {
    assert.equal(policy.defaultTopicFeedValue(index), 'latest');
  }
});

test('legacy settings gain reading defaults without resetting existing appearance preferences or the storage key', () => {
  const legacy = { effectLevel: 3, reduceMotion: true, highContrast: true, themeMode: 2,
    treeView: false, autoRefresh: true };
  const fixture = settingsRuntime(legacy);
  const settings = fixture.loadAppearanceSettings();
  assert.strictEqual(settings, legacy, 'Keep the connected persistent object identity.');
  assert.equal(fixture.key(), 'appearance_settings_v1');
  assert.deepEqual(settings, { effectLevel: 3, reduceMotion: true, highContrast: true, themeMode: 2,
    treeView: false, autoRefresh: true, defaultFeed: 'latest', immersiveTopics: false, openAtUnread: true });
  assert.strictEqual(fixture.loadAppearanceSettings(), settings, 'Reuse the same global settings object.');
});

test('valid reading preferences survive restoration while malformed stored values recover safely', () => {
  const valid = { effectLevel: 1, reduceMotion: false, highContrast: false, themeMode: 0,
    treeView: true, autoRefresh: false, defaultFeed: 'unread', immersiveTopics: true, openAtUnread: false };
  assert.deepEqual(settingsRuntime(valid).loadAppearanceSettings(), valid);
  const invalid = { effectLevel: 9, reduceMotion: null, highContrast: 'false', themeMode: NaN,
    treeView: null, autoRefresh: 1, defaultFeed: '../latest', immersiveTopics: 'true', openAtUnread: 0 };
  assert.deepEqual(settingsRuntime(invalid).loadAppearanceSettings(), {
    effectLevel: 2, reduceMotion: false, highContrast: false, themeMode: 0,
    treeView: true, autoRefresh: false, defaultFeed: 'latest', immersiveTopics: false, openAtUnread: true
  });
});

test('new and temporarily unavailable storage share usable reading defaults, and failures remain visible', () => {
  for (const options of [{}, { unavailable: true }, { throws: true }]) {
    const fixture = settingsRuntime(undefined, options);
    const settings = fixture.loadAppearanceSettings();
    assert.equal(settings.defaultFeed, 'latest');
    assert.equal(settings.immersiveTopics, false);
    assert.equal(settings.openAtUnread, true);
    assert.equal(fixture.appearanceStorageStatus.available, !options.unavailable && !options.throws);
  }
  const fixture = settingsRuntime();
  const settings = fixture.loadAppearanceSettings();
  settings.defaultFeed = 'top';
  fixture.persistenceError('unrelated_storage');
  assert.equal(fixture.appearanceStorageStatus.available, true);
  fixture.persistenceError('appearance_settings_v1');
  assert.equal(fixture.appearanceStorageStatus.available, false);
  assert.equal(settings.defaultFeed, 'top', 'A storage error must not discard the current selection.');
});

test('bar collapse follows explicit immersion and yields to both accessibility preferences', () => {
  for (const immersiveTopics of [false, true]) {
    for (const reduceMotion of [false, true]) {
      for (const highContrast of [false, true]) {
        assert.equal(policy.shouldCollapseTopicBars(immersiveTopics, reduceMotion, highContrast),
          immersiveTopics && !reduceMotion && !highContrast);
      }
    }
  }
});

test('unread continuation stays inside real server progress and disabled or unknown progress starts at the first post', () => {
  assert.equal(policy.firstUnreadPostNumber(7, 20, true), 8);
  assert.equal(policy.firstUnreadPostNumber(20, 20, true), 20);
  assert.equal(policy.firstUnreadPostNumber(24, 20, true), 20);
  assert.equal(policy.firstUnreadPostNumber(7, 20, false), 1);
  for (const value of [undefined, null, 0, -1, 1.2, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal(policy.firstUnreadPostNumber(value, 20, true), 1);
    assert.equal(policy.firstUnreadPostNumber(7, value, true), 1);
  }
});
