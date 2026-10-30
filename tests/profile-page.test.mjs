import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const models = load(source('models/ForumModels'));
function extract(name, terminator) {
  const page = source(`pages/${name}`);
  const start = page.indexOf(`export struct ${name}`);
  const end = page.indexOf(terminator, start);
  assert.ok(start >= 0 && end > start, 'Execute the actual production page lifecycle.');
  return (page.slice(start, end) + '\n}\n').replace(`export struct ${name}`, `export class ${name}`)
    .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
}
function runtime(name = 'ProfilePage') {
  const requests = [];
  const session = { user: { id: 8, username: 'first' }, revision: 1 };
  class RequestCancellation { isCancelled = false; cancel() { this.isCancelled = true; } }
  class ForumApiError extends Error { kind = 'network'; }
  const bindings = { ...models, forumSession: session, Scroller: class {},
    loadAppearanceSettings: () => ({}), $r: resource => resource,
    RequestCancellation, ForumApiError, ForumErrorKind: { VerificationRequired: 'verify', AuthenticationRequired: 'login' },
    forumApi: { fetchProfile: (...args) => new Promise((resolve, reject) => { requests.push({ args, resolve, reject }); }) }
  };
  const exported = load(extract(name, name === 'ProfilePage' ? '  @Builder' : '  build()'), bindings);
  const page = new exported[name]();
  // These method fixtures represent a shown NavDestination. Hidden-page
  // cancellation has separate coverage and must not trigger real reads here.
  if (name === 'ProfileSectionPage') { page.visible = true; }
  return { page, requests, session, ForumApiError };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
const stats = (topics, replies, likes) => ({ fields: [
  { label: '发表话题', value: topics }, { label: '回复数量', value: replies }, { label: '收到赞', value: likes }
], entries: [], hasMore: false, nextCursor: 0 });

test('profile statistics use confirmed summary values and leave unavailable values unknown', async () => {
  const rt = runtime();
  assert.equal(rt.page.topicCount, '—');
  rt.page.aboutToAppear();
  assert.equal(rt.requests[0].args[0], 'first');
  assert.equal(rt.requests[0].args[1], models.ProfileSection.Summary);
  rt.requests[0].resolve(stats('0', '12', '—')); await flush();
  assert.equal(rt.page.topicCount, '0'); assert.equal(rt.page.replyCount, '12'); assert.equal(rt.page.likesReceived, '—');
  assert.equal(rt.page.statisticsError, false);
});

test('account changes clear profile metrics immediately and old summary replies cannot repopulate them', async () => {
  const rt = runtime(); rt.page.aboutToAppear();
  rt.session.user = { id: 9, username: 'second' }; rt.session.revision++;
  rt.page.accountChanged();
  assert.equal(rt.requests[0].args[5].isCancelled, true);
  assert.equal(rt.page.topicCount, '—');
  rt.requests[0].resolve(stats('100', '200', '300')); await flush();
  assert.equal(rt.page.topicCount, '—');
  rt.requests[1].resolve(stats('4', '5', '6')); await flush();
  assert.equal(rt.page.topicCount, '4'); assert.equal(rt.page.replyCount, '5'); assert.equal(rt.page.likesReceived, '6');
});

test('unmounting cancels profile statistics and failures expose retry without inventing zero counts', async () => {
  const rt = runtime(); rt.page.aboutToAppear();
  rt.requests[0].reject(new Error('fixture unavailable')); await flush();
  assert.equal(rt.page.statisticsError, true); assert.equal(rt.page.topicCount, '—');
  const retry = rt.page.loadStatistics();
  rt.page.aboutToDisappear();
  assert.equal(rt.requests[1].args[5].isCancelled, true);
  rt.requests[1].resolve(stats('7', '8', '9')); await retry;
  assert.equal(rt.page.topicCount, '—');
  rt.page.accountChanged(); assert.equal(rt.requests.length, 2);
});

test('personal-list pagination failure retries the same cursor and preserves previous rows', async () => {
  const rt = runtime('ProfileSectionPage');
  rt.page.section = models.ProfileSection.Bookmarks;
  const first = rt.page.load(true);
  rt.requests[0].resolve({ fields: [], entries: [{ id: 'one' }], hasMore: true, nextCursor: 1 }); await first;
  const more = rt.page.load(false);
  rt.requests[1].reject(new rt.ForumApiError('fixture unavailable')); await more;
  assert.equal(rt.page.lastLoadReset, false); assert.equal(rt.page.cursor, 1);
  assert.deepEqual(rt.page.entries.map(entry => entry.id), ['one']);
  const retry = rt.page.load(rt.page.lastLoadReset);
  assert.equal(rt.requests[2].args[2], 1);
  rt.requests[2].resolve({ fields: [], entries: [{ id: 'two' }], hasMore: false, nextCursor: 2 }); await retry;
  assert.deepEqual(rt.page.entries.map(entry => entry.id), ['one', 'two']);
});

test('personal lists cancel and reject late private data after an account change', async () => {
  const rt = runtime('ProfileSectionPage');
  const pending = rt.page.load(true);
  rt.session.user = undefined; rt.session.revision++; rt.page.accountChanged();
  assert.equal(rt.requests[0].args[5].isCancelled, true);
  rt.requests[0].resolve({ fields: [], entries: [{ id: 'private' }], hasMore: true, nextCursor: 1 }); await pending;
  assert.deepEqual(rt.page.entries, []); assert.equal(rt.page.hasMore, false); assert.equal(rt.page.needsLogin, true);
});
