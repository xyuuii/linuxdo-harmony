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
const feedSource = source('components/TopicFeed');
const start = feedSource.indexOf('export struct TopicFeed');
const end = feedSource.indexOf('  build() {', start);
assert.ok(start >= 0 && end > start, 'Execute actual production feed methods, not an alternate implementation.');
const feedClass = (feedSource.slice(start, end) + '\n}\n')
  .replace('export struct TopicFeed', 'export class TopicFeed')
  .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');

function runtime() {
  const requests = [];
  const fetch = (kind, page, token) => new Promise((resolve, reject) => { requests.push({ kind, page, token, resolve, reject }); });
  class RequestCancellation { cancelled = false; cancel() { this.cancelled = true; } }
  class ForumApiError extends Error { kind = 'network'; }
  const exported = load(feedClass, {
    ...presentation,
    AppearanceSettings: class { autoRefresh = false; },
    Scroller: class { edges = []; scrollEdge(edge) { this.edges.push(edge); } },
    Edge: { Top: 'top' }, RequestCancellation, ForumApiError,
    ForumErrorKind: { VerificationRequired: 'verification', AuthenticationRequired: 'authentication' },
    forumApi: { fetchLatest: (page, token) => fetch('latest', page, token),
      fetchCategoryTopics: (_, __, page, token) => fetch('category', page, token) }
  });
  return { feed: new exported.TopicFeed(), requests, ForumApiError };
}

const item = (id, pinned = false) => ({ topic: { id, title: `Topic ${id}`, pinned, unseen: true }, authorUsername: `u${id}` });
async function finish(request, items, hasMore = true) {
  request.resolve({ items, hasMore });
  await new Promise(resolve => setImmediate(resolve));
}

test('a fresh latest-tab signal returns to the native List edge and refreshes page zero once', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(9)]; feed.page = 4; feed.appear();
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop();
  assert.deepEqual(feed.listScroller.edges, ['top']);
  assert.equal(feed.refreshing, true);
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 0);
  feed.refreshLatestFromTop(); feed.refreshFromPull();
  assert.equal(requests.length, 1, 'Native Refresh callback must not duplicate a programmatic refresh.');
  assert.equal(requests[0].token.cancelled, false);
  await finish(requests[0], [item(2)]);
  assert.deepEqual(feed.items.map(value => value.topic.id), [2]);
  assert.equal(feed.page, 0); assert.equal(feed.refreshing, false); assert.equal(feed.busy, false);
});

test('latest-tab signals during a page request return immediately and coalesce into one following refresh', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(1)]; feed.page = 2; feed.appear();
  void feed.load(false);
  for (let signal = 1; signal <= 3; signal++) { feed.refreshTopSignal = signal; feed.refreshLatestFromTop(); }
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 3);
  assert.equal(requests[0].token.cancelled, false);
  assert.equal(feed.listScroller.edges.length, 3, 'The user sees the return immediately even while a request is busy.');
  await finish(requests[0], [item(3)]);
  assert.equal(requests.length, 2); assert.equal(requests[1].page, 0);
  feed.refreshFromPull(); assert.equal(requests.length, 2);
  await finish(requests[1], [item(4)]);
  assert.equal(requests.length, 2); assert.deepEqual(feed.items.map(value => value.topic.id), [4]);
});

test('a hidden latest feed retains the signal until active and category feeds ignore it', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.active = false; feed.refreshTopSignal = 5; feed.appear();
  assert.equal(requests.length, 0); assert.deepEqual(feed.listScroller.edges, []);
  feed.active = true; feed.refreshLatestFromTop();
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 0);
  await finish(requests[0], [item(1)]);
  const category = runtime();
  category.feed.loaded = true; category.feed.categoryId = 6; category.feed.appear();
  category.feed.refreshTopSignal = 1; category.feed.refreshLatestFromTop();
  assert.equal(category.requests.length, 0); assert.deepEqual(category.feed.listScroller.edges, []);
});

test('a queued latest refresh waits if its page becomes hidden before a request finishes', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.appear(); void feed.load(false);
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop(); feed.active = false;
  await finish(requests[0], [item(1)]);
  assert.equal(requests.length, 1); assert.equal(feed.pendingTopRefresh, true);
  feed.active = true; feed.refreshLatestFromTop();
  assert.equal(requests.length, 2); assert.equal(requests[1].page, 0);
  await finish(requests[1], [item(2)]);
});

test('ordinary pagination still appends, de-duplicates and does not open concurrent page requests', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.items = [item(1), item(2)]; feed.appear();
  void feed.load(false); void feed.load(false);
  assert.equal(requests.length, 1); assert.equal(requests[0].page, 1);
  await finish(requests[0], [item(2), item(3)], false);
  assert.deepEqual(feed.items.map(value => value.topic.id), [1, 2, 3]);
  assert.equal(feed.hasMore, false); assert.equal(feed.page, 1);
});

test('a session reload invalidates the old page response and clears an already fulfilled pending refresh', async () => {
  const { feed, requests } = runtime();
  feed.loaded = true; feed.appear(); void feed.load(false);
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop(); feed.onReload();
  assert.equal(requests[0].token.cancelled, true); assert.equal(requests.length, 2);
  await finish(requests[0], [item(9)]);
  assert.deepEqual(feed.items, []); assert.equal(feed.busy, true);
  await finish(requests[1], [item(2)]);
  assert.deepEqual(feed.items.map(value => value.topic.id), [2]);
  assert.equal(requests.length, 2); assert.equal(feed.busy, false);
});

test('failed latest refresh stops the indicator and can retry through ordinary pull refresh', async () => {
  const { feed, requests, ForumApiError } = runtime();
  feed.loaded = true; feed.items = [item(1)]; feed.appear();
  feed.refreshTopSignal = 1; feed.refreshLatestFromTop();
  requests[0].reject(new ForumApiError('Network unavailable'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(feed.busy, false); assert.equal(feed.refreshing, false);
  assert.equal(feed.error, 'Network unavailable'); assert.equal(feed.items.length, 1);
  feed.refreshFromPull(); assert.equal(requests.length, 2);
  await finish(requests[1], [item(2)]);
  assert.equal(feed.error, '');
});

test('pinned grouping keeps server order, never duplicates cards, and never changes pin/read state', () => {
  const values = [item(8, true), item(2), item(5, true), item(3), item(8, true)];
  const before = JSON.stringify(values);
  const sections = presentation.splitTopicFeed(values);
  assert.deepEqual(sections.pinned.map(value => value.topic.id), [8, 5]);
  assert.deepEqual(sections.topics.map(value => value.topic.id), [2, 3]);
  assert.equal(JSON.stringify(values), before);
  assert.equal(sections.pinned[0], values[0]);
});

test('compact pinned preview exposes the first three titles and expansion exposes every remaining topic', () => {
  const values = [1, 2, 3, 4, 5].map(id => item(id, true));
  assert.deepEqual(presentation.visiblePinnedTopics(values, false).map(value => value.topic.id), [1, 2, 3]);
  assert.deepEqual(presentation.visiblePinnedTopics(values, true).map(value => value.topic.id), [1, 2, 3, 4, 5]);
  assert.equal(values.length, 5);
  assert.deepEqual(presentation.visiblePinnedTopics([], false), []);
});
