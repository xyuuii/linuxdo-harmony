import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Execute production reader methods with the installed compiler. ArkUI layout
// and native image/photo I/O remain part of device acceptance, not this harness.
const require = createRequire(import.meta.url);
const compiler = [
  process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required; set DEVECO_TYPESCRIPT_PATH for another installation.');
const ts = require(compiler);
const sourceRoot = fileURLToPath(new URL('../app/entry/src/main/ets/', import.meta.url));
const source = name => readFileSync(path.join(sourceRoot, name + '.ets'), 'utf8');

function extract(value, startMarker, endMarker) {
  const start = value.indexOf(startMarker);
  const end = value.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Production source extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value.replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
    fileName: 'topic-reader-production-extract.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length,
    0, 'Extracted production methods must transpile. Full ArkTS compilation is verified separately.');
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const topicSource = source('pages/TopicPage');
const richSource = source('components/RichPostContent');
const rich = load(extract(richSource, 'export interface PostInline', '@ComponentV2'));
const declarations = extract(topicSource, 'export interface TopicTreeRow', '@ComponentV2');
const prefix = extract(topicSource, 'export struct TopicPage', '  @Builder\n');
// Include the actual viewer-close and native-Back closures from build(), so the
// tests exercise the same closing paths while avoiding ArkUI builder syntax.
const close = /onClose: \(\): void => \{([^\n]*)\}/.exec(topicSource);
const back = /\.onBackPressed\(\(\): boolean => \{([^\n]*)\}/.exec(topicSource);
assert.ok(close && back, 'Production viewer-close and native-Back handlers must remain extractable.');
const pageClass = (prefix + `\ncloseFromViewer(): void {${close[1]}}\nbackFromViewer(): boolean {${back[1]}}\n}\n`)
  .replace('export struct TopicPage', 'export class TopicPage')
  .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');

function readerRuntime() {
  const timers = [];
  const reads = [];
  const bars = [];
  const session = { user: { id: 7 }, revision: 1 };
  const prohibited = () => { throw new Error('Native I/O is prohibited in reader method tests.'); };
  const exports = load(declarations + '\n' + pageClass, {
    forumSession: session,
    loadAppearanceSettings: () => ({}),
    parsePostContent: rich.parsePostContent,
    postContentUrl: rich.postContentUrl,
    forumApi: { fetchTopic: prohibited, fetchPosts: prohibited, getUserAgent: prohibited },
    http: { createHttp: prohibited }, fileIo: { open: prohibited },
    picker: { DocumentViewPicker: prohibited },
    photoAccessHelper: { getPhotoAccessHelper: prohibited },
    webview: { WebCookieManager: { fetchCookie: prohibited } },
    Scroller: class {
      offset = { xOffset: 0, yOffset: 0 };
      captures = 0;
      restores = [];
      indexCalls = [];
      currentOffset() { this.captures++; return { ...this.offset }; }
      scrollTo(value) { this.restores.push(value); this.offset = { xOffset: value.xOffset, yOffset: value.yOffset }; }
      scrollToIndex(...args) { this.indexCalls.push(args); }
    },
    ScrollAlign: { START: 'start' },
    window: { getLastWindow: async () => ({ setWindowSystemBarProperties: async value => { bars.push(value); } }) },
    $r: id => ({ id }),
    setTimeout(callback, delay) { timers.push({ callback, delay }); return timers.length; }
  });
  const page = new exports.TopicPage();
  page.getUIContext = () => ({ getHostContext: () => ({
    resourceManager: { getColorSync: id => id.endsWith('page_background') ? 0xfff4f5f8 : 0xff11151d }
  }) });
  page.reload = number => { reads.push(number); };
  const layout = () => { while (timers.length > 0) { timers.shift().callback(); } };
  return { page, session, timers, reads, bars, layout };
}

function imagePost(id, cooked) {
  return { id, postNumber: id, topicId: 100, cooked, replyToPostNumber: 0, replyCount: 0 };
}

test('a floor gallery deduplicates original images and excludes emoji, insecure pictures and other floors', () => {
  const { page } = readerRuntime();
  const current = imagePost(2,
    '<a href="/uploads/original.png"><img src="/uploads/optimized.png"></a>' +
    '<img src="/uploads/original.png"><img src="/uploads/second.jpg">' +
    '<img class="emoji" src="/images/emoji/smile.png" alt=":smile:">' +
    '<img class="emoji-custom" src="/uploads/custom-emoji.png" alt=":custom:">' +
    '<img src="http://images.example.test/insecure.png">' +
    '<iframe><img src="https://images.example.test/hidden.png"></iframe>');
  page.posts = [current, imagePost(3, '<img src="/uploads/other-floor.jpg">')];
  page.picture('https://linux.do/uploads/second.jpg', current);
  assert.deepEqual(page.pictureUrls, [
    'https://linux.do/uploads/original.png', 'https://linux.do/uploads/second.jpg'
  ]);
  assert.equal(page.pictureInitialIndex, 1);
  assert.equal(page.pictureUrl, 'https://linux.do/uploads/second.jpg');
  assert.equal(page.showPicture, true);
});

test('a standalone image does not reuse a previous floor gallery and unsafe clicks never open the viewer', () => {
  const { page } = readerRuntime();
  page.picture('/uploads/first.png', imagePost(2, '<img src="/uploads/first.png"><img src="/uploads/second.png">'));
  page.closeFromViewer();
  page.picture('https://images.example.test/standalone.png');
  assert.deepEqual(page.pictureUrls, ['https://images.example.test/standalone.png']);
  assert.equal(page.pictureInitialIndex, 0);
  page.closeFromViewer();
  const captures = page.scroller.captures;
  page.picture('javascript:alert(1)', imagePost(3, '<img src="/uploads/ignored.png">'));
  assert.equal(page.showPicture, false);
  assert.equal(page.scroller.captures, captures, 'A rejected click must not capture or disturb the reader position.');
  assert.ok(page.error.length > 0);
});

test('opening captures the exact reader offset and both close paths restore it after layout without a reload', () => {
  for (const closePath of ['closeFromViewer', 'backFromViewer']) {
    const { page, timers, reads, layout } = readerRuntime();
    page.scroller.offset.yOffset = 2468.5;
    page.picture('/uploads/read.png', imagePost(8, '<img src="/uploads/read.png">'));
    assert.equal(page.pictureScrollOffset, 2468.5);
    page.pictureVisibilityChanged();
    // Simulate the larger image-overlay viewport clipping the retained List's
    // maximum offset near its end, before the title bar becomes visible again.
    page.scroller.offset.yOffset = 2412.5;
    const consumed = page[closePath]();
    if (closePath === 'backFromViewer') { assert.equal(consumed, true); }
    assert.equal(page.showPicture, false);
    page.pictureVisibilityChanged();
    assert.equal(timers.at(-1).delay, 30);
    assert.deepEqual(page.scroller.restores, [], 'Position restoration must wait for the title-bar layout.');
    layout();
    assert.deepEqual(page.scroller.restores, [{ xOffset: 0, yOffset: 2468.5, animation: false }]);
    assert.equal(page.scroller.offset.yOffset, 2468.5);
    assert.deepEqual(reads, [], 'Closing an image must not reload or reposition by a numbered floor.');
    assert.deepEqual(page.scroller.indexCalls, []);
    assert.equal(page.backFromViewer(), false, 'A second Back must use the normal topic navigation.');
  }
});

test('a pending close restoration cannot scroll a newly opened viewer or a hidden reader', () => {
  for (const interruption of ['reopen', 'hide']) {
    const { page, layout } = readerRuntime();
    page.scroller.offset.yOffset = 100;
    page.picture('/uploads/first.png');
    page.closeFromViewer();
    page.pictureVisibilityChanged();
    if (interruption === 'reopen') { page.picture('/uploads/second.png'); }
    else { page.hidden = true; }
    layout();
    assert.deepEqual(page.scroller.restores, []);
  }
});

test('account change clears the private floor gallery and saved offset before reloading for the new account', () => {
  const { page, session, reads, layout } = readerRuntime();
  page.entered = true;
  page.currentNumber = 8;
  page.scroller.offset.yOffset = 900;
  page.picture('/uploads/private-b.png', imagePost(8,
    '<img src="/uploads/private-a.png"><img src="/uploads/private-b.png">'));
  assert.equal(page.pictureInitialIndex, 1);
  session.user = { id: 9 };
  session.revision++;
  // ArkUI normally invokes this production monitor for the observed revision.
  page.accountChanged();
  assert.equal(page.showPicture, false);
  assert.equal(page.pictureUrl, '');
  assert.deepEqual(page.pictureUrls, []);
  assert.equal(page.pictureInitialIndex, 0);
  assert.equal(page.pictureScrollOffset, 0);
  assert.deepEqual(page.posts, []);
  assert.equal(page.topic, undefined);
  assert.equal(page.topicOwnerId, 0);
  assert.deepEqual(reads, [8]);
  page.pictureVisibilityChanged();
  layout();
  assert.deepEqual(page.scroller.restores, [{ xOffset: 0, yOffset: 0, animation: false }],
    'Account changes must not restore the prior account\'s private reading offset.');
});

test('stable floor rows update collapse, expansion and reactions in place without rekeying local input state', () => {
  const productionKey = /\}, \(row: TopicTreeRow\): string => ([^\n]+)\)/.exec(topicSource);
  assert.ok(productionKey, 'The production LazyForEach row key must remain extractable.');
  const { TopicRowsSource, topicTreeRows, rowKey } = load(declarations +
    '\nexport { TopicRowsSource };\n' +
    `export const rowKey = (row: TopicTreeRow): string => ${productionKey[1]};\n`);
  const data = new TopicRowsSource();
  let reloads = 0;
  data.registerDataChangeListener({ onDataReloaded() { reloads++; } });
  const root = { ...imagePost(2, '<p>root</p>'), replyCount: 2, reactions: [] };
  const posts = [imagePost(1, '<p>original</p>'), root,
    { ...imagePost(3, '<p>child A</p>'), replyToPostNumber: 2 },
    { ...imagePost(4, '<p>child B</p>'), replyToPostNumber: 2 }];

  data.update(topicTreeRows(posts, [2], [], true));
  const retained = data.getData(1);
  const retainedKey = rowKey(retained);
  // A component's local input belongs to its stable LazyForEach key. This
  // checks the data/key contract; native @Local rendering is verified on-device.
  const localInput = new Map([[retainedKey, { boostDraft: '未发送的简评' }]]);
  assert.equal(data.totalCount(), 4);
  assert.equal(retained.lastInGroup, false);
  assert.equal(retained.shownReplies, 2);

  data.update(topicTreeRows(posts, [2], [2], true));
  assert.strictEqual(data.getData(1), retained, 'Collapse must update the cached row, not replace its identity.');
  assert.equal(data.totalCount(), 2);
  assert.equal(retained.lastInGroup, true, 'The old row reference must now expose the expand control.');
  assert.equal(retained.shownReplies, 0);
  assert.equal(retained.loadedReplies, 2);
  assert.equal(rowKey(retained), retainedKey);

  data.update(topicTreeRows(posts, [2], [], true));
  assert.strictEqual(data.getData(1), retained);
  assert.equal(data.totalCount(), 4);
  assert.equal(retained.lastInGroup, false);
  assert.equal(retained.shownReplies, 2);
  assert.equal(retained.loadedReplies, 2);

  const reacted = { ...root, reactions: [{ id: 'heart', count: 1 }],
    currentUserReaction: { id: 'heart', canUndo: true } };
  data.update(topicTreeRows([posts[0], reacted, posts[2], posts[3]], [2], [], true));
  assert.strictEqual(data.getData(1), retained, 'Updating the post must preserve the observed row object.');
  assert.strictEqual(retained.post, reacted, 'The retained row must expose the newly returned post/reaction data.');
  assert.equal(retained.post.reactions[0].count, 1);
  assert.equal(rowKey(retained), retainedKey, 'Reaction updates must not remount the floor by changing its key.');
  assert.equal(localInput.get(rowKey(retained)).boostDraft, '未发送的简评');
  assert.equal(reloads, 4);
});
