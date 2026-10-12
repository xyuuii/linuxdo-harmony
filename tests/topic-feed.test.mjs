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
  const compiled = ts.transpileModule(value.replace(/^import .*;\n/gm, ''), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const presentation = load(source('services/TopicFeedPresentation'));
const models = load(source('models/ForumModels'));
const feedSource = source('components/TopicFeed');
const start = feedSource.indexOf('export struct TopicFeed');
const end = feedSource.indexOf('  @LocalBuilder', start);
assert.ok(start >= 0 && end > start, 'Execute actual production feed methods, not an alternate implementation.');
const feedClass = (feedSource.slice(start, end) + '\n}\n')
  .replace('export struct TopicFeed', 'export class TopicFeed')
  .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');

function runtime() {
  const requests = [];
  const categoryRequests = [];
  const timers = new Map();
  let nextTimer = 0;
  const fetch = (kind, page, token) => new Promise((resolve, reject) => { requests.push({ kind, page, token, resolve, reject }); });
  class RequestCancellation { cancelled = false; cancel() { this.cancelled = true; } }
  class ForumApiError extends Error { kind = 'network'; }
  const exported = load(feedClass, {
    ...presentation, ...models,
    AppearanceSettings: class { autoRefresh = false; },
    Scroller: class { edges = []; position = 0; scrollEdge(edge) { this.edges.push(edge); this.position = 0; } },
    Edge: { Top: 'top' }, RequestCancellation, ForumApiError,
    ForumErrorKind: { VerificationRequired: 'verification', AuthenticationRequired: 'authentication' },
    setInterval: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearInterval: id => { timers.delete(id); },
    forumApi: { fetchTopicFeed: (filter, page, token) => fetch(filter, page, token),
      fetchCategoryTopics: (_, __, page, token) => fetch('category', page, token),
      fetchCategories: () => new Promise((resolve, reject) => { categoryRequests.push({ resolve, reject }); }) }
  });
  const createFeed = (filterIndex = 0, active = true, prefetch = false) => {
    const feed = new exported.TopicFeed();
    Object.assign(feed, { filterIndex, active, prefetch });
    return feed;
  };
  return { feed: createFeed(), createFeed, requests, categoryRequests, timers, ForumApiError };
}

const item = (id, pinned = false) => ({ topic: { id, title: `Topic ${id}`, pinned, unseen: true }, authorUsername: `u${id}` });
const flush = () => new Promise(resolve => setImmediate(resolve));
async function finish(request, items, hasMore = true) {
  request.resolve({ items, hasMore });
  await flush();
}
const ids = feed => feed.items.map(value => value.topic.id);

function policy(feed, active, prefetch = false) {
  Object.assign(feed, { active, prefetch });
  feed.onRefreshPolicy();
}

test('current and neighboring feeds fetch independent first pages, then reuse data and scroll position on selection', async () => {
  const { feed, createFeed, requests } = runtime();
  const next = createFeed(1, false, true);
  feed.appear(); next.appear();
  assert.deepEqual(requests.map(request => [request.kind, request.page]), [['latest', 0], ['new', 0]]);
  await finish(requests[0], [item(1)]); await finish(requests[1], [item(2)]);
  feed.listScroller.position = 340; next.listScroller.position = 90;
  policy(feed, false, true); policy(next, true);
  assert.equal(requests.length, 2, 'Activating an already prefetched page must not clear or reload it.');
  assert.deepEqual(ids(feed), [1]); assert.deepEqual(ids(next), [2]);
  assert.equal(feed.listScroller.position, 340); assert.equal(next.listScroller.position, 90);
  policy(next, false, true); policy(feed, true);
  assert.equal(requests.length, 2); assert.equal(feed.listScroller.position, 340);
});

test('all five fixed instances request their own real feed without sharing data', async () => {
  const { createFeed, requests } = runtime();
  const feeds = Array.from({ length: 5 }, (_, index) => createFeed(index, index === 0, index > 0));
  feeds.forEach(feed => feed.appear());
  assert.deepEqual(requests.map(request => request.kind), ['latest', 'new', 'unread', 'hot', 'top']);
  for (let index = 4; index >= 0; index--) { await finish(requests[index], [item(index + 1)]); }
  assert.deepEqual(feeds.map(ids), [[1], [2], [3], [4], [5]]);
});

test('distant pages do no work until prefetched and cannot paginate, refresh, or signal scroll while inactive', async () => {
  const { feed, requests } = runtime();
  feed.active = false; feed.appear();
  assert.equal(requests.length, 0);
  policy(feed, false, true); assert.equal(requests.length, 1);
  await finish(requests[0], [item(1)]);
  feed.loadNextPage(); feed.refreshFromPull(); void feed.load(false); void feed.load(true);
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop();
  const scrolls = []; feed.onReadScroll = (...args) => scrolls.push(args);
  assert.deepEqual(feed.readScroll(20, 1, 2), { offsetRemain: 20 });
  assert.equal(requests.length, 1); assert.deepEqual(scrolls, []); assert.equal(feed.refreshing, false);
  policy(feed, true);
  assert.equal(requests.length, 1, 'An inactive refresh signal must not surprise a later selected page.');
  feed.readScroll(30, 1, 2); assert.deepEqual(scrolls, [[30, 1, 2]]);
});

test('losing selection to a neighboring prefetch lets initial data finish without restarting its request', async () => {
  const { feed, requests } = runtime();
  feed.appear(); policy(feed, false, true);
  assert.equal(requests[0].token.cancelled, false); assert.equal(requests.length, 1);
  await finish(requests[0], [item(1)]);
  policy(feed, true);
  assert.equal(requests.length, 1); assert.deepEqual(ids(feed), [1]);
});

test('a distant in-flight first page is cancelled and its late response cannot poison a later activation', async () => {
  const { feed, requests } = runtime();
  feed.appear(); policy(feed, false);
  assert.equal(requests[0].token.cancelled, true); assert.equal(feed.busy, false);
  policy(feed, true); assert.equal(requests.length, 2);
  await finish(requests[0], [item(99)]);
  assert.deepEqual(ids(feed), []); assert.equal(feed.busy, true);
  await finish(requests[1], [item(2)]);
  assert.deepEqual(ids(feed), [2]);
});

test('late errors from a cancelled request do not overwrite the newer page', async () => {
  const { feed, requests, ForumApiError } = runtime();
  feed.appear(); policy(feed, false); policy(feed, true);
  await finish(requests[1], [item(2)]);
  requests[0].reject(new ForumApiError('Old failure')); await flush();
  assert.deepEqual(ids(feed), [2]); assert.equal(feed.error, ''); assert.equal(feed.busy, false);
});

test('leaving during pagination cancels only the pending page and preserves existing data for return', async () => {
  const { feed, requests } = runtime();
  feed.appear(); await finish(requests[0], [item(1)]);
  feed.loadNextPage(); policy(feed, false, true);
  assert.equal(requests[1].token.cancelled, true);
  await finish(requests[1], [item(99)]);
  assert.deepEqual(ids(feed), [1]); assert.equal(feed.page, 0);
  policy(feed, true); feed.loadNextPage();
  assert.equal(requests.length, 3); assert.equal(requests[2].page, 1);
  await finish(requests[2], [item(2)], false);
  assert.deepEqual(ids(feed), [1, 2]);
});

test('swiper disappearance preserves loaded pages and their scrollers without re-fetching', async () => {
  const { feed, requests } = runtime();
  feed.appear(); await finish(requests[0], [item(1)]);
  feed.listScroller.position = 560;
  feed.disappear(); feed.appear();
  assert.equal(requests.length, 1); assert.deepEqual(ids(feed), [1]); assert.equal(feed.listScroller.position, 560);
  assert.deepEqual(feed.listScroller.edges, []);
});

test('an unfinished page detached by swiper ignores its old response and resumes on return', async () => {
  const { feed, requests } = runtime();
  feed.filterIndex = 2; feed.appear(); feed.disappear();
  assert.equal(requests[0].token.cancelled, true);
  await finish(requests[0], [item(99)]);
  assert.deepEqual(ids(feed), []); assert.equal(feed.loaded, false);
  feed.appear(); assert.equal(requests[1].kind, 'unread');
  await finish(requests[1], [item(2)]);
  assert.deepEqual(ids(feed), [2]);
});

test('a fresh selected-page signal returns to the native List edge and refreshes page zero once', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(9)]; feed.page = 4; feed.appear();
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop();
  assert.deepEqual(feed.listScroller.edges, ['top']); assert.equal(feed.refreshing, true);
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 0);
  assert.deepEqual(ids(feed), [9], 'Refreshing must retain the current content until replacement arrives.');
  feed.refreshLatestFromTop(); feed.refreshFromPull();
  assert.equal(requests.length, 1); assert.equal(requests[0].token.cancelled, false);
  await finish(requests[0], [item(2)]);
  assert.deepEqual(ids(feed), [2]); assert.equal(feed.page, 0);
  assert.equal(feed.refreshing, false); assert.equal(feed.busy, false);
});

test('selected-page signals during pagination coalesce into one following refresh', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(1)]; feed.page = 2; feed.appear();
  feed.loadNextPage();
  for (let signal = 1; signal <= 3; signal++) { feed.refreshTopSignal = signal; feed.refreshLatestFromTop(); }
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 3);
  assert.equal(requests[0].token.cancelled, false); assert.equal(feed.listScroller.edges.length, 3);
  await finish(requests[0], [item(3)]);
  assert.equal(requests.length, 2); assert.equal(requests[1].page, 0);
  feed.refreshFromPull(); assert.equal(requests.length, 2);
  await finish(requests[1], [item(4)]);
  assert.equal(requests.length, 2); assert.deepEqual(ids(feed), [4]);
});

test('queued refresh is discarded when its page loses selection, and neighboring content stays intact', async () => {
  const { feed, createFeed, requests } = runtime();
  const next = createFeed(1, false, true);
  feed.loaded = true; feed.items = [item(1)]; next.loaded = true; next.items = [item(2)];
  feed.appear(); next.appear(); feed.loadNextPage();
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop(); policy(feed, false, true); policy(next, true);
  await finish(requests[0], [item(99)]);
  assert.equal(requests.length, 1); assert.equal(feed.pendingTopRefresh, false);
  assert.deepEqual(ids(feed), [1]); assert.deepEqual(ids(next), [2]);
  policy(next, false, true); policy(feed, true);
  assert.equal(requests.length, 1);
});

test('ordinary pagination appends, de-duplicates, and stops concurrent or exhausted page requests', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(1), item(2)]; feed.appear();
  feed.loadNextPage(); feed.loadNextPage();
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 1);
  await finish(requests[0], [item(2), item(3)], false);
  assert.deepEqual(ids(feed), [1, 2, 3]); assert.equal(feed.hasMore, false); assert.equal(feed.page, 1);
  feed.loadNextPage(); assert.equal(requests.length, 1);
});

test('session reload invalidates every cache and late old-account data; current and adjacent first pages restart', async () => {
  const { feed, createFeed, requests } = runtime();
  const next = createFeed(1, false, true); const distant = createFeed(4, false, false);
  for (const page of [feed, next, distant]) { page.loaded = true; page.items = [item(8)]; page.page = 5; page.appear(); }
  feed.loadNextPage();
  for (const page of [feed, next, distant]) { page.error = 'old error'; page.needsVerification = true; page.onReload(); }
  assert.equal(requests[0].token.cancelled, true);
  assert.deepEqual(requests.slice(1).map(request => [request.kind, request.page]), [['latest', 0], ['new', 0]]);
  for (const page of [feed, next, distant]) {
    assert.deepEqual(ids(page), []); assert.equal(page.page, 0); assert.equal(page.error, '');
    assert.equal(page.loaded, false); assert.equal(page.needsVerification, false);
  }
  await finish(requests[0], [item(99)]); assert.deepEqual(ids(feed), []); assert.equal(feed.busy, true);
  await finish(requests[1], [item(1)]); await finish(requests[2], [item(2)]);
  policy(distant, true); assert.equal(requests[3].kind, 'top'); assert.equal(requests[3].page, 0);
  await finish(requests[3], [item(4)]);
  assert.deepEqual([feed, next, distant].map(ids), [[1], [2], [4]]);
});

test('reload while detached clears cached data but waits for its next appearance', async () => {
  const { feed, requests } = runtime();
  feed.appear(); await finish(requests[0], [item(1)]); feed.disappear(); feed.onReload();
  assert.deepEqual(ids(feed), []); assert.equal(requests.length, 1);
  feed.appear(); assert.equal(requests.length, 2); await finish(requests[1], [item(2)]);
  assert.deepEqual(ids(feed), [2]);
});

test('refresh, pagination, error and retry state remain isolated between cached pages', async () => {
  const { feed, createFeed, requests, ForumApiError } = runtime();
  const next = createFeed(3, false, true);
  feed.appear(); next.appear(); await finish(requests[0], [item(1)]); await finish(requests[1], [item(2)]);
  feed.refreshFromPull(); requests[2].reject(new ForumApiError('Network unavailable')); await flush();
  assert.equal(feed.error, 'Network unavailable'); assert.equal(feed.refreshing, false); assert.deepEqual(ids(feed), [1]);
  assert.equal(next.error, ''); assert.equal(next.page, 0); assert.deepEqual(ids(next), [2]);
  policy(feed, false, true); policy(next, true); next.loadNextPage();
  assert.equal(requests[3].kind, 'hot'); assert.equal(requests[3].page, 1);
  await finish(requests[3], [item(3)]);
  policy(next, false, true); policy(feed, true); feed.refreshFromPull();
  await finish(requests[4], [item(4)]);
  assert.equal(feed.error, ''); assert.deepEqual(ids(feed), [4]); assert.deepEqual(ids(next), [2, 3]);
});

test('auto refresh runs only on a visible selected page and clears on inactivity or detachment', async () => {
  const { feed, requests, timers } = runtime();
  feed.appearance.autoRefresh = true; feed.appear();
  assert.equal(timers.size, 1); await finish(requests[0], [item(1)]);
  const currentTimer = [...timers.values()][0]; currentTimer();
  assert.equal(requests.length, 2); await finish(requests[1], [item(2)]);
  policy(feed, false, true); assert.equal(timers.size, 0);
  currentTimer(); assert.equal(requests.length, 2, 'An already queued timer must also re-check selection.');
  policy(feed, true); assert.equal(timers.size, 1);
  feed.disappear(); assert.equal(timers.size, 0);
});

test('category feeds preserve their independent endpoint and ignore home refresh signals', async () => {
  const { feed, requests } = runtime();
  feed.categoryId = 6; feed.categorySlug = 'tools'; feed.appear();
  assert.equal(requests[0].kind, 'category'); await finish(requests[0], [item(1)]);
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop();
  assert.equal(requests.length, 1); assert.deepEqual(feed.listScroller.edges, []);
  feed.loadNextPage(); assert.equal(requests[1].kind, 'category'); assert.equal(requests[1].page, 1);
  await finish(requests[1], [item(2)]); assert.deepEqual(ids(feed), [1, 2]);
});

test('empty and verification-required first pages keep distinct recoverable states', async () => {
  const { feed, createFeed, requests, ForumApiError } = runtime();
  const next = createFeed(2, false, true);
  feed.appear(); next.appear(); await finish(requests[0], [], false);
  const error = new ForumApiError('请先登录'); error.kind = 'authentication'; requests[1].reject(error); await flush();
  assert.equal(feed.loaded, true); assert.equal(feed.hasMore, false); assert.equal(feed.error, '');
  assert.equal(next.loaded, false); assert.equal(next.needsVerification, true); assert.equal(next.error, '请先登录');
  policy(next, true); assert.equal(requests.length, 2, 'A failed page remains actionable without looping background retries.');
  next.refreshFromPull(); await finish(requests[2], [item(2)]);
  assert.equal(next.needsVerification, false); assert.equal(next.error, ''); assert.deepEqual(ids(next), [2]);
});

test('pinned grouping keeps server order, never duplicates cards, and never changes pin/read state', () => {
  const values = [item(8, true), item(2), item(5, true), item(3), item(8, true)];
  const before = JSON.stringify(values);
  const sections = presentation.splitTopicFeed(values);
  assert.deepEqual(sections.pinned.map(value => value.topic.id), [8, 5]);
  assert.deepEqual(sections.topics.map(value => value.topic.id), [2, 3]);
  assert.equal(JSON.stringify(values), before); assert.equal(sections.pinned[0], values[0]);
});

test('compact pinned preview exposes the first three titles and expansion exposes every remaining topic', () => {
  const values = [1, 2, 3, 4, 5].map(id => item(id, true));
  assert.deepEqual(presentation.visiblePinnedTopics(values, false).map(value => value.topic.id), [1, 2, 3]);
  assert.deepEqual(presentation.visiblePinnedTopics(values, true).map(value => value.topic.id), [1, 2, 3, 4, 5]);
  assert.equal(values.length, 5); assert.deepEqual(presentation.visiblePinnedTopics([], false), []);
});

test('category metadata arrives after first paint and old-account metadata cannot mutate new-session rows', async () => {
  const { feed, requests, categoryRequests } = runtime();
  const categorized = { ...item(1), topic: { ...item(1).topic, categoryId: 8 } };
  feed.appear(); await finish(requests[0], [categorized]);
  assert.equal(feed.loaded, true); assert.equal(feed.busy, false); assert.equal(categoryRequests.length, 1);
  categoryRequests[0].resolve([{ id: 8, name: '开发调优', subcategoryList: [] }]); await flush();
  assert.equal(feed.items[0].category.name, '开发调优');
  feed.refreshFromPull(); await finish(requests[1], [categorized]);
  feed.onReload(); await finish(requests[2], [item(2)]);
  categoryRequests[1].resolve([{ id: 8, name: 'old', subcategoryList: [] }]); await flush();
  assert.deepEqual(ids(feed), [2]);
  feed.refreshFromPull(); await finish(requests[3], [categorized]);
  categoryRequests[2].reject(new Error('Categories unavailable')); await flush();
  assert.equal(feed.error, ''); assert.deepEqual(ids(feed), [1]);
});

test('dense metadata keeps category and the first two real tags, falling back only to the author', () => {
  const value = { ...item(1), topic: { ...item(1).topic, tags: ['开源', '工具', '其他'] }, category: { name: '资源荟萃' } };
  assert.equal(presentation.topicMetadata(value), '资源荟萃 · 开源 · 工具');
  assert.equal(presentation.topicMetadata({ ...value, category: undefined }), '开源 · 工具');
  assert.equal(presentation.topicMetadata({ ...value, category: undefined, topic: { ...value.topic, tags: [] } }), 'u1');
});

test('returning from a detached page hydrates retained rows without re-fetching topics', async () => {
  const { feed, requests, categoryRequests } = runtime();
  feed.appear(); await finish(requests[0], [{ ...item(1), topic: { ...item(1).topic, categoryId: 8 } }]);
  feed.disappear(); categoryRequests[0].resolve([{ id: 8, name: '开发调优', subcategoryList: [] }]); await flush();
  assert.equal(feed.items[0].category, undefined);
  feed.appear(); assert.equal(requests.length, 1); assert.equal(categoryRequests.length, 2);
  categoryRequests[1].resolve([{ id: 8, name: '开发调优', subcategoryList: [] }]); await flush();
  assert.equal(feed.items[0].category.name, '开发调优');
});
