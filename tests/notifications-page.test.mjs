import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// Exercise actual page methods and the rendered retry callback. Native rendering
// stays in device acceptance; requests here are deferred, local-only fixtures.
const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
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
const pageSource = source('pages/NotificationsPage');
const start = pageSource.indexOf('export struct NotificationsPage');
const end = pageSource.indexOf('  @LocalBuilder', start);
const retry = /onRetry: \(\): void => \{ ([^\n]+) \}, onVerify:/.exec(pageSource);
assert.ok(start >= 0 && end > start && retry, 'Extract production page logic and its actual error retry callback.');
const pageClass = (pageSource.slice(start, end) + `\n  retryFromUI(): void { ${retry[1]} }\n}\n`)
  .replace('export struct NotificationsPage', 'export class NotificationsPage')
  .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');

function runtime({ embedded = false, active = true, visible = true } = {}) {
  const requests = [];
  const writes = [];
  const opened = [];
  const messages = [];
  const session = { user: { id: 7 }, revision: 1, unreadRefreshes: 0,
    async refreshUnread() { this.unreadRefreshes++; } };
  class RequestCancellation {
    isCancelled = false;
    cancel() { this.isCancelled = true; }
  }
  class ForumApiError extends Error {
    constructor(message, kind = 'network') { super(message); this.kind = kind; }
  }
  const exports = load(pageClass, {
    notificationFilters: models.notificationFilters,
    forumSession: session,
    loadAppearanceSettings: () => ({}),
    Scroller: class { edges = []; scrollEdge(edge) { this.edges.push(edge); } },
    Edge: { Top: 'top' }, RequestCancellation, ForumApiError,
    ForumErrorKind: { VerificationRequired: 'verification', AuthenticationRequired: 'authentication' },
    forumApi: {
      fetchNotifications: (offset, filter, token) => new Promise((resolve, reject) => {
        requests.push({ offset, filter, token, resolve, reject });
      }),
      markNotificationRead: id => new Promise((resolve, reject) => { writes.push({ id, resolve, reject }); })
    }
  });
  const page = new exports.NotificationsPage();
  // Request tests start in an already visible destination. Lifecycle tests
  // explicitly start unmounted and hidden, then drive the production callbacks.
  page.embedded = embedded; page.active = active; page.visible = visible;
  page.onOpenTopic = (...args) => opened.push(args);
  page.getUIContext = () => ({ getPromptAction: () => ({ showToast: options => messages.push(options.message) }) });
  return { page, requests, writes, session, opened, messages, ForumApiError };
}

const notice = (id, read = false) => ({ id, read, type: 2, title: `Notification ${id}`, label: '回复',
  actor: 'fixture', avatarUrl: '', createdAt: '2026-10-12T09:00:00Z', topicId: 42, postNumber: 3 });
const settle = () => new Promise(resolve => setImmediate(resolve));
async function finish(request, notifications, nextOffset = 60, hasMore = true) {
  request.resolve({ notifications, nextOffset, hasMore });
  await settle();
}

test('switching tabs immediately clears the old category and ignores old responses in either completion order', async () => {
  for (const oldFirst of [true, false]) {
    const { page, requests } = runtime();
    page.items = [notice(1)]; page.notificationOffset = 180; page.hasMore = true;
    void page.load(false);
    page.selectFilter(2);
    assert.equal(requests[0].token.isCancelled, true);
    assert.equal(page.filterIndex, 2);
    assert.deepEqual(page.items, []);
    assert.equal(page.notificationOffset, 0);
    assert.equal(page.hasMore, false);
    assert.deepEqual(page.listScroller.edges, ['top']);
    assert.equal(requests[1].offset, 0);
    assert.equal(requests[1].filter, models.NotificationFilter.Likes);
    if (oldFirst) {
      await finish(requests[0], [notice(9)], 240);
      assert.deepEqual(page.items, []);
      assert.equal(page.busy, true, 'old finally cannot stop the new tab spinner');
    }
    await finish(requests[1], [notice(2)], 60, false);
    if (!oldFirst) { await finish(requests[0], [notice(9)], 240); }
    assert.deepEqual(page.items.map(item => item.id), [2]);
    assert.equal(page.notificationOffset, 60);
    assert.equal(page.hasMore, false);
    assert.equal(page.busy, false);
  }
});

test('rapid tab changes discard stale failures and selecting the current or invalid tab does not reload', async () => {
  const { page, requests, ForumApiError } = runtime();
  page.selectFilter(1); page.selectFilter(3);
  assert.equal(requests.length, 2);
  page.selectFilter(3); page.selectFilter(-1); page.selectFilter(models.notificationFilters.length);
  assert.equal(requests.length, 2);
  requests[0].reject(new ForumApiError('stale authentication failure', 'authentication'));
  await settle();
  assert.equal(page.error, ''); assert.equal(page.needsLogin, false); assert.equal(page.busy, true);
  await finish(requests[1], [notice(3)]);
  assert.deepEqual(page.items.map(item => item.id), [3]);
});

test('losing the session cancels requests and clears private rows even if the former response arrives later', async () => {
  const { page, requests, session } = runtime();
  page.shown();
  page.items = [notice(1)]; page.notificationOffset = 120; page.hasMore = true;
  session.user = undefined; session.revision++;
  page.accountChanged();
  assert.equal(requests[0].token.isCancelled, true);
  assert.deepEqual(page.items, []); assert.equal(page.notificationOffset, 0); assert.equal(page.hasMore, false);
  assert.equal(page.needsLogin, true); assert.equal(page.busy, false);
  assert.equal(requests.length, 1, 'signed-out state must not request private notifications');
  await finish(requests[0], [notice(99)]);
  assert.deepEqual(page.items, []); assert.equal(page.needsLogin, true);
});

test('a visible account change reloads and a response cannot survive an owner or revision change', async () => {
  const { page, requests, session } = runtime();
  page.shown();
  session.user = { id: 8 }; session.revision++;
  page.accountChanged();
  assert.equal(requests.length, 2); assert.equal(requests[0].token.isCancelled, true);
  await finish(requests[1], [notice(8)]);
  await finish(requests[0], [notice(7)]);
  assert.deepEqual(page.items.map(item => item.id), [8]);
  for (const change of ['owner', 'revision']) {
    const next = runtime();
    void next.page.load(true);
    if (change === 'owner') { next.session.user = { id: 9 }; } else { next.session.revision++; }
    await finish(next.requests[0], [notice(7)]);
    assert.deepEqual(next.page.items, [], 'response guards also cover the interval before the monitor runs');
  }
});

test('hidden notification requests are cancelled and shown restarts incomplete work only', async () => {
  const { page, requests } = runtime();
  page.shown(); page.refreshing = true; page.hidden();
  assert.equal(requests[0].token.isCancelled, true);
  assert.equal(page.visible, false); assert.equal(page.busy, false); assert.equal(page.refreshing, false);
  await finish(requests[0], [notice(1)]);
  assert.deepEqual(page.items, []);
  page.shown();
  assert.equal(requests.length, 2); assert.equal(requests[1].offset, 0);
  await finish(requests[1], [notice(2)]);
  page.hidden(); page.shown();
  assert.equal(requests.length, 2, 'returning from a topic keeps a completed notification list');
});

test('returning from login loads the currently selected category through shown', async () => {
  const { page, requests, session } = runtime();
  session.user = undefined; page.filterIndex = 3; page.shown();
  assert.equal(page.needsLogin, true); assert.equal(requests.length, 0);
  page.hidden(); session.user = { id: 8 }; session.revision++; page.accountChanged();
  assert.equal(requests.length, 0, 'the hidden destination waits until login navigation returns');
  page.shown();
  assert.equal(requests.length, 1); assert.equal(requests[0].filter, models.NotificationFilter.Messages);
  await finish(requests[0], [notice(8)]);
  assert.equal(page.needsLogin, false); assert.deepEqual(page.items.map(item => item.id), [8]);
});

test('an embedded message tab stays idle until mounted and active, including account changes', async () => {
  const { page, requests, session } = runtime({ embedded: true, active: false, visible: false });
  page.activeChanged(); page.embeddedAppeared();
  assert.equal(requests.length, 0); assert.equal(page.visible, false);
  page.filterIndex = 2;
  session.user = { id: 8 }; session.revision++; page.accountChanged();
  page.retryFromUI();
  assert.equal(requests.length, 0, 'cached inactive tabs do not fetch private notifications');
  page.active = true; page.activeChanged(); page.activeChanged();
  assert.equal(requests.length, 1, 'activation starts one request');
  assert.equal(requests[0].filter, models.NotificationFilter.Likes);
  await finish(requests[0], [notice(8)], 120, true);
  assert.equal(page.visible, true);
  assert.deepEqual(page.items.map(item => item.id), [8]);
});

test('main tab switches retain the selected filter, completed rows, cursor and external scroller', async () => {
  const { page, requests } = runtime({ embedded: true, visible: false });
  const scroller = { edges: [], position: 620, scrollEdge(edge) { this.edges.push(edge); this.position = 0; } };
  page.listScroller = scroller;
  page.filterIndex = 3; page.embeddedAppeared();
  await finish(requests[0], [notice(3)], 180, true);
  page.active = false; page.activeChanged();
  assert.equal(page.visible, false);
  page.active = true; page.activeChanged();
  assert.equal(page.visible, true); assert.equal(requests.length, 1);
  assert.equal(page.filterIndex, 3); assert.equal(page.notificationOffset, 180); assert.equal(page.hasMore, true);
  assert.deepEqual(page.items.map(item => item.id), [3]);
  assert.equal(page.listScroller, scroller); assert.equal(scroller.position, 620); assert.deepEqual(scroller.edges, []);
});

test('covering an embedded message tab cancels pending work and rejects responses before the active monitor', async () => {
  for (const completion of ['success', 'failure']) {
    const { page, requests, ForumApiError } = runtime({ embedded: true, visible: false });
    page.embeddedAppeared();
    page.active = false;
    if (completion === 'success') { await finish(requests[0], [notice(7)]); }
    else { requests[0].reject(new ForumApiError('covered login failure', 'authentication')); await settle(); }
    assert.deepEqual(page.items, []); assert.equal(page.error, ''); assert.equal(page.needsLogin, false);
    page.activeChanged();
    assert.equal(requests[0].token.isCancelled, true); assert.equal(page.visible, false);
    page.active = true; page.activeChanged();
    assert.equal(requests.length, 2);
    await finish(requests[1], [notice(8)]);
    assert.deepEqual(page.items.map(item => item.id), [8]);
  }
});

test('an embedded login return reloads the selected category only after navigation uncovers it', async () => {
  const { page, requests, session } = runtime({ embedded: true, visible: false });
  session.user = undefined; page.filterIndex = 3; page.embeddedAppeared();
  assert.equal(page.needsLogin, true); assert.equal(requests.length, 0);
  page.active = false; page.activeChanged();
  session.user = { id: 8 }; session.revision++; page.accountChanged();
  assert.equal(requests.length, 0);
  page.active = true; page.activeChanged();
  assert.equal(requests.length, 1); assert.equal(requests[0].filter, models.NotificationFilter.Messages);
  await finish(requests[0], [notice(8)]);
  assert.equal(page.needsLogin, false); assert.deepEqual(page.items.map(item => item.id), [8]);
});

test('embedded activation cannot start requests before appearance or after disappearance', async () => {
  const { page, requests } = runtime({ embedded: true, visible: false });
  page.activeChanged(); page.shown();
  assert.equal(requests.length, 0);
  page.embeddedAppeared();
  assert.equal(requests.length, 1);
  page.embeddedDisappeared();
  assert.equal(requests[0].token.isCancelled, true);
  page.activeChanged(); page.shown();
  assert.equal(requests.length, 1);
  await finish(requests[0], [notice(7)]);
  assert.deepEqual(page.items, []);
  page.embeddedAppeared();
  assert.equal(requests.length, 2);
  await finish(requests[1], [notice(8)]);
  assert.deepEqual(page.items.map(item => item.id), [8]);
});

test('pagination failure retries the same cursor and successful continuation appends without duplicates', async () => {
  const { page, requests, ForumApiError } = runtime();
  page.items = [notice(1)]; page.notificationOffset = 180; page.hasMore = true;
  void page.load(false); void page.load(false);
  assert.equal(requests.length, 1);
  requests[0].reject(new ForumApiError('fixture pagination failure')); await settle();
  assert.equal(page.notificationOffset, 180); assert.equal(page.busy, false);
  assert.deepEqual(page.items.map(item => item.id), [1]);
  page.retryFromUI();
  assert.equal(requests[1].offset, 180);
  await finish(requests[1], [notice(1), notice(2)], 240, false);
  assert.deepEqual(page.items.map(item => item.id), [1, 2]);
  assert.equal(page.notificationOffset, 240); assert.equal(page.hasMore, false); assert.equal(page.error, '');
});

test('a failed pull refresh retries from zero and replaces old rows despite an existing history cursor', async () => {
  const { page, requests, ForumApiError } = runtime();
  page.items = [notice(1)]; page.notificationOffset = 180; page.hasMore = true; page.refreshing = true;
  void page.load(true);
  assert.equal(requests[0].offset, 0);
  requests[0].reject(new ForumApiError('fixture refresh failure')); await settle();
  assert.equal(page.notificationOffset, 180); assert.equal(page.busy, false); assert.equal(page.refreshing, false);
  assert.deepEqual(page.items.map(item => item.id), [1]);
  page.retryFromUI();
  assert.equal(requests[1].offset, 0, 'retry must preserve refresh intent instead of inferring it from the old cursor');
  await finish(requests[1], [notice(2)], 60, false);
  assert.deepEqual(page.items.map(item => item.id), [2]);
  assert.equal(page.notificationOffset, 60); assert.equal(page.error, '');
});

test('mark-read receipts update the row and badge only for the account that opened it', async () => {
  const current = runtime();
  current.page.items = [notice(1)]; current.page.open(current.page.items[0]);
  assert.deepEqual(current.opened, [[42, 3]]); assert.equal(current.writes.length, 1);
  assert.equal(current.page.items[0].read, false, 'read state waits for the receipt');
  current.writes[0].resolve(); await settle();
  assert.equal(current.page.items[0].read, true); assert.equal(current.session.unreadRefreshes, 1);
  current.page.open(current.page.items[0]);
  assert.equal(current.writes.length, 1, 'already-read rows do not submit another write');
  for (const change of ['owner', 'revision']) {
    const next = runtime();
    next.page.items = [notice(1)]; next.page.open(next.page.items[0]);
    if (change === 'owner') { next.session.user = { id: 8 }; } else { next.session.revision++; }
    next.page.items = [notice(1), notice(2)];
    next.writes[0].resolve(); await settle();
    assert.equal(next.page.items[0].read, false);
    assert.equal(next.session.unreadRefreshes, 0);
  }
});

test('late mark-read failures remain silent after hiding or changing account', async () => {
  for (const change of ['none', 'hidden', 'owner']) {
    const { page, writes, session, messages } = runtime();
    page.visible = true; page.items = [notice(1)]; page.open(page.items[0]);
    if (change === 'hidden') { page.hidden(); }
    if (change === 'owner') { session.user = { id: 8 }; session.revision++; }
    writes[0].reject(new Error('fixture read receipt failure')); await settle();
    assert.deepEqual(messages, change === 'none' ? ['已读状态暂时未同步'] : []);
    assert.equal(page.items[0].read, false);
  }
});

test('notification row keys refresh changed content and navigation targets even when id and read are unchanged', () => {
  const callback = /^\s*\}, (\(item: ForumNotification\): string => [^\n]+)\)\s*$/m.exec(pageSource);
  assert.ok(callback, 'Extract the actual notification ForEach key callback.');
  const { notificationKey } = load(`export const notificationKey = ${callback[1]};`);
  const original = notice(1);
  const key = notificationKey(original);
  assert.equal(notificationKey({ ...original }), key, 'unchanged content keeps the same row key');
  for (const [field, value] of [
    ['title', 'Updated topic title'], ['actor', 'new_actor'], ['avatarUrl', 'https://linux.do/avatar.png'],
    ['topicId', 77], ['postNumber', 8], ['read', true], ['label', '私信'],
    ['createdAt', '2026-10-12T10:00:00Z']
  ]) {
    const updated = { ...original, [field]: value };
    assert.equal(updated.id, original.id);
    if (field !== 'read') { assert.equal(updated.read, original.read); }
    assert.notEqual(notificationKey(updated), key, `${field} updates must rebuild the row and its click closure`);
  }
  assert.equal(notificationKey(original), key, 'key calculation does not mutate notification content');
});
