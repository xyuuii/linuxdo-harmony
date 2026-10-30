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
    fileName: 'topic-back-control-production-extract.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const topicSource = source('pages/TopicPage');
const declarations = extract(topicSource, 'export interface TopicTreeRow', '@ComponentV2');
const page = (extract(topicSource, 'export struct TopicPage', '  @Builder\n') + '\n}\n')
  .replace('export struct TopicPage', 'export class TopicPage')
  .replace(/^\s*@Computed\s*\n/gm, '\n')
  .replace(/^\s*@Monitor\([\s\S]*?\)\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');
const { TopicScrollPolicy } = load(source('services/TopicScrollPolicy'));

function runtime() {
  const forbidden = () => { throw new Error('Native, device and network I/O is prohibited in this fixture.'); };
  const appearance = { effectLevel: 2, reduceMotion: false, highContrast: false, themeMode: 0 };
  class Scroller {
    edgeCalls = [];
    scrollEdge(...args) { this.edgeCalls.push(args); }
  }
  const { TopicPage } = load(declarations + '\n' + page, {
    forumSession: { user: { id: 7 }, revision: 1 }, loadAppearanceSettings: () => appearance,
    TopicScrollPolicy, Scroller, $r: id => ({ id }), Edge: { Top: 'top' },
    forumApi: { fetchTopic: forbidden, fetchPosts: forbidden }, http: { createHttp: forbidden },
    fileIo: { open: forbidden }, picker: { DocumentViewPicker: forbidden },
    photoAccessHelper: { getPhotoAccessHelper: forbidden }, setTimeout: forbidden, clearTimeout: forbidden
  });
  const reader = new TopicPage();
  reader.getUIContext = forbidden;
  return { reader, appearance };
}

test('unified reader controls remain expanded for both accessibility preferences', () => {
  const { reader, appearance } = runtime();
  reader.toolbarExpanded = false;
  assert.equal(reader.readerToolsVisible, false);
  assert.equal(reader.readerSurfaceWidth, 52);
  for (const preference of ['reduceMotion', 'highContrast']) {
    appearance[preference] = true;
    assert.equal(reader.readerToolsVisible, true);
    assert.ok(reader.readerSurfaceWidth > 52);
    appearance[preference] = false;
  }
});

test('the persistent bookmark targets the real first post even when a later floor is being read', () => {
  const { reader } = runtime();
  const first = { id: 7, postNumber: 1 };
  reader.posts = [{ id: 91, postNumber: 33 }, first, { id: 21, postNumber: 5 }];
  reader.currentNumber = 33;
  const bookmarked = [];
  reader.bookmark = post => { bookmarked.push(post); };
  reader.bookmarkPrimaryPost();
  assert.deepEqual(bookmarked, [first]);
  reader.posts = [{ id: 91, postNumber: 33 }];
  reader.bookmarkPrimaryPost();
  assert.equal(bookmarked.length, 1, 'Missing first-post data must not silently bookmark the current reply.');
});

test('manual collapse dismisses floor navigation and resets scroll accumulation before reopening', () => {
  const { reader } = runtime();
  reader.showJump = true;
  reader.scrollPolicy.update(20, true, false, false);
  reader.toggleReaderTools();
  assert.equal(reader.showJump, false); assert.equal(reader.toolbarExpanded, false);
  assert.equal(reader.scrollPolicy.update(13, true, false, false), undefined,
    'The new control state must not inherit a former drag distance.');
  reader.toggleReaderTools();
  assert.equal(reader.toolbarExpanded, true);
});

test('back-to-top keeps the loading/write guards and reloads the true first slice before moving from a tail page', () => {
  const { reader, appearance } = runtime();
  reader.currentNumber = 33;
  for (const state of ['loading', 'writeBusy']) {
    reader[state] = true; reader.backToTopicTop(); reader[state] = false;
  }
  assert.deepEqual(reader.scroller.edgeCalls, []);
  reader.sliceStart = 40;
  const jumps = [];
  reader.jump = number => { jumps.push(number); };
  reader.backToTopicTop();
  assert.deepEqual(jumps, [1]); assert.deepEqual(reader.scroller.edgeCalls, []);
  reader.sliceStart = 0; reader.highlightedId = 71;
  appearance.reduceMotion = true;
  reader.backToTopicTop();
  assert.deepEqual(reader.scroller.edgeCalls, [['top']]);
  assert.equal(reader.currentNumber, 1); assert.equal(reader.highlightedId, 0);
});
