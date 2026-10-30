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
const userModels = load('models/UserProfileModels.ets', models);
const userWire = load('services/UserProfileWire.ets', { ...models, ...wire, ...userModels });
const { ForumApi, ForumErrorKind, RequestCancellation } = load('services/ForumApi.ets', { ...models, ...wire, ...userModels, ...userWire });
const { ForumUserActivityFilter } = userModels;
const pending = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { resolve, promise }; };

test('public profile reads use the server identity and never request emails or register another member visit', async () => {
  const api = new ForumApi();
  const paths = [];
  api.get = async path => {
    paths.push(path);
    return JSON.stringify({ user: { id: 7, username: 'Neo', name: '<b>社区成员</b>', trust_level: 4,
      avatar_template: '/user_avatar/linux.do/neo/{size}/1.png', bio_cooked: '<p>真实简介</p>', created_at: '2020-01-02T00:00:00Z' } });
  };
  const result = await api.fetchUserProfile('@Neo');
  assert.deepEqual(paths, ['/u/Neo.json?skip_track_visit=true']);
  assert.equal(result.id, 7);
  assert.equal(result.username, 'Neo');
  assert.equal(result.name, '社区成员');
  assert.equal(result.bio, '真实简介');
  assert.equal(result.trustLevel, 4);
  assert.equal(result.lastSeenAt, '');
});

test('hidden profiles suppress private fields and missing trust/stat values remain unknown', () => {
  const hidden = userWire.forumUserProfileFromWire({ id: 7, username: 'hidden', profile_hidden: true,
    bio_cooked: 'must not display', location: 'hidden place', trust_level: 4, created_at: '2020-01-01' });
  assert.equal(hidden.hidden, true);
  assert.equal(hidden.bio, '');
  assert.equal(hidden.location, '');
  assert.equal(hidden.trustLevel, -1);
  assert.equal(userWire.forumUserProfileFromWire({ id: 1, username: 'partial' }).trustLevel, -1);
  const summary = userWire.forumUserSummaryFromWire({ topic_count: 0, likes_received: 25 });
  assert.equal(summary.fields.find(field => field.label === '发表话题').value, '0');
  assert.equal(summary.fields.find(field => field.label === '收到的赞').value, '25');
  assert.equal(summary.fields.find(field => field.label === '回复数量').value, '—');
  const privateSummary = userWire.forumUserSummaryFromWire({ can_see_summary_stats: false, topic_count: 999, time_read: 999 });
  assert.ok(privateSummary.fields.every(field => field.value === '—'));
});

test('activity filtering preserves real floor and advances the server cursor over every row', async () => {
  const api = new ForumApi();
  api.get = async path => {
    assert.equal(path, '/user_actions.json?username=Neo&offset=30&limit=30&filter=5');
    return JSON.stringify({ user_actions: [
      { action_type: 5, post_id: 10, topic_id: 100, post_number: 17, title: '<b>真实话题</b>', excerpt: '<p>真实回复</p>', created_at: '2026-01-01' },
      { action_type: 12, post_id: 11, topic_id: 200, post_number: 1, title: 'unexpected private action' },
      { action_type: 5, post_id: 10, topic_id: 100, post_number: 17, title: 'duplicate', created_at: '2026-01-01' }
    ] });
  };
  const result = await api.fetchUserProfileActivity('Neo', ForumUserActivityFilter.Replies, 30);
  assert.equal(result.entries.length, 1);
  assert.equal(result.entries[0].postNumber, 17);
  assert.equal(result.entries[0].title, '真实话题');
  assert.equal(result.entries[0].excerpt, '真实回复');
  assert.equal(result.nextOffset, 33);
  assert.equal(result.hasMore, false);
});

test('malformed profile identity and invalid filters are rejected before an unrelated profile can display', async () => {
  const api = new ForumApi();
  api.get = async () => JSON.stringify({ user: { id: 9, username: 'other' } });
  await assert.rejects(api.fetchUserProfile('Neo'), error => error.kind === ForumErrorKind.InvalidResponse);
  await assert.rejects(api.fetchUserProfile('../admin'), error => error.kind === ForumErrorKind.Rejected);
  await assert.rejects(api.fetchUserProfileActivity('Neo', '12'), error => error.kind === ForumErrorKind.Rejected);
  api.get = async () => JSON.stringify({});
  await assert.rejects(api.fetchUserProfileSummary('Neo'), error => error.kind === ForumErrorKind.InvalidResponse);
});

test('changing accounts or cancelling a hidden page rejects late profile, summary and activity responses', async () => {
  for (const read of [api => api.fetchUserProfile('Neo'), api => api.fetchUserProfileSummary('Neo'),
    api => api.fetchUserProfileActivity('Neo')]) {
    const api = new ForumApi();
    const deferred = pending();
    api.get = async () => deferred.promise;
    const operation = read(api);
    api.resetSessionContext();
    const rejection = assert.rejects(operation, error => error.kind === ForumErrorKind.Cancelled);
    deferred.resolve(JSON.stringify({ user: { id: 7, username: 'Neo' }, user_summary: {}, user_actions: [] }));
    await rejection;
  }
  const api = new ForumApi();
  const request = new RequestCancellation();
  const deferred = pending();
  api.get = async () => deferred.promise;
  const operation = api.fetchUserProfile('Neo', request);
  request.cancel();
  const rejection = assert.rejects(operation, error => error.kind === ForumErrorKind.Cancelled);
  deferred.resolve(JSON.stringify({ user: { id: 7, username: 'Neo' } }));
  await rejection;
});
