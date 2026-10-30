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

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    fileName: 'home-topic-feed-production-extract.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const models = load(source('models/ForumModels'));
const readingPreferences = load(source('services/ReadingPreferences').replace(/^import .*;\n/gm, ''), models);
const feedSource = source('components/HomeTopicFeed');
const start = feedSource.indexOf('@ObservedV2\nclass HomeFeedPage');
const end = feedSource.indexOf('  @LocalBuilder', start);
assert.ok(start >= 0 && end > start, 'Execute the production page class and pager methods, not a rewritten policy.');
const feedClass = (feedSource.slice(start, end) + '\n}\n')
  .replace('export struct HomeTopicFeed', 'export class HomeTopicFeed')
  .replace(/^\s*@(?:ObservedV2|ComponentV2|Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local|Trace) /g, '');

// The controller and scroller stand in for native boundaries only. The actual
// production state initialization, selection, prefetch and refresh methods run.
// Follow-finger geometry and platform gesture arbitration stay in device QA.
function runtime({ active = true, mounted = true, reduceMotion = false } = {}) {
  const changes = [];
  const reads = [];
  const exported = load(feedClass, {
    topicFeedFilters: models.topicFeedFilters,
    defaultTopicFeedIndex: readingPreferences.defaultTopicFeedIndex,
    AppearanceSettings: class { reduceMotion = reduceMotion; },
    Scroller: class {
      offset = 0;
      reads = 0;
      currentOffset() { this.reads++; return { xOffset: 0, yOffset: this.offset }; }
    },
    SwiperController: class { changeIndex(index, animate) { changes.push([index, animate]); } }
  });
  const feed = new exported.HomeTopicFeed();
  Object.assign(feed, { active, mounted, onReadScroll: (...args) => reads.push(args) });
  const prefetched = () => feed.pages.filter(page => feed.shouldPrefetch(page.index)).map(page => page.index);
  return { feed, changes, reads, prefetched };
}

test('tab clicks ask native Swiper to animate without changing the bound page before the native callback', () => {
  const { feed, changes } = runtime();
  feed.selectFilter(1);
  assert.deepEqual(changes, [[1, true]]);
  assert.equal(feed.filterIndex, 0, 'Changing the bound index now would jump before the controller animation.');
  assert.equal(feed.targetIndex, 1);
  feed.animationStarted(1);
  assert.equal(feed.filterIndex, 0);
  feed.pageChanged(1);
  assert.equal(feed.filterIndex, 1);
  assert.equal(feed.targetIndex, 1);
  feed.selectFilter(1);
  assert.equal(changes.length, 1, 'The already settled page needs no second native transition.');
});

test('reduce motion disables the requested transition without changing target or neighboring-page prefetch', () => {
  const regular = runtime();
  const reduced = runtime({ reduceMotion: true });
  regular.feed.selectFilter(4); reduced.feed.selectFilter(4);
  assert.deepEqual(regular.changes, [[4, true]]);
  assert.deepEqual(reduced.changes, [[4, false]]);
  assert.equal(reduced.feed.filterIndex, 0);
  assert.deepEqual(reduced.prefetched(), regular.prefetched());
  assert.deepEqual(reduced.prefetched(), [0, 1, 4]);
  regular.feed.pageChanged(4); reduced.feed.pageChanged(4);
  assert.deepEqual(reduced.prefetched(), regular.prefetched());
  assert.deepEqual(reduced.prefetched(), [3, 4]);
});

test('the five page objects and their independent scrollers retain identity and position across navigation', () => {
  const { feed } = runtime();
  const pages = [...feed.pages];
  const scrollers = pages.map(page => page.scroller);
  assert.equal(pages.length, 5);
  assert.equal(new Set(pages).size, 5);
  assert.equal(new Set(scrollers).size, 5);
  assert.deepEqual(pages.map(page => page.index), [0, 1, 2, 3, 4]);
  scrollers.forEach((scroller, index) => { scroller.offset = (index + 1) * 137; });
  for (const index of [1, 2, 4, 3, 0, 4]) {
    feed.selectFilter(index); feed.animationStarted(index); feed.pageChanged(index); feed.animationEnded(index);
    feed.refreshTopSignal++; feed.refreshCurrentFromTop();
    feed.pages.forEach((page, slot) => {
      assert.strictEqual(page, pages[slot]);
      assert.strictEqual(page.scroller, scrollers[slot]);
      assert.equal(page.scroller.currentOffset().yOffset, (slot + 1) * 137);
    });
  }
});

test('only current neighbors and a remote click target prefetch, and hidden or unmounted parents prefetch nothing', () => {
  const { feed, prefetched, changes } = runtime();
  assert.deepEqual(prefetched(), [0, 1]);
  feed.selectFilter(4);
  assert.deepEqual(prefetched(), [0, 1, 4], 'The remote target starts before the selected page changes.');
  feed.pageChanged(2);
  assert.deepEqual(prefetched(), [1, 2, 3]);
  feed.animationStarted(4);
  assert.deepEqual(prefetched(), [1, 2, 3, 4]);
  feed.active = false;
  assert.deepEqual(prefetched(), []);
  feed.selectFilter(0);
  assert.equal(changes.length, 1);
  feed.active = true; feed.mounted = false;
  assert.deepEqual(prefetched(), []);
  feed.selectFilter(0);
  assert.equal(changes.length, 1);
  feed.mounted = true;
  assert.deepEqual(prefetched(), [1, 2, 3, 4]);
});

test('page changes and interrupted animation endings use the real settled index, not the original request', () => {
  const { feed, changes, prefetched } = runtime();
  feed.selectFilter(4);
  feed.animationStarted(4);
  assert.equal(feed.filterIndex, 0);
  feed.animationEnded(2);
  assert.equal(feed.filterIndex, 2);
  assert.equal(feed.targetIndex, 2);
  assert.deepEqual(prefetched(), [1, 2, 3]);
  feed.selectFilter(2);
  assert.equal(changes.length, 1);
  feed.pageChanged(0);
  assert.equal(feed.filterIndex, 0); assert.equal(feed.targetIndex, 0);
  feed.pageChanged(4);
  assert.equal(feed.filterIndex, 4); assert.equal(feed.targetIndex, 4);
});

test('invalid native or tab indices never alter selection, target or request a native jump', () => {
  const { feed, changes } = runtime();
  feed.pageChanged(2);
  for (const index of [-1, 5, 1.5, NaN, Infinity, -Infinity]) {
    feed.selectFilter(index); feed.animationStarted(index); feed.pageChanged(index); feed.animationEnded(index);
    assert.equal(feed.filterIndex, 2); assert.equal(feed.targetIndex, 2);
  }
  assert.deepEqual(changes, []);
});

test('refresh-top increments only the currently settled page signal and consumes every outer signal once', () => {
  const { feed } = runtime();
  feed.pageChanged(2);
  feed.selectFilter(4);
  feed.refreshTopSignal = 1; feed.refreshCurrentFromTop();
  assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 1, 0, 0]);
  feed.refreshCurrentFromTop();
  assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 1, 0, 0]);
  feed.pageChanged(4); feed.refreshCurrentFromTop();
  assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 1, 0, 0]);
  feed.refreshTopSignal = 2; feed.refreshCurrentFromTop();
  assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 1, 0, 1]);
  feed.refreshTopSignal = 1; feed.refreshCurrentFromTop();
  assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 1, 0, 1]);
});

test('refresh requests while inactive or unmounted coalesce into one refresh of the page active on return', () => {
  for (const property of ['active', 'mounted']) {
    const { feed } = runtime();
    feed.pageChanged(1); feed[property] = false;
    for (const signal of [1, 2, 3]) {
      feed.refreshTopSignal = signal; feed.refreshCurrentFromTop();
    }
    assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 0, 0, 0]);
    feed.pageChanged(3); feed[property] = true; feed.refreshCurrentFromTop();
    assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 0, 1, 0]);
    feed.refreshCurrentFromTop(); feed[property] = false; feed[property] = true; feed.refreshCurrentFromTop();
    assert.deepEqual(feed.pages.map(page => page.refreshSignal), [0, 0, 0, 1, 0]);
  }
});

test('scroll notifications use the selected page native origin including the real top inset and measured overlay header', () => {
  for (const topInset of [0, 38.85, 56]) {
    const { feed, reads } = runtime();
    feed.topInset = topInset;
    feed.measureHeader(112);
    feed.pageChanged(3);
    feed.pages[0].scroller.offset = 0;
    feed.pages[3].scroller.offset = 500;
    feed.readPageScroll(feed.pages[0], 30, 1, 2);
    assert.deepEqual(reads, []);
    assert.equal(feed.pages[0].scroller.reads, 0, 'A hidden old homepage must not influence navigation.');
    feed.readPageScroll(feed.pages[3], 30, 1, 2);
    assert.deepEqual(reads, [[30, 1, 2, false]]);
    feed.pages[0].scroller.offset = 500;
    feed.pages[3].scroller.offset = -feed.contentTopInset + 1;
    feed.readPageScroll(feed.pages[3], -30, 2, 1);
    feed.pages[3].scroller.offset = -feed.contentTopInset - 5;
    feed.readPageScroll(feed.pages[3], -3, 2, 1);
    assert.deepEqual(reads, [[30, 1, 2, false], [-30, 2, 1, true], [-3, 2, 1, true]]);
    feed.pages[3].scroller.offset = -feed.contentTopInset + 1.01;
    feed.readPageScroll(feed.pages[3], 1, 1, 2);
    assert.deepEqual(reads.at(-1), [1, 1, 2, false]);
    assert.equal(feed.pages[0].scroller.reads, 0);
  }
});

test('overlay header measurements update the native content origin without replacing pages or their scroll state', () => {
  const { feed } = runtime();
  const pages = [...feed.pages];
  feed.topInset = 38.85;
  feed.pages[0].scroller.offset = 420;
  const original = feed.contentTopInset;
  for (const invalid of [0, -1, NaN, Infinity]) { feed.measureHeader(invalid); }
  assert.equal(feed.contentTopInset, original);
  feed.measureHeader(112);
  assert.equal(feed.contentTopInset, 150.85);
  feed.measureHeader(112.2);
  assert.equal(feed.contentTopInset, 150.85, 'Subpixel area noise must not keep invalidating every list origin.');
  feed.topInset = 56;
  assert.equal(feed.contentTopInset, 168, 'Window avoid-area changes remain separate from the content header height.');
  feed.pages.forEach((page, index) => assert.strictEqual(page, pages[index]));
  assert.equal(feed.pages[0].scroller.offset, 420);
});

test('inactive and unmounted pager scroll callbacks neither read native scroll state nor notify navigation', () => {
  for (const property of ['active', 'mounted']) {
    const { feed, reads } = runtime();
    feed.pageChanged(2); feed[property] = false;
    feed.readPageScroll(feed.pages[2], 100, 1, 2);
    assert.deepEqual(reads, []);
    assert.equal(feed.pages[2].scroller.reads, 0);
  }
});

test('configured default feed is applied once and returning home preserves the selected list', () => {
  const { feed } = runtime({ mounted: false });
  feed.appearance.defaultFeed = 'unread';
  feed.appear();
  assert.equal(feed.filterIndex, 2);
  assert.equal(feed.targetIndex, 2);
  feed.pageChanged(4);
  feed.mounted = false;
  feed.appear();
  assert.equal(feed.filterIndex, 4);
});

test('switching account discards private taxonomy names and scope without resetting the selected feed', () => {
  const { feed } = runtime();
  Object.assign(feed, { selectedCategoryId: 123, selectedCategoryName: 'Fixture private category',
    selectedTag: 'fixture-private-tag', showTaxonomy: true, filterIndex: 2, targetIndex: 2 });
  feed.accountChanged();
  assert.equal(feed.selectedCategoryId, 0);
  assert.equal(feed.selectedCategoryName, '');
  assert.equal(feed.selectedTag, '');
  assert.equal(feed.showTaxonomy, false);
  assert.equal(feed.filterIndex, 2);
});
