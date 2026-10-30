import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required.');
const ts = require(compiler);
function load(path, bindings = {}) {
  const source = readFileSync(new URL(`../app/entry/src/main/ets/${path}`, import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source.replace(/^import [\s\S]*?;\r?\n/gm, ''), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled)(module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const models = load('models/ForumModels.ets');
const wire = load('services/ForumWire.ets', models);
const policy = load('services/SearchPolicy.ets');
const { ForumSearchHistoryStore } = load('services/SearchHistoryStore.ets', policy);
const { ForumApi, ForumErrorKind } = load('services/ForumApi.ets', { ...models, ...wire });
const entry = (query, changes = {}) => ({ query, titleOnly: false, categoryId: 0, categoryName: '', tags: '', author: '', orderIndex: 0, ...changes });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
};

test('advanced controls generate the documented Discourse title/category/tag/author query', () => {
  const result = policy.buildForumSearchQuery(entry('鸿蒙 客户端', {
    titleOnly: true, categoryId: 42, categoryName: '开发调优, Lv1', tags: '#鸿蒙,人工智能，鸿蒙', author: '@Neo'
  }));
  assert.deepEqual(result, { query: '鸿蒙 客户端 in:title category:42 tags:鸿蒙,人工智能 @Neo', error: '' });
  assert.equal(policy.buildForumSearchQuery(entry('', { categoryId: 42 })).query, 'category:42');
  assert.equal(policy.buildForumSearchQuery(entry('"exact phrase" after:2026-01-01')).query, '"exact phrase" after:2026-01-01');
  assert.equal(policy.forumSearchCriteriaSummary(entry('x', { titleOnly: true, categoryId: 42,
    categoryName: '开发调优', tags: '鸿蒙', author: '@Neo' })), '仅标题 · 开发调优 · #鸿蒙 · @Neo');
});

test('dedicated fields cannot inject extra filters and title-only still needs content or another scope', () => {
  assert.ok(policy.buildForumSearchQuery(entry('', { titleOnly: true })).error);
  assert.ok(policy.buildForumSearchQuery(entry('x', { author: 'Neo order:likes' })).error);
  assert.ok(policy.buildForumSearchQuery(entry('x', { tags: '鸿蒙,order:latest' })).error);
  assert.ok(policy.buildForumSearchQuery(entry('x', { categoryId: NaN })).error);
  assert.ok(policy.buildForumSearchQuery(entry('x', { tags: Array.from({ length: 11 }, (_, index) => `t${index}`).join(',') })).error);
  assert.ok(policy.buildForumSearchQuery(entry('x'.repeat(1001))).error);
});

test('topic search keeps the visible scope last and leaves ordinary search unchanged', () => {
  assert.equal(policy.buildForumSearchQuery(entry('关键词 topic:999'), 42).query, '关键词 topic:999 topic:42');
  assert.equal(policy.buildForumSearchQuery(entry('关键词'), 0).query, '关键词');
  assert.ok(policy.buildForumSearchQuery(entry('关键词'), -42).error);
});

test('main and topic recent searches persist to different account-scoped keys', async () => {
  const data = new Map();
  const preferences = { getPreferences: async () => ({
    get: async (key, fallback) => data.get(key) ?? fallback,
    put: async (key, value) => { data.set(key, value); }, flush: async () => {}
  }) };
  const { ForumSearchHistoryPreferences } = load('services/SearchHistoryPreferences.ets', { preferences });
  const main = new ForumSearchHistoryPreferences({}, 0);
  const topic = new ForumSearchHistoryPreferences({}, 42);
  await main.write('search_history_7', '["main"]');
  await topic.write('search_history_7', '["topic"]');
  assert.equal(await main.read('search_history_7'), '["main"]');
  assert.equal(await topic.read('search_history_7'), '["topic"]');
  assert.equal(await topic.read('search_history_8'), '[]');
  assert.deepEqual([...data.keys()], ['search_history_7', 'search_history_7_topic_42']);
});

test('recent searches preserve structured filters and sort, bound history, and discard malformed records', () => {
  const first = entry('Harmony', { titleOnly: true, categoryId: 42, categoryName: '开发调优', author: '@Neo', orderIndex: 4 });
  const result = policy.normalizeForumSearchHistory([first, entry('harmony', { ...first, query: 'harmony' }), null,
    entry('bad', { author: 'in:all-pms' }), ...Array.from({ length: 20 }, (_, index) => entry(`q${index}`))]);
  assert.equal(result.length, 12);
  assert.equal(result[0].query, 'Harmony');
  assert.equal(result[0].author, 'Neo');
  assert.equal(result[0].orderIndex, 4);
  assert.equal(result[1].query, 'q0');
});

test('late storage reads remain scoped to their explicit account and the guest has a separate key', async () => {
  const old = deferred();
  const seen = [];
  const storage = {
    read: async key => { seen.push(key); return key === 'search_history_7' ? old.promise : JSON.stringify([entry(key)]); },
    write: async () => {}
  };
  const store = new ForumSearchHistoryStore(storage);
  const pending = store.read(7);
  assert.equal((await store.read(8))[0].query, 'search_history_8');
  assert.equal((await store.read(0))[0].query, 'search_history_0');
  old.resolve(JSON.stringify([entry('old account')]));
  assert.equal((await pending)[0].query, 'old account');
  assert.equal((await store.read(8))[0].query, 'search_history_8');
  assert.deepEqual(seen, ['search_history_7', 'search_history_8', 'search_history_0']);
});

test('clearing while an earlier search awaits history prevents that record from being resurrected', async () => {
  const read = deferred();
  const saved = [];
  const store = new ForumSearchHistoryStore({ read: async () => read.promise, write: async (_key, value) => { saved.push(value); } });
  const earlier = store.remember(7, entry('earlier search'));
  await store.clear(7);
  read.resolve(JSON.stringify([entry('old disk record')]));
  assert.deepEqual(await earlier, []);
  assert.deepEqual(await store.read(7), []);
  assert.deepEqual(saved, ['[]']);
});

test('history writes serialize remember/delete/clear so a slow save cannot overwrite a later clear', async () => {
  const firstWrite = deferred();
  const started = deferred();
  const saved = [];
  const store = new ForumSearchHistoryStore({ read: async () => '[]', write: async (_key, value) => {
    saved.push(value); if (saved.length === 1) { started.resolve(); await firstWrite.promise; }
  } });
  const remember = store.remember(7, entry('remember me'));
  await started.promise;
  const clear = store.clear(7);
  assert.equal(saved.length, 1);
  firstWrite.resolve();
  await Promise.all([remember, clear]);
  assert.equal(saved[1], '[]');
  assert.deepEqual(await store.read(7), []);
  await store.remember(8, entry('other account'));
  await store.remove(8, entry('other account'));
  assert.deepEqual(await store.read(8), []);
});

test('six search sorts keep scope and server hit floor reaches the result instead of always first post', async () => {
  const api = new ForumApi();
  api.get = async path => {
    const parsed = new URL(path, 'https://linux.do');
    const query = parsed.searchParams.get('q');
    assert.match(query, /category:42/);
    assert.equal(parsed.searchParams.get('page'), '2');
    return JSON.stringify({ topics: [{ id: 10, title: '命中回复' }, { id: 11, title: '兼容无楼层' }],
      posts: [{ id: 100, topic_id: 10, post_number: 17, username: 'Neo', blurb: '命中内容' },
        { id: 101, topic_id: 11, post_number: 0, username: 'other' }],
      grouped_search_result: { more_full_page_results: true } });
  };
  for (const option of models.searchOrders) {
    const result = await api.search('鸿蒙 category:42', 2, option.value);
    assert.equal(result.postNumbers.get(10), 17);
    assert.equal(result.postNumbers.get(11), 1);
    assert.equal(result.excerpts.get(10), '命中内容');
    assert.equal(result.hasMore, true);
  }
});

test('a search response from a previous account is cancelled before mapping private hits', async () => {
  const api = new ForumApi();
  const response = deferred();
  api.get = async () => response.promise;
  const search = api.search('private');
  api.resetSessionContext();
  const rejected = assert.rejects(search, error => error.kind === ForumErrorKind.Cancelled);
  response.resolve(JSON.stringify({ topics: [{ id: 99, title: 'private' }], posts: [] }));
  await rejected;
});

test('the production topic-search page preserves multiple floor hits and rejects a server fallback to global scope', async () => {
  const source = readFileSync(new URL('../app/entry/src/main/ets/pages/SearchPage.ets', import.meta.url), 'utf8');
  const body = source.match(/  private async search\(reset: boolean\): Promise<void> \{([\s\S]+?)\n  \}\n\n  @Builder\n  filtersSheet/);
  assert.ok(body, 'production search method remains available');
  const compiled = ts.transpileModule(`async function search(reset: boolean): Promise<void> {${body[1]}\n}\nmodule.exports = search;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const session = { user: { id: 7 } };
  let response = { items: [{ topic: { id: 42 } }], excerpts: new Map(), postNumbers: new Map([[42, 17]]),
    postMatches: [{ id: 'p17', topicId: 42, postNumber: 17 }, { id: 'p22', topicId: 42, postNumber: 22 }], hasMore: false };
  const api = { search: async () => response };
  const module = { exports: {} };
  new Function('module', 'buildForumSearchQuery', 'searchOrders', 'RequestCancellation', 'ForumApiError', 'ForumErrorKind',
    'forumApi', 'forumSession', 'plainText', 'Edge', compiled)(module, policy.buildForumSearchQuery, models.searchOrders,
    load('services/ForumApi.ets', { ...models, ...wire }).RequestCancellation,
    load('services/ForumApi.ets', { ...models, ...wire }).ForumApiError, ForumErrorKind, api, session, value => value, { Top: 0 });
  const page = { active: true, visible: true, topicScopeId: 42, busy: false, orderIndex: 0, items: [], postMatches: [],
    criteria: () => entry('关键词'), historyEntry: () => entry('关键词'), listScroller: { scrollEdge: () => {} },
    remember: async () => {}, excerpts: new Map(), postNumbers: new Map() };
  await module.exports.call(page, true);
  assert.deepEqual(page.postMatches.map(match => match.postNumber), [17, 22]);
  assert.equal(page.error, '');
  response = { ...response, items: [{ topic: { id: 999 } }] };
  await module.exports.call(page, true);
  assert.equal(page.items.length, 0);
  assert.equal(page.postMatches.length, 0);
  assert.match(page.error, /未保持指定范围/);
});
