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
const source = name => readFileSync(fileURLToPath(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url)), 'utf8');

function extract(value, startMarker, endMarker) {
  const start = value.indexOf(startMarker);
  const end = value.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Production source extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value.replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
    fileName: 'composer-sheet-production-extract.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const indexSource = source('pages/Index');
const routeClass = extract(indexSource, '@ObservedV2\nclass ForumRoute', '@Entry');
// Stop before replyEditor's ArkUI builder rather than taking every method up
// to openLogin. The production route and control methods execute unchanged.
const methods = [
  extract(indexSource, '  private compose(', '  @Builder\n  replyEditor'),
  extract(indexSource, '  private openLogin(', '  private openNotifications('),
  extract(indexSource, '  private pushRoute(', '  private openTopic('),
  extract(indexSource, '  private setNavigationCollapsed(', '  private rootVisibilityChanged(')
].join('\n');
const { TopicScrollPolicy } = load(source('services/TopicScrollPolicy'));
const UIKeyboardAvoidMode = { OFFSET: 'offset', RESIZE: 'resize', NONE: 'none' };

function sheetRuntime(loggedIn = true) {
  const session = { user: loggedIn ? { id: 7 } : undefined };
  const toasts = [];
  const pathCalls = [];
  const keyboardModes = [];
  const forbidden = () => { throw new Error('Native I/O is prohibited in composer sheet control tests.'); };
  const { ForumRoute, IndexComposer } = load(routeClass +
    `\nexport class IndexComposer {\n${methods}\n}\nexport { ForumRoute };`, {
    forumSession: session,
    UIKeyboardAvoidMode,
    ProfileSection: { Summary: 'summary' },
    forumApi: new Proxy({}, { get: forbidden }),
    window: { getLastWindow: forbidden },
    webview: { WebCookieManager: { fetchCookie: forbidden } }
  });
  const topic = new ForumRoute();
  topic.topicId = 100;
  topic.postNumber = 8;
  topic.replyRevision = 3;
  const paths = [{ name: 'topic', param: topic }];
  const index = new IndexComposer();
  Object.assign(index, {
    showComposer: false, composerRoute: undefined,
    composerDismissSignal: 0, composerDismissAllowed: true,
    mainPageVisible: false, navigationCollapsed: false,
    navigationScrollPolicy: new TopicScrollPolicy(),
    appearance: { reduceMotion: false, highContrast: false },
    paths: {
      pushPath(route) { pathCalls.push(route); paths.push(route); },
      pop: forbidden, clear: forbidden
    },
    getUIContext: () => ({
      setKeyboardAvoidMode: mode => { keyboardModes.push(mode); },
      getPromptAction: () => ({ showToast: options => { toasts.push(options); } })
    })
  });
  return { index, topic, paths, pathCalls, session, toasts, keyboardModes, ForumRoute };
}

// These are parent control/lifecycle tests, not SDK sheet rendering tests.
// Draft confirmation, attachments and async submission remain owned by the
// real ComposerPage; no forum write or native preference operation runs here.
test('opening a composer preserves the current topic route and cannot replace an already retained sheet scene', () => {
  const { index, topic, paths, pathCalls, keyboardModes, ForumRoute } = sheetRuntime();
  index.compose(100, 8, 0, topic);
  const scene = index.composerRoute;
  assert.ok(scene instanceof ForumRoute);
  assert.equal(index.showComposer, true);
  assert.equal(scene.topicId, 100);
  assert.equal(scene.replyTo, 8);
  assert.equal(scene.postId, 0);
  assert.strictEqual(scene.returnTopic, topic);
  assert.deepEqual(pathCalls, [], 'Replying must not push a composer route or hide/reload its originating topic.');
  assert.equal(paths.length, 1);
  assert.strictEqual(paths[0].param, topic);
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET]);

  const other = new ForumRoute();
  other.topicId = 200;
  index.composerDismissSignal = 4;
  index.composerDismissAllowed = false;
  index.compose(200, 11, 23, other);
  assert.strictEqual(index.composerRoute, scene, 'A second tap must not replace the component holding a draft.');
  assert.equal(index.composerDismissSignal, 4);
  assert.equal(index.composerDismissAllowed, false);
  assert.deepEqual(pathCalls, []);
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET], 'A retained sheet must not change the keyboard policy on repeated taps.');
});

test('busy or unconfirmed dismissal retains content, and the scene is cleared only after closing has disappeared', () => {
  const { index, topic, toasts, keyboardModes } = sheetRuntime();
  index.requestComposerDismiss();
  assert.equal(index.composerDismissSignal, 0);
  index.compose(100, 0, 0, topic);
  const scene = index.composerRoute;
  index.composerDismissAllowed = false;
  index.requestComposerDismiss();
  assert.equal(index.showComposer, true);
  assert.strictEqual(index.composerRoute, scene);
  assert.equal(index.composerDismissSignal, 0);
  assert.equal(toasts.length, 1);
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET], 'Busy dismissal must keep the active sheet keyboard policy.');

  index.composerDismissAllowed = true;
  index.requestComposerDismiss();
  assert.equal(index.composerDismissSignal, 1, 'Allowed close attempts ask the child to confirm rather than clearing it.');
  assert.equal(index.showComposer, true);
  assert.strictEqual(index.composerRoute, scene, 'Cancelling the child confirmation keeps the current scene mounted.');
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET]);
  index.closeComposer(); // The production child onDone callback reaches this method.
  assert.equal(index.showComposer, false);
  assert.strictEqual(index.composerRoute, scene, 'The scene stays available throughout the native exit animation.');
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET], 'onDone must not resize the background page while the sheet is still exiting.');
  index.composerDisappeared();
  assert.equal(index.showComposer, false);
  assert.equal(index.composerRoute, undefined);
  assert.equal(index.composerDismissSignal, 0);
  assert.equal(index.composerDismissAllowed, true);
  assert.deepEqual(keyboardModes, [UIKeyboardAvoidMode.OFFSET, UIKeyboardAvoidMode.RESIZE],
    'Restore the ordinary page keyboard policy only after the native sheet disappeared.');
});

test('only a successful submission updates the originating floor and reply revision, while cancellation leaves both unchanged', () => {
  const { index, topic, paths, pathCalls } = sheetRuntime();
  index.compose(100, 0, 0, topic);
  index.requestComposerDismiss();
  index.closeComposer();
  index.composerDisappeared();
  assert.equal(topic.postNumber, 8);
  assert.equal(topic.replyRevision, 3);
  index.composerSubmitted(99);
  assert.equal(topic.postNumber, 8, 'A callback after the scene was cleared has no originating route to update.');

  index.compose(100, 8, 0, topic);
  index.composerSubmitted(27);
  assert.equal(topic.postNumber, 27);
  assert.equal(topic.replyRevision, 4, 'The existing TopicPage receives a refresh signal without a route round trip.');
  index.closeComposer();
  index.composerDisappeared();
  index.compose(100, 27, 400, topic);
  index.composerSubmitted(27);
  assert.equal(topic.postNumber, 27);
  assert.equal(topic.replyRevision, 5, 'Editing the same floor still refreshes the retained topic even when postNumber is unchanged.');
  assert.strictEqual(paths[0].param, topic);
  assert.deepEqual(pathCalls, []);
});

test('a signed-out compose action opens the existing login flow without creating a sheet scene', () => {
  const { index, topic, paths, pathCalls, keyboardModes, ForumRoute } = sheetRuntime(false);
  index.compose(100, 8, 0, topic);
  assert.equal(index.showComposer, false);
  assert.equal(index.composerRoute, undefined);
  assert.equal(index.composerDismissSignal, 0);
  assert.equal(index.loginOwnerId, 0);
  assert.equal(pathCalls.length, 1);
  assert.equal(pathCalls[0].name, 'login');
  assert.ok(pathCalls[0].param instanceof ForumRoute);
  assert.equal(paths.length, 2);
  assert.strictEqual(paths[0].param, topic);
  assert.deepEqual(keyboardModes, [], 'Signing in first must not enable the composer-specific keyboard policy.');
});
