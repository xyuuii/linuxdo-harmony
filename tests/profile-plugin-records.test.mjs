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
const source = path => readFileSync(new URL(`../app/entry/src/main/ets/${path}.ets`, import.meta.url), 'utf8');
function compile(value, bindings = {}) {
  const compiled = ts.transpileModule(value.replace(/^import [\s\S]*?;\r?\n/gm, ''), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled)(module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const models = compile(source('models/ForumModels'));
const wire = compile(source('services/ForumWire'), models);
const apiModule = compile(source('services/ForumApi'), { ...models, ...wire });
const { ForumApi, ForumApiError, ForumErrorKind, RequestCancellation } = apiModule;
const { ProfileSection, ProfileBoostDirection } = models;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const solved = (index = 1, username = 'owner') => ({ post_id: index, topic_id: 100, post_number: index + 1,
  username, topic_title: '<b>被采纳所在话题</b>', cooked: '<p>该用户的解答</p>', created_at: '2026-01-02T03:04:05Z' });
const boost = (id = 120, direction = 'given', changes = {}) => ({ id, post_id: 101, cooked: '<p>真实 Boost</p>',
  created_at: '2026-01-02', user: { username: direction === 'given' ? 'owner' : 'sender', avatar_template: '' },
  post: { id: 101, topic_id: 100, url: '/t/title/100/17', topic_title: '所在话题',
    username: direction === 'given' ? 'recipient' : 'owner', avatar_template: '' }, ...changes });

test('my votes reads the official active topic-voting list and keeps server topic pagination', async () => {
  const api = new ForumApi();
  api.get = async path => {
    assert.equal(path, '/topics/voted-by/owner.json?page=2');
    return JSON.stringify({ topic_list: { topics: [{ id: 100, title: '投过的话题' }], more_topics_url: '/topics/voted-by/owner?page=3' } });
  };
  const result = await api.fetchProfile('owner', ProfileSection.Votes, 2);
  assert.equal(result.entries[0].topicId, 100);
  assert.equal(result.entries[0].postNumber, 1);
  assert.equal(result.entries[0].subtitle, '有效话题投票');
  assert.equal(result.hasMore, true); assert.equal(result.nextCursor, 3);
});

test('my solutions uses accepted answer records for the answer author, not solved-topic participation', async () => {
  const api = new ForumApi();
  const paths = [];
  api.get = async path => {
    paths.push(path); return JSON.stringify({ user_solved_posts: [solved(16)] });
  };
  const result = await api.fetchProfile('owner', ProfileSection.Solutions, 30);
  assert.deepEqual(paths, ['/solution/by_user.json?username=owner&offset=30&limit=30']);
  assert.equal(result.entries[0].postNumber, 17);
  assert.equal(result.entries[0].title, '被采纳所在话题');
  assert.match(result.entries[0].subtitle, /回复于 2026-01-02/);
  assert.equal(result.nextCursor, 31);
  api.get = async () => JSON.stringify({ user_solved_posts: [solved(16, 'someone_else')] });
  await assert.rejects(api.fetchProfile('owner', ProfileSection.Solutions), error => error.kind === ForumErrorKind.InvalidResponse);
  api.get = async () => JSON.stringify({ user_actions: [{ action_type: 15, topic_id: 100 }] });
  await assert.rejects(api.fetchProfile('owner', ProfileSection.Solutions), error => error.kind === ForumErrorKind.InvalidResponse);
});

test('solution offsets count the original page while the returned floor remains exact', async () => {
  const api = new ForumApi();
  api.get = async () => JSON.stringify({ user_solved_posts: Array.from({ length: 30 }, (_, index) => solved(index + 1)) });
  const result = await api.fetchProfile('owner', ProfileSection.Solutions, 60);
  assert.equal(result.entries.length, 30); assert.equal(result.nextCursor, 90); assert.equal(result.hasMore, true);
});

test('given and received Boosts use separate official endpoints, directions and before-ID cursors', async () => {
  const api = new ForumApi();
  api.mutate = async () => { throw new Error('record lists must never write'); };
  const paths = [];
  api.get = async path => {
    paths.push(path);
    return JSON.stringify({ boosts: Array.from({ length: 20 }, (_, index) => boost(120 - index)) });
  };
  const given = await api.fetchProfile('owner', ProfileSection.Boosts);
  assert.equal(paths[0], '/discourse-boosts/users/owner/boosts-given.json');
  assert.equal(given.entries[0].postNumber, 17); assert.equal(given.entries[0].actor, 'recipient');
  assert.match(given.entries[0].subtitle, /发给 @recipient/);
  assert.equal(given.hasMore, true); assert.equal(given.nextCursor, 101);
  api.get = async path => { paths.push(path); return JSON.stringify({ boosts: [boost(100, 'received')] }); };
  const received = await api.fetchProfile('owner', ProfileSection.Boosts, 101, undefined, undefined, undefined, ProfileBoostDirection.Received);
  assert.equal(paths[1], '/discourse-boosts/users/owner/boosts-received.json?before_boost_id=101');
  assert.equal(received.entries[0].actor, 'sender'); assert.match(received.entries[0].subtitle, /来自 @sender/);
  assert.equal(received.nextCursor, 100); assert.equal(received.hasMore, false);
});

test('Boost floor routing accepts canonical numeric slugs but never guesses missing or foreign floors', async () => {
  const api = new ForumApi();
  const valid = boost(); valid.post.url = '/t/123/100/17';
  api.get = async () => JSON.stringify({ boosts: [valid] });
  assert.equal((await api.fetchProfile('owner', ProfileSection.Boosts)).entries[0].postNumber, 17);
  for (const url of ['/t/title/100', 'https://other.test/t/title/100/17', '/t/title/999/17', '/t/title/100/0']) {
    const invalid = boost(); invalid.post.url = url;
    api.get = async () => JSON.stringify({ boosts: [invalid] });
    await assert.rejects(api.fetchProfile('owner', ProfileSection.Boosts), error => error.kind === ForumErrorKind.InvalidResponse, url);
  }
  api.get = async () => JSON.stringify({ boosts: [boost(120)] });
  await assert.rejects(api.fetchProfile('owner', ProfileSection.Boosts, 120), error => error.kind === ForumErrorKind.InvalidResponse);
  api.get = async () => JSON.stringify({ boosts: [boost(100, 'received')] });
  await assert.rejects(api.fetchProfile('owner', ProfileSection.Boosts), error => error.kind === ForumErrorKind.InvalidResponse);
});

test('a missing plugin, forbidden record and malformed response remain actionable errors instead of fake empty lists', async () => {
  for (const section of [ProfileSection.Votes, ProfileSection.Solutions, ProfileSection.Boosts]) {
    const api = new ForumApi();
    api.get = async () => { throw new ForumApiError(ForumErrorKind.NotFound, 404, 'not found'); };
    await assert.rejects(api.fetchProfile('owner', section), error => error.kind === ForumErrorKind.Unsupported);
    api.get = async () => { throw new ForumApiError(ForumErrorKind.Forbidden, 403, 'forbidden'); };
    await assert.rejects(api.fetchProfile('owner', section), error => error.kind === ForumErrorKind.Forbidden);
    api.get = async () => JSON.stringify({});
    await assert.rejects(api.fetchProfile('owner', section), error => error.kind === ForumErrorKind.InvalidResponse);
    api.get = async () => { throw new Error('private native detail'); };
    await assert.rejects(api.fetchProfile('owner', section), error => error.kind === ForumErrorKind.Network && !error.message.includes('private native detail'));
  }
});

test('plugin list replies cannot cross account generations or revive cancelled reads', async () => {
  for (const section of [ProfileSection.Votes, ProfileSection.Solutions, ProfileSection.Boosts]) {
    const api = new ForumApi();
    const response = deferred();
    api.get = async () => response.promise;
    const read = api.fetchProfile('owner', section);
    api.resetSessionContext();
    const rejected = assert.rejects(read, error => error.kind === ForumErrorKind.Cancelled);
    response.resolve('{}'); await rejected;
  }
});

test('Boost direction changes discard the former page and hidden personal lists cannot read or accept late results', async () => {
  const value = source('pages/ProfileSectionPage');
  const start = value.indexOf('export struct ProfileSectionPage');
  const body = (value.slice(start, value.indexOf('  build()', start)) + '\n}\n')
    .replace('export struct ProfileSectionPage', 'export class ProfileSectionPage')
    .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
  const session = { user: { id: 7, username: 'owner' }, revision: 1 };
  const pending = [];
  const api = { fetchProfile: (...args) => new Promise(resolve => { pending.push({ args, resolve }); }) };
  const { ProfileSectionPage } = compile(body, { ...models, forumSession: session, RequestCancellation, ForumApiError, ForumErrorKind, forumApi: api });
  const page = new ProfileSectionPage(); page.section = ProfileSection.Boosts;
  await page.load(true); assert.equal(pending.length, 0);
  page.visible = true;
  const first = page.load(true);
  page.chooseBoostDirection(ProfileBoostDirection.Received);
  assert.equal(pending[0].args[5].isCancelled, true);
  assert.equal(pending[1].args[6], ProfileBoostDirection.Received);
  pending[0].resolve({ fields: [], entries: [{ id: 'given' }], hasMore: true, nextCursor: 100 });
  await first; assert.deepEqual(page.entries, []);
  page.visible = false;
  pending[1].resolve({ fields: [], entries: [{ id: 'received' }], hasMore: false, nextCursor: 50 });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(page.entries, []);
});
