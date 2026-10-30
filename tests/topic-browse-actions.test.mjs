import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = fileURLToPath(new URL('../app/entry/src/main/ets/', import.meta.url));
const modules = new Map();
const methods = { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' };
function load(name) {
  if (modules.has(name)) return modules.get(name);
  const compiled = ts.transpileModule(readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(value => value.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} }; modules.set(name, module.exports);
  const boundary = id => {
    if (id === '@kit.NetworkKit') return { http: { RequestMethod: methods } };
    if (id === '@kit.ArkWeb') return { webview: {} };
    if (id === '@kit.BasicServicesKit') return {};
    if (id === '@kit.ArkTS') return { url: { URL } };
    assert.ok(id.startsWith('.'), `Unmocked boundary ${id}`);
    return load(path.normalize(path.join(path.dirname(name), id)));
  };
  new Function('require', 'module', 'exports', compiled.outputText)(boundary, module, module.exports);
  return module.exports;
}
const { ForumApi, ForumErrorKind } = load('services/ForumApi');
const { TopicFeedFilter } = load('models/ForumModels');
const { postFromWire } = load('services/ForumWire');

test('all five feeds preserve category, encoded tag, sort and ranking period on pagination', async () => {
  const api = new ForumApi(); const paths = [];
  api.get = async path => { paths.push(path); return JSON.stringify({ topic_list: { topics: [] } }); };
  const options = { categoryId: 4, tagName: '人工智能 & API', sortOrder: 'likes', topPeriod: 'monthly' };
  for (const filter of Object.values(TopicFeedFilter)) {
    await api.fetchTopicFeed(filter, 2, undefined, options);
    const url = new URL('https://linux.do' + paths.at(-1));
    assert.equal(url.pathname, `/${filter}.json`);
    assert.equal(url.searchParams.get('page'), '2');
    assert.equal(url.searchParams.get('category'), '4');
    assert.equal(url.searchParams.get('tags[]'), options.tagName);
    assert.equal(url.searchParams.get('order'), 'likes');
    assert.equal(url.searchParams.get('ascending'), 'false');
    assert.equal(url.searchParams.get('period'), filter === 'top' ? 'monthly' : null);
  }
  await api.fetchTopicFeed(TopicFeedFilter.Top, 0);
  assert.equal(paths.at(-1), '/top.json?page=0&period=weekly');
});

test('invalid browse scope is rejected before any request', async () => {
  const api = new ForumApi(); api.get = async () => assert.fail('No request allowed');
  const valid = { categoryId: 0, tagName: '', sortOrder: '', topPeriod: 'weekly' };
  for (const changes of [{ categoryId: -1 }, { categoryId: 1.5 }, { tagName: 'x\n' },
    { tagName: 'x'.repeat(101) }, { sortOrder: 'likes&admin=true' }, { topPeriod: 'forever' }]) {
    await assert.rejects(api.fetchTopicFeed(TopicFeedFilter.Latest, 0, undefined, { ...valid, ...changes }),
      error => error.kind === ForumErrorKind.Rejected);
  }
});

test('topic notifications accept only explicit server receipts and do not retry unknown writes', async () => {
  const api = new ForumApi(); const calls = [];
  api.mutate = async (...args) => { calls.push(args); return '{"success":"OK"}'; };
  await api.setTopicNotificationLevel(42, 3);
  assert.equal(calls[0][0], '/t/42/notifications.json');
  assert.equal(calls[0][1], 'POST');
  assert.deepEqual(JSON.parse(calls[0][2]), { notification_level: 3 });
  for (const raw of ['', '{}', '{"success":false}']) {
    calls.length = 0; api.mutate = async (...args) => { calls.push(args); return raw; };
    await assert.rejects(api.setTopicNotificationLevel(42, 0));
    assert.equal(calls.length, 1);
  }
  calls.length = 0;
  await assert.rejects(api.setTopicNotificationLevel(42, 5));
  assert.equal(calls.length, 0);
});

test('flag choices come only from actionable server permissions and submission verifies the returned post', async () => {
  const wire = { id: 20, topic_id: 42, post_number: 7, cooked: '<p>fixture</p>',
    actions_summary: [{ id: 3, can_act: true }, { id: 4, can_act: false }, { id: 7 }, { id: 8, can_act: true }, { id: 99, can_act: true }] };
  assert.deepEqual(postFromWire(wire).flagTypes, [3, 8]);
  const api = new ForumApi(); const calls = [];
  api.mutate = async (...args) => { calls.push(args); return JSON.stringify(wire); };
  assert.equal((await api.flagPost(20, 8, 'Please review this fixture')).id, 20);
  assert.equal(calls[0][0], '/post_actions.json');
  assert.deepEqual(JSON.parse(calls[0][2]), { id: 20, post_action_type_id: 8, message: 'Please review this fixture' });
  for (const raw of ['', '{}', JSON.stringify({ ...wire, id: 21 })]) {
    calls.length = 0; api.mutate = async (...args) => { calls.push(args); return raw; };
    await assert.rejects(api.flagPost(20, 3, ''), error => error.kind === ForumErrorKind.UnknownResult);
    assert.equal(calls.length, 1);
  }
  calls.length = 0;
  await assert.rejects(api.flagPost(20, 8, ''));
  await assert.rejects(api.flagPost(20, 1, ''));
  assert.equal(calls.length, 0);
});
