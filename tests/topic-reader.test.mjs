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
const scroll = load(source('services/TopicScrollPolicy'));
const ScrollSource = { NONE: 0, DRAG: 1, FLING: 2, OTHER_USER_INPUT: 3, SCROLLER: 4, SCROLLER_ANIMATION: 5 };
const ScrollState = { Idle: 0, Scroll: 1, Fling: 2 };
const declarations = extract(topicSource, 'export interface TopicTreeRow', '@ComponentV2');
const prefix = extract(topicSource, 'export struct TopicPage', '  @Builder\n');
// Include the actual viewer-close and native-Back closures from build(), so the
// tests exercise the same closing paths while avoiding ArkUI builder syntax.
const close = /onClose: \(\): void => \{([^\n]*)\}/.exec(topicSource);
const back = /\.onBackPressed\(\(\): boolean => \{([^\n]*)\}/.exec(topicSource);
const hide = /\.onHidden\(\(\) => \{([\s\S]*?)\}\)/.exec(topicSource);
const shown = /\.onShown\(\(\) => \{([\s\S]*?)\}\)/.exec(topicSource);
assert.ok(close && back && hide && shown, 'Production viewer-close, native-Back and navigation lifecycle handlers must remain extractable.');
const pageClass = (prefix + `\ncloseFromViewer(): void {${close[1]}}\nbackFromViewer(): boolean {${back[1]}}` +
  `\nhideFromNavigation(): void {${hide[1]}}\nshowFromNavigation(): void {${shown[1]}}\n}\n`)
  .replace('export struct TopicPage', 'export class TopicPage')
  .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');

function readerRuntime() {
  const timers = [];
  const cancelledTimers = [];
  let timerId = 0;
  const reads = [];
  const bars = [];
  const animations = [];
  const session = { user: { id: 7 }, revision: 1 };
  const prohibited = () => { throw new Error('Native I/O is prohibited in reader method tests.'); };
  const exports = load(declarations + '\n' + pageClass, {
    forumSession: session,
    loadAppearanceSettings: () => ({}),
    parsePostContent: rich.parsePostContent,
    postContentUrl: rich.postContentUrl,
    ...scroll,
    ScrollSource,
    ScrollState,
    curves: { springMotion: (...args) => ({ spring: args }) },
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
      edgeCalls = [];
      atEnd = false;
      currentOffset() { this.captures++; return { ...this.offset }; }
      isAtEnd() { return this.atEnd; }
      scrollTo(value) { this.restores.push(value); this.offset = { xOffset: value.xOffset, yOffset: value.yOffset }; }
      scrollToIndex(...args) { this.indexCalls.push(args); }
      scrollEdge(...args) { this.edgeCalls.push(args); }
    },
    ScrollAlign: { START: 'start' },
    Edge: { Top: 'top' },
    window: { getLastWindow: async () => ({ setWindowSystemBarProperties: async value => { bars.push(value); } }) },
    $r: id => ({ id }),
    setTimeout(callback, delay) { const id = ++timerId; timers.push({ id, callback, delay }); return id; },
    clearTimeout(id) {
      cancelledTimers.push(id);
      const index = timers.findIndex(timer => timer.id === id);
      if (index >= 0) { timers.splice(index, 1); }
    }
  });
  const page = new exports.TopicPage();
  page.getUIContext = () => ({
    getHostContext: () => ({
      resourceManager: { getColorSync: id => id.endsWith('page_background') ? 0xfff4f5f8 : 0xff11151d }
    }),
    animateTo(options, callback) { animations.push(options); callback(); options.onFinish?.(); }
  });
  page.reload = number => { reads.push(number); };
  const layout = () => { while (timers.length > 0) { timers.shift().callback(); } };
  return { page, session, timers, cancelledTimers, reads, bars, animations, layout };
}

function imagePost(id, cooked) {
  return { id, postNumber: id, topicId: 100, cooked, replyToPostNumber: 0, replyCount: 0 };
}

test('same-floor edit refreshes data once, ordinary floor navigation only jumps and shown consumes pending refresh', () => {
  const { page, reads } = readerRuntime();
  const jumps = [];
  page.jump = number => { jumps.push(number); };
  page.entered = true;
  page.postNumber = 147;
  page.lastInputNumber = 147;
  page.currentNumber = 147;
  page.reloadSignal = 1;
  page.targetNumberChanged();
  assert.deepEqual(reads, [147], 'Editing an already loaded floor must re-fetch it, not only locate its old row.');
  assert.deepEqual(jumps, []);
  assert.equal(page.handledReloadSignal, 1);
  page.targetNumberChanged();
  assert.deepEqual(reads, [147], 'The consumed refresh and unchanged target must not perform a second request.');
  assert.deepEqual(jumps, []);

  page.postNumber = 148;
  page.targetNumberChanged();
  assert.deepEqual(jumps, [148]);
  assert.deepEqual(reads, [147], 'Changing only the target keeps normal cached-floor navigation.');
  page.postNumber = 149;
  page.reloadSignal = 2;
  page.targetNumberChanged();
  assert.deepEqual(reads, [147, 149]);
  assert.deepEqual(jumps, [148], 'A coalesced target and refresh change has one reload path.');

  page.hidden = true;
  page.reloadSignal = 3;
  page.currentNumber = 155;
  page.targetNumberChanged();
  assert.deepEqual(reads, [147, 149]);
  page.showFromNavigation();
  assert.deepEqual(reads, [147, 149, 149], 'Returning to a hidden editor result refreshes its floor instead of an unrelated scroll position.');
  assert.equal(page.handledReloadSignal, 3);
  page.targetNumberChanged();
  assert.deepEqual(reads, [147, 149, 149]);

  const initial = readerRuntime();
  initial.page.postNumber = 7;
  initial.page.reloadSignal = 4;
  initial.page.showFromNavigation();
  initial.page.targetNumberChanged();
  assert.deepEqual(initial.reads, [7], 'First onShown synchronizes the incoming signal before a queued monitor runs.');

  for (const busyField of ['loading', 'writeBusy']) {
    const delayed = readerRuntime();
    delayed.page.entered = true;
    delayed.page.lastInputNumber = 147;
    delayed.page.postNumber = 148;
    delayed.page.reloadSignal = 1;
    delayed.page[busyField] = true;
    delayed.page.targetNumberChanged();
    assert.deepEqual(delayed.reads, [], `${busyField} must defer the refresh request.`);
    assert.equal(delayed.page.handledReloadSignal, 0, 'A deferred signal must remain unconsumed.');
    assert.equal(delayed.page.lastInputNumber, 147, 'A deferred target must remain pending too.');
    delayed.page[busyField] = false;
    delayed.page.targetNumberChanged();
    assert.deepEqual(delayed.reads, [148], `${busyField} completion must consume the pending signal once.`);
    assert.equal(delayed.page.handledReloadSignal, 1);
    assert.equal(delayed.page.lastInputNumber, 148);
    delayed.page[busyField] = true;
    delayed.page.targetNumberChanged();
    delayed.page[busyField] = false;
    delayed.page.targetNumberChanged();
    assert.deepEqual(delayed.reads, [148], 'Busy transitions without new input cannot repeat a consumed refresh.');

    const targetOnly = readerRuntime();
    const deferredJumps = [];
    targetOnly.page.jump = number => { deferredJumps.push(number); };
    targetOnly.page.entered = true;
    targetOnly.page.postNumber = 9;
    targetOnly.page[busyField] = true;
    targetOnly.page.targetNumberChanged();
    assert.deepEqual(deferredJumps, []);
    assert.equal(targetOnly.page.lastInputNumber, 1);
    targetOnly.page[busyField] = false;
    targetOnly.page.targetNumberChanged();
    assert.deepEqual(deferredJumps, [9], 'Ordinary floor navigation must also wait until the reader is not busy.');
    assert.deepEqual(targetOnly.reads, []);
  }
});

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

function endedTopic(page) {
  page.topic = { postStream: { stream: [1, 2] }, canReply: true, closed: false, archived: false };
  page.posts = [imagePost(1, '<p>original</p>'), imagePost(2, '<p>tail</p>')];
  page.sliceEnd = 1;
  page.consumed = [1, 2];
  page.scroller.offset.yOffset = 800;
}

test('reader toolbar thresholds use traveled distance from the negative title-aware list origin', () => {
  for (const topInset of [0, 38.85, 56]) {
    const { page } = readerRuntime();
    page.topInset = topInset;
    const nativeStart = -(topInset + 56);
    page.scroller.offset.yOffset = nativeStart + 2;
    page.readScroll(20, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(page.toolbarExpanded, true);
    page.scroller.offset.yOffset = nativeStart + 22;
    assert.ok(page.scroller.offset.yOffset < 0, 'A moved list may legitimately retain a negative native offset.');
    page.readScroll(12, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(page.toolbarExpanded, false, '32 vp of forward reading must collapse even before native offset reaches zero.');

    page.scroller.offset.yOffset = nativeStart + 54;
    page.readScroll(-8, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(page.toolbarExpanded, false);
    page.scroller.offset.yOffset = nativeStart + 46;
    page.readScroll(-8, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(page.toolbarExpanded, true, '16 vp of reverse reading must restore the controls.');

    page.toolbarExpanded = false;
    page.scroller.offset.yOffset = nativeStart;
    page.readScroll(-1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(page.toolbarExpanded, true, 'Returning to the actual negative origin must reveal the controls.');
  }
});

test('end feedback requires a new upward DRAG after the true topic end, never arrival, FLING or a programmatic scroll', () => {
  const { page, timers, animations } = readerRuntime();
  endedTopic(page);
  assert.equal(page.topicEnded, true);
  page.readScroll(80, ScrollState.Scroll, ScrollSource.DRAG);
  page.scroller.atEnd = true;
  page.settleReaderScroll();
  assert.equal(page.endFeedbackProgress, 0, 'First arrival at the last item is not an extra upward pull.');
  assert.equal(page.endHintTimer, 0);
  for (const [state, source] of [
    [ScrollState.Scroll, ScrollSource.SCROLLER], [ScrollState.Scroll, ScrollSource.SCROLLER_ANIMATION],
    [ScrollState.Scroll, ScrollSource.FLING], [ScrollState.Fling, ScrollSource.FLING],
    [ScrollState.Fling, ScrollSource.DRAG], [ScrollState.Scroll, ScrollSource.OTHER_USER_INPUT]
  ]) {
    page.readScroll(40, state, source);
    assert.equal(page.endFeedbackProgress, 0);
    assert.equal(page.endHintTimer, 0);
  }
  page.readScroll(16, ScrollState.Scroll, ScrollSource.DRAG);
  assert.equal(page.endFeedbackProgress, 0.25);
  page.readScroll(48, ScrollState.Scroll, ScrollSource.DRAG);
  assert.equal(page.endFeedbackProgress, 1);
  page.settleReaderScroll();
  assert.equal(timers.at(-1).delay, 3200);
  assert.ok(animations.length > 0);
  page.readScroll(-1, ScrollState.Scroll, ScrollSource.DRAG);
  assert.equal(page.endFeedbackProgress, 0, 'Reading upwards dismisses the hint and its timer.');
  assert.equal(page.endHintTimer, 0);
  assert.deepEqual(timers, []);

  for (const preventEnd of [
    reader => { reader.topic = undefined; },
    reader => { reader.posts = []; },
    reader => { reader.topic.postStream.stream.push(3); },
    reader => { reader.loading = true; },
    reader => { reader.error = 'fixture read failure'; }
  ]) {
    const { page: reader } = readerRuntime();
    endedTopic(reader);
    reader.scroller.atEnd = true;
    preventEnd(reader);
    assert.equal(reader.topicEnded, false);
    reader.readScroll(64, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(reader.endFeedbackProgress, 0);
    assert.equal(reader.endHintTimer, 0);
  }
});

test('return to top reloads the initial slice when only a retained root remains, otherwise scrolls to the exact origin', () => {
  const { page, reads } = readerRuntime();
  endedTopic(page);
  page.sliceStart = 30;
  page.currentNumber = 48;
  page.posts = [imagePost(1, '<p>retained root</p>'), imagePost(48, '<p>tail</p>')];
  page.backToTopicTop();
  assert.deepEqual(reads, [1], 'A retained original post does not supply its omitted first-page replies.');
  assert.deepEqual(page.scroller.restores, [], 'The tail window must reload before positioning the reader.');
  assert.deepEqual(page.scroller.edgeCalls, [], 'An edge jump cannot replace the missing initial slice.');

  for (const [topInset, reduceMotion] of [[0, false], [0, true], [38.85, false], [38.85, true], [56, false], [56, true]]) {
    const { page: head, reads: headReads } = readerRuntime();
    endedTopic(head);
    head.topInset = topInset;
    head.appearance.reduceMotion = reduceMotion;
    head.sliceStart = 0;
    head.currentNumber = 2;
    head.highlightedId = 2;
    head.backToTopicTop();
    assert.deepEqual(headReads, []);
    assert.equal(head.currentNumber, 1);
    assert.equal(head.highlightedId, 0);
    assert.deepEqual(head.scroller.restores, [], 'A numeric zero jump is not the title-aware list origin.');
    assert.equal(head.scroller.edgeCalls.length, 1);
    const edge = head.scroller.edgeCalls[0];
    assert.equal(edge[0], 'top');
    if (reduceMotion) { assert.equal(edge.length, 1, 'Reduced motion uses the native immediate edge jump without velocity.'); }
    else { assert.deepEqual(edge[1], { velocity: 1200 }, 'Normal motion returns smoothly to the true native edge.'); }
  }
});

test('leaving the reader, opening an image and switching accounts cancel the end-hint timer and clear feedback', () => {
  for (const leave of ['navigation', 'picture', 'account']) {
    const { page, session, timers, cancelledTimers, layout } = readerRuntime();
    endedTopic(page);
    page.scroller.atEnd = true;
    page.readScroll(32, ScrollState.Scroll, ScrollSource.DRAG);
    page.settleReaderScroll();
    const pendingTimer = page.endHintTimer;
    assert.ok(pendingTimer > 0);
    assert.ok(timers.some(timer => timer.id === pendingTimer));
    if (leave === 'navigation') { page.hideFromNavigation(); assert.equal(page.hidden, true); }
    else if (leave === 'picture') { page.picture('/uploads/fullscreen.png'); assert.equal(page.showPicture, true); }
    else {
      session.user = { id: 9 };
      session.revision++;
      page.accountChanged();
      assert.equal(page.toolbarExpanded, true);
    }
    assert.equal(page.endHintTimer, 0);
    assert.equal(page.endFeedbackProgress, 0);
    assert.equal(page.endPullDistance, 0);
    assert.ok(cancelledTimers.includes(pendingTimer));
    assert.ok(!timers.some(timer => timer.id === pendingTimer));
    layout();
    assert.equal(page.endFeedbackProgress, 0, 'A cancelled callback must not revive a hidden or former-account hint.');
  }
});
