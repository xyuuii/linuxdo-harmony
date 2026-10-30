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
const directory = load('models/DirectoryModels.ets', models);
const directoryWire = load('services/DirectoryWire.ets', { ...models, ...wire, ...directory });
const apiModule = load('services/ForumApi.ets', { ...models, ...wire, ...directory, ...directoryWire });
const { ForumApi, ForumErrorKind, RequestCancellation } = apiModule;
const category = (id, name, parent = 0, count = 1) => ({ id, name, parentCategoryId: parent, topicCount: count,
  slug: String(id), color: 'FFFFFF', textColor: '000000', description: '', subcategoryList: [] });

test('category disclosure keeps children independent and search retains ancestor context', () => {
  const categories = [category(1, '开发调优', 0, 10), category(2, '开发调优, Lv1', 1, 4),
    category(3, '工具', 2, 3), category(4, '日常', 0, 7)];
  assert.deepEqual(directory.directoryCategoryRows(categories, '', []).map(row => [row.category.id, row.totalTopicCount]), [[1, 17], [4, 7]]);
  assert.deepEqual(directory.directoryCategoryRows(categories, '', [1]).map(row => row.category.id), [1, 2, 4]);
  assert.deepEqual(directory.directoryCategoryRows(categories, '', [1, 2]).map(row => row.category.id), [1, 2, 3, 4]);
  assert.deepEqual(directory.directoryCategoryRows(categories, '工具', []).map(row => [row.category.id, row.depth]), [[1, 0], [2, 1], [3, 2]]);
  assert.deepEqual(directory.directoryCategoryRows(categories, '不存在', []), []);
});

test('tag catalogs include grouped and category-constrained tags, deduplicate and paginate the complete match set', () => {
  const response = { tags: [{ id: 1, name: 'AI', count: 10 }], extras: {
    tag_groups: [{ tags: [{ id: 2, name: '模型', count: 20 }] }],
    categories: [{ tags: [{ id: 1, name: 'AI', count: 10 }, { id: 3, text: '鸿蒙', count: 3 }] }]
  } };
  const tags = directoryWire.directoryTagsFromWire(response);
  assert.equal(tags.length, 3);
  assert.deepEqual(directory.directoryTagPage(tags, '', 0).items.map(tag => tag.name), ['模型', 'AI', '鸿蒙']);
  assert.deepEqual(directory.directoryTagPage(tags, 'ai', 0).items.map(tag => tag.name), ['AI']);
  const large = Array.from({ length: 203 }, (_, id) => ({ id, name: `tag-${id}`, description: '', topicCount: id, slug: '' }));
  assert.equal(directory.directoryTagPage(large, '', 0).items.length, 100);
  assert.equal(directory.directoryTagPage(large, '', 1).hasMore, true);
  assert.equal(directory.directoryTagPage(large, '', 2).items.length, 3);
  assert.equal(directory.directoryTagPage(large, '', 2).hasMore, false);
});

test('badge and group mapping uses server descriptions and keeps private membership counts unknown', () => {
  const badges = directoryWire.directoryBadgesFromWire({ badges: [{ id: 1, name: '<b>初来乍到</b>',
    description: '<p>已参与社区</p>', long_description: '<p>更完整的获得条件</p>', grant_count: 5, badge_type_id: 3,
    badge_grouping_id: 2, has_badge: true }], badge_groupings: [{ id: 2, name: '起步' }] });
  assert.equal(badges[0].name, '初来乍到');
  assert.equal(badges[0].longDescription, '更完整的获得条件');
  assert.equal(badges[0].groupName, '起步');
  assert.equal(badges[0].hasBadge, true);
  const groups = directoryWire.directoryGroupsFromWire({ groups: [{ id: 1, name: 'private', bio_cooked: '<p>说明</p>' }],
    total_rows_groups: 1, load_more_groups: '/groups?page=1' });
  assert.equal(groups.items[0].userCount, -1);
  assert.equal(groups.items[0].description, '说明');
  assert.equal(groups.total, 1);
});

test('tag cache is permission-scoped and an old account response cannot refill it', async () => {
  const api = new ForumApi();
  let calls = 0;
  api.get = async path => { assert.equal(path, '/tags.json'); calls++; return JSON.stringify({ tags: [{ id: 1, name: 'before', count: 1 }] }); };
  assert.equal((await api.fetchDirectoryTags()).items[0].name, 'before');
  await api.fetchDirectoryTags('BEFORE'); assert.equal(calls, 1);
  api.resetSessionContext();
  let finish;
  api.get = async () => new Promise(resolve => { finish = resolve; });
  const stale = api.fetchDirectoryTags();
  api.resetSessionContext();
  const rejected = assert.rejects(stale, error => error.kind === ForumErrorKind.Cancelled);
  finish(JSON.stringify({ tags: [{ id: 1, name: 'stale', count: 1 }] }));
  await rejected;
  api.get = async () => JSON.stringify({ tags: [{ id: 2, name: 'after', count: 1 }] });
  assert.equal((await api.fetchDirectoryTags()).items[0].name, 'after');
});

test('cancelled tag reads reject cached results and group query stays inside the encoded forum path', async () => {
  const api = new ForumApi();
  api.get = async () => JSON.stringify({ tags: [] });
  await api.fetchDirectoryTags();
  const token = new RequestCancellation(); token.cancel();
  await assert.rejects(api.fetchDirectoryTags('', 0, token), error => error.kind === ForumErrorKind.Cancelled);
  await assert.rejects(api.fetchDirectoryTags('', -1), error => error.kind === ForumErrorKind.Rejected);
  api.get = async path => {
    assert.equal(path, '/groups.json?page=2&order=name&asc=true&filter=%26admin%3Dtrue');
    return JSON.stringify({ groups: [], total_rows_groups: 0 });
  };
  assert.equal((await api.fetchDirectoryGroups('&admin=true', 2)).items.length, 0);
  api.get = async () => JSON.stringify({ error: 'not a directory' });
  await assert.rejects(api.fetchDirectoryBadges(), error => error.kind === ForumErrorKind.InvalidResponse);
});
