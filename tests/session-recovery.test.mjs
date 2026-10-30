import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(value => value && existsSync(value));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/services/${name}.ets`, import.meta.url), 'utf8');
function load(value, modules, globals = {}) {
  const compiled = ts.transpileModule(value, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } });
  const module = { exports: {} };
  const nativeRequire = name => {
    assert.ok(Object.hasOwn(modules, name), `Unexpected native I/O: ${name}`);
    return modules[name];
  };
  new Function('module', 'exports', 'require', ...Object.keys(globals), compiled.outputText)
    (module, module.exports, nativeRequire, ...Object.values(globals));
  return module.exports;
}
const http = { RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' } };
const modelSource = name => readFileSync(new URL(`../app/entry/src/main/ets/models/${name}.ets`, import.meta.url), 'utf8');
// Load actual pure local dependencies without opening the native-I/O allowlist.
const forumModels = load(modelSource('ForumModels'), {});
const forumWire = load(source('ForumWire'), { '../models/ForumModels': forumModels });
const userProfileModels = load(modelSource('UserProfileModels'), { './ForumModels': forumModels });
const userProfileWire = load(source('UserProfileWire'), {
  '../models/ForumModels': forumModels, '../models/UserProfileModels': userProfileModels, './ForumWire': forumWire
});
const directoryModels = load(modelSource('DirectoryModels'), { './ForumModels': forumModels });
const directoryWire = load(source('DirectoryWire'), { '../models/DirectoryModels': directoryModels, './ForumWire': forumWire });
const postRevisionModels = load(modelSource('PostRevisionModels'), { './ForumModels': forumModels });
const postRevisionWire = load(source('PostRevisionWire'), {
  '../models/ForumModels': forumModels, '../models/PostRevisionModels': postRevisionModels
});
const localApiModules = { '../models/UserProfileModels': userProfileModels, './UserProfileWire': userProfileWire,
  '../models/DirectoryModels': directoryModels, './DirectoryWire': directoryWire,
  '../models/PostRevisionModels': postRevisionModels, './PostRevisionWire': postRevisionWire };
const exports = load(source('ForumApi'), {
  '@kit.ArkTS': { url: { URL } },
  '@kit.NetworkKit': { http }, '@kit.ArkWeb': { webview: {} },
  '../models/ForumModels': { safeForumUrl: path => path.startsWith('/') && !path.startsWith('//') ? `https://linux.do${path}` : '' },
  './ForumWire': {}, ...localApiModules
});
const { ForumApi, ForumApiError, ForumErrorKind: Kind, RequestCancellation, READ_SESSION_RECOVERY_TIMEOUT_MS } = exports;
const mediaPolicy = load(source('BrowserMediaPolicy'), { '@kit.ArkTS': { url: { URL } } });
const mediaTransfer = load(source('BrowserMediaTransfer'), {
  '@kit.ArkTS': { util: {} }, './ForumApi': exports, './BrowserMediaPolicy': mediaPolicy
});
const response = (status, body = '{}', headers = {}) => ({ status, body, headers });
const challenge = () => response(403, '<html>Just a moment</html>', { 'cf-mitigated': 'challenge' });
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
const settle = () => new Promise(resolve => setImmediate(resolve));
function runtime(native = async () => challenge(), browser = async () => response(200, '{"restored":true}')) {
  const api = new ForumApi();
  const calls = [];
  const browserCalls = [];
  // Keep real production request/recovery/error paths, replacing only transport and time spacing.
  api.waitForSlot = async () => {};
  api.nativeRequest = async spec => { calls.push({ ...spec }); return native(spec); };
  api.registerBrowserTransport(async spec => { browserCalls.push({ ...spec }); return browser(spec); });
  const request = (method = 'GET', path = '/latest.json', token = new RequestCancellation()) =>
    api.request({ path, method, cancellation: token });
  return { api, calls, browserCalls, request };
}

test('concurrent challenged reads share one recovery and each replay exactly once in ArkWeb', async () => {
  const rt = runtime();
  const ready = deferred();
  let recoveries = 0;
  rt.api.registerBrowserRecovery(() => { recoveries++; return ready.promise; });
  const first = rt.request();
  const second = rt.request('GET', '/categories.json');
  await settle();
  assert.equal(recoveries, 1);
  ready.resolve(true);
  assert.equal(await first, '{"restored":true}');
  await second;
  assert.equal(rt.calls.length, 2);
  assert.equal(rt.browserCalls.length, 2);
  assert.equal(rt.api.activeRequests.size, 0);
});

test('a second challenge ends the read, and cooldown prevents repeated recoveries', async () => {
  const rt = runtime(undefined, async () => challenge());
  let recoveries = 0;
  rt.api.registerBrowserRecovery(async () => { recoveries++; return true; });
  for (let i = 0; i < 2; i++) { await assert.rejects(rt.request(), { kind: Kind.VerificationRequired }); }
  assert.equal(recoveries, 1);
  assert.equal(rt.calls.length, 1);
  assert.equal(rt.browserCalls.length, 2);
});

test('a late old challenge reuses the browser context already restored by another read', async () => {
  const late = deferred();
  const rt = runtime(spec => spec.path === '/late.json' ? late.promise : Promise.resolve(challenge()));
  let recoveries = 0;
  rt.api.registerBrowserRecovery(async () => { recoveries++; return true; });
  const pending = rt.request('GET', '/late.json');
  await settle();
  await rt.request();
  late.resolve(challenge());
  await pending;
  assert.equal(recoveries, 1);
  assert.deepEqual(rt.browserCalls.map(value => value.path), ['/latest.json', '/late.json']);
});

test('writes and uploads are never recovered or replayed after dispatch', async () => {
  for (const spec of [{ method: 'POST' }, { method: 'PUT' }, { method: 'DELETE' },
    { method: 'POST', multipart: [{ name: 'files[]' }] }]) {
    const rt = runtime();
    let recoveries = 0;
    rt.api.registerBrowserRecovery(async () => { recoveries++; return true; });
    await assert.rejects(rt.api.request({ ...spec, path: '/posts.json' }), { kind: Kind.VerificationRequired });
    assert.equal(rt.calls.length, 1);
    assert.equal(rt.browserCalls.length, 0);
    assert.equal(recoveries, 0);
  }
});

test('a CSRF read can recover before a write, which is then sent once with the new token', async () => {
  const rt = runtime(undefined, async spec => spec.path.includes('csrf') ?
    response(200, '{"csrf":"fresh-token"}') : response(200, '{"accepted":true}'));
  // These parsers are unrelated to the recovery fixture's native-module boundary.
  rt.api.parse = JSON.parse;
  rt.api.fetchCsrf = async cancellation => JSON.parse(await rt.api.get('/session/csrf.json', cancellation)).csrf;
  rt.api.registerBrowserRecovery(async () => true);
  await rt.api.mutate('/posts.json', 'POST', '{"raw":"fixture"}');
  const writes = rt.browserCalls.filter(value => value.method !== 'GET');
  assert.equal(writes.length, 1);
  assert.equal(writes[0].csrf, 'fresh-token');
});

test('permissions, expired logins, rate limits and uncertain writes never start recovery', async () => {
  for (const [status, body, kind] of [[403, '{"error":"forbidden"}', Kind.Forbidden],
    [401, '{}', Kind.AuthenticationRequired], [429, '{}', Kind.RateLimited], [500, '{}', Kind.Rejected]]) {
    const rt = runtime(async () => response(status, body));
    let recoveries = 0;
    rt.api.registerBrowserRecovery(async () => { recoveries++; return true; });
    await assert.rejects(rt.request(), { kind });
    assert.equal(recoveries, 0);
    assert.equal(rt.calls.length, 1);
  }
  const rt = runtime(async () => { throw new ForumApiError(Kind.UnknownResult, 0, 'uncertain'); });
  await assert.rejects(rt.request('POST'), { kind: Kind.UnknownResult });
  assert.equal(rt.calls.length, 1);
});

test('native session-cookie rotations and revocations flush promptly without changing a successful write receipt', async () => {
  for (const cookie of ['_t=fixture; Secure; HttpOnly', '_t=; Max-Age=0; Secure', 'cf_clearance=fixture; Secure']) {
    for (const diskFails of [false, true]) {
      const saved = [];
      let flushes = 0;
      const native = load(source('ForumApi'), {
        '@kit.ArkTS': { url: { URL } },
        '@kit.NetworkKit': { http: { ...http, HttpDataType: { STRING: 'string' }, createHttp: () => ({
          async request() { return { responseCode: 200, result: '{"accepted":true}', header: { 'Set-Cookie': cookie } }; }, destroy() {}
        }) } },
        '@kit.ArkWeb': { webview: { WebCookieManager: {
          async fetchCookie() { return ''; }, configCookieSync(...args) { saved.push(args); },
          async saveCookieAsync() { flushes++; if (diskFails) { throw new Error('fixture disk failure'); } }
        } } },
        '../models/ForumModels': { safeForumUrl: path => `https://linux.do${path}` }, './ForumWire': {}, ...localApiModules
      });
      const api = new native.ForumApi();
      api.waitForSlot = async () => {};
      assert.equal(await api.request({ path: '/session.json', method: 'POST' }), '{"accepted":true}');
      assert.equal(flushes, 1);
      assert.equal(saved[0][1], cookie);
    }
  }
});

test('cancelling one read does not cancel another consumer of shared recovery', async () => {
  const rt = runtime();
  const ready = deferred();
  let sharedToken;
  rt.api.registerBrowserRecovery(token => { sharedToken = token; return ready.promise; });
  const token = new RequestCancellation();
  const first = rt.request('GET', '/latest.json', token);
  const firstRejected = assert.rejects(first, { kind: Kind.Cancelled });
  const second = rt.request('GET', '/categories.json');
  await settle();
  token.cancel();
  await firstRejected;
  assert.equal(sharedToken.isCancelled, false);
  ready.resolve(true);
  await second;
  assert.deepEqual(rt.browserCalls.map(value => value.path), ['/categories.json']);
  assert.equal(token.handlers.size, 0);
});

test('session reset, backgrounding and manual navigation cancel recovery without reviving its context', async () => {
  for (const invalidate of [api => api.resetSessionContext(), api => api.setForeground(false),
    api => api.cancelSessionRecovery(), api => api.registerBrowserRecovery(undefined)]) {
    const rt = runtime();
    const ready = deferred();
    let sharedToken;
    rt.api.registerBrowserRecovery(token => { sharedToken = token; return ready.promise; });
    const pending = rt.request();
    const rejected = assert.rejects(pending, error => [Kind.Cancelled, Kind.VerificationRequired].includes(error.kind));
    await settle();
    invalidate(rt.api);
    await rejected;
    assert.equal(sharedToken.isCancelled, true);
    ready.resolve(true);
    await settle();
    assert.equal(rt.api.browserTransportEnabled, false);
    assert.equal(rt.browserCalls.length, 0);
  }
});

test('a new session generation can recover immediately and an older late result cannot replace its task', async () => {
  const api = new ForumApi();
  const attempts = [];
  api.registerBrowserRecovery(token => {
    const ready = deferred();
    attempts.push({ token, ready });
    return ready.promise;
  });
  const old = api.recoverReadSession(new RequestCancellation());
  await settle();
  assert.equal(attempts.length, 1);
  api.resetSessionContext();
  assert.equal(await old, false);
  const fresh = api.recoverReadSession(new RequestCancellation());
  await settle();
  assert.equal(attempts.length, 2, 'The previous generation cooldown must not block recovery.');
  const currentTask = api.recoveryTask;
  attempts[0].ready.resolve(true);
  await settle();
  assert.strictEqual(api.recoveryTask, currentTask, 'An old completion cannot clear a newer shared task.');
  assert.equal(api.browserTransportEnabled, false);
  attempts[1].ready.resolve(true);
  assert.equal(await fresh, true);
  assert.equal(api.getReadRecoveryVersion(), 1);
  assert.equal(api.recoveryTask, undefined);
});

test('recovery never navigates over an active write and new writes wait for existing recovery', async () => {
  const write = deferred();
  const rt = runtime(spec => spec.method === 'POST' ? write.promise : Promise.resolve(challenge()));
  let recoveries = 0;
  rt.api.registerBrowserRecovery(async () => { recoveries++; return true; });
  const pendingWrite = rt.request('POST');
  await settle();
  await assert.rejects(rt.request(), { kind: Kind.VerificationRequired });
  assert.equal(recoveries, 0);
  write.resolve(response(200));
  await pendingWrite;

  const ready = deferred();
  rt.api.registerBrowserRecovery(() => ready.promise);
  const read = rt.request();
  await settle();
  const newWrite = rt.request('POST');
  await settle();
  assert.equal(rt.browserCalls.length, 0);
  ready.resolve(true);
  await Promise.all([read, newWrite]);
  assert.equal(rt.browserCalls.filter(value => value.method === 'POST').length, 1);
});

test('the shared deadline releases callers even if a recovery handler never resolves', async () => {
  const deadlines = [];
  const isolated = load(source('ForumApi'), {
    '@kit.ArkTS': { url: { URL } },
    '@kit.NetworkKit': { http }, '@kit.ArkWeb': { webview: {} },
    '../models/ForumModels': { safeForumUrl: path => `https://linux.do${path}` }, './ForumWire': {}, ...localApiModules
  }, { setTimeout: (callback, delay) => { deadlines.push(delay); queueMicrotask(callback); return 1; }, clearTimeout() {} });
  const api = new isolated.ForumApi();
  let token;
  api.registerBrowserRecovery(value => { token = value; return new Promise(() => {}); });
  assert.equal(await api.recoverReadSession(new isolated.RequestCancellation()), false);
  assert.equal(token.isCancelled, true);
  assert.equal(api.recoveryTask, undefined);
  assert.equal(api.browserTransportEnabled, false);
  assert.deepEqual(deadlines, [READ_SESSION_RECOVERY_TIMEOUT_MS]);
});

function manualClock() {
  let now = 0;
  let nextId = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimeout(callback, delay = 0) { const id = ++nextId; timers.set(id, { callback, due: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    advance(delay) {
      const target = now + delay;
      while (true) {
        const next = [...timers].filter(([, value]) => value.due <= target).sort((a, b) => a[1].due - b[1].due)[0];
        if (!next) { break; }
        timers.delete(next[0]);
        now = next[1].due;
        next[1].callback();
      }
      now = target;
    },
    timers
  };
}

function adapterRuntime(probe, { navigates = true, documentState = 'interactive', documentOrigin = 'https://linux.do',
  topLevel = true, bridgeReady = true, commitDelay = 1, onLoad, saveCookie } = {}) {
  const clock = manualClock();
  let saves = 0;
  let nextRequestId = 0;
  let injections = 0;
  let adapter;
  const urls = [];
  const document = { readyState: documentState };
  const location = { origin: documentOrigin };
  const controller = { getUrl: () => urls.at(-1) || 'https://linux.do/', async runJavaScript(script) {
    if (script.includes('const request =')) { injections++; return 'started'; }
    const window = {}; window.top = topLevel ? window : {};
    if (bridgeReady) { window[adapter.bridgeName] = adapter.bridge; }
    const value = new Function('location', 'document', 'window', `return ${script}`)
      (location, document, window);
    return JSON.stringify(value);
  }, loadUrl(url) {
    urls.push(url);
    if (onLoad) {
      onLoad({ adapter, clock, document, location, urls });
    } else if (navigates) {
      adapter.pageStarted();
      clock.setTimeout(() => adapter.pageCommitted(), commitDelay);
    }
  } };
  const { BrowserTransportAdapter } = load(source('BrowserTransportAdapter'), {
    '@kit.ArkWeb': { webview: { WebCookieManager: { async saveCookieAsync() {
      saves++;
      if (saveCookie) { await saveCookie(); }
    } } } },
    '@kit.CryptoArchitectureKit': {}, './ForumApi': exports,
    './BrowserMediaPolicy': mediaPolicy, './BrowserMediaTransfer': mediaTransfer
  }, { Date: { now: clock.now }, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout });
  adapter = new BrowserTransportAdapter(controller);
  adapter.recoveryPause = async () => { clock.advance(250); };
  // The actual request implementation remains available for navigation/cancellation tests.
  adapter.requestToken = async () => (++nextRequestId).toString(16).padStart(32, '0');
  if (probe) { adapter.request = probe; }
  const completeCsrf = () => {
    const id = [...adapter.pending.keys()][0];
    assert.ok(id, 'A real pending CSRF bridge request is required.');
    adapter.receive(id, JSON.stringify({ status: 200, body: '{"csrf":"valid"}', headers: { contentType: 'application/json' } }));
  };
  return { adapter, controller, urls, clock, document, location, completeCsrf,
    injections: () => injections, saved: () => saves };
}

test('browser recovery requires an actual JSON CSRF receipt; a title, cookie or HTML 200 is insufficient', async () => {
  const good = adapterRuntime(async () => response(200, '{"csrf":"valid"}', { 'content-type': 'application/json; charset=utf-8' }));
  assert.equal(await good.adapter.recoverSession(new RequestCancellation()), true);
  assert.deepEqual(good.urls, ['https://linux.do/']);
  assert.equal(good.saved(), 1);
  for (const receipt of [response(200, '<html>Welcome</html>', { 'content-type': 'text/html' }),
    response(200, '{}', { 'content-type': 'application/json' }),
    response(200, '{"csrf":"valid"}', { 'content-type': 'application/json', 'cf-mitigated': 'challenge' }),
    challenge()]) {
    let probes = 0;
    const rt = adapterRuntime(async () => { probes++; return receipt; });
    assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
    assert.equal(rt.saved(), 0);
    assert.equal(probes, 3);
  }
});

test('browser recovery waits for a usable document and refuses to destroy pending requests', async () => {
  for (const blocked of ['pending', 'loading', 'cancelled']) {
    let probes = 0;
    const rt = adapterRuntime(async () => { probes++; throw new Error('must not probe'); }, { navigates: false });
    const token = new RequestCancellation();
    if (blocked === 'pending') { rt.adapter.pending.set('fixture', {}); }
    if (blocked === 'cancelled') { token.cancel(); }
    assert.equal(await rt.adapter.recoverSession(token), false);
    assert.equal(probes, 0);
    assert.equal(rt.urls.length, blocked === 'loading' ? 1 : 0);
  }
});

test('a newly committed same-origin interactive document can verify CSRF before slow resources finish loading', async () => {
  for (const documentState of ['interactive', 'complete']) {
    let probes = 0;
    const rt = adapterRuntime(async () => {
      probes++;
      return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' });
    }, { documentState });
    assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), true);
    assert.equal(probes, 1);
    assert.equal(rt.saved(), 1);
  }
  for (const context of [{ documentState: 'loading' },
    { documentState: 'interactive', documentOrigin: 'https://other.example' },
    { documentState: 'complete', documentOrigin: 'null', bridgeReady: false },
    { documentState: 'interactive', topLevel: false },
    { documentState: 'interactive', bridgeReady: false }]) {
    let probes = 0;
    const rt = adapterRuntime(async () => { probes++; throw new Error('unready context'); },
      context);
    assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
    assert.equal(probes, 0);
  }
});

test('an old interactive document cannot start a probe until this recovery navigation commits', async () => {
  let probes = 0;
  const rt = adapterRuntime(async () => { probes++; return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' }); },
    { navigates: false, documentState: 'complete' });
  // The existing page has an earlier valid commit, but loadUrl below has not committed yet.
  rt.adapter.pageCommitted();
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(probes, 0);
  assert.equal(rt.saved(), 0);
});

test('a slow new document committing after twelve seconds can still prove the session within the shared budget', async () => {
  let probes = 0;
  const rt = adapterRuntime(async () => {
    probes++;
    return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' });
  }, { commitDelay: 12000 });
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), true);
  assert.equal(rt.clock.now(), 12000);
  assert.equal(probes, 1);
  assert.equal(rt.saved(), 1);
  assert.equal(rt.clock.timers.size, 0);
});

test('a commit delivered before the corresponding PageBegin remains usable for startup verification', async () => {
  let probes = 0;
  const rt = adapterRuntime(async () => {
    probes++;
    return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' });
  }, { onLoad({ adapter, clock }) {
    clock.setTimeout(() => {
      adapter.pageCommitted();
      adapter.pageStarted();
    }, 1);
  } });
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), true);
  assert.equal(rt.urls.length, 1);
  assert.equal(probes, 1);
  assert.equal(rt.saved(), 1);
  assert.equal(rt.clock.timers.size, 0);
});

test('a late cookie save cannot confirm a cancelled, replaced, disposed, untrusted or expired document', async () => {
  for (const reason of ['page_begin_error', 'page_begin_only', 'error_origin_only', 'new_commit',
    'parent_cancel', 'deadline', 'disposed', 'untrusted_url']) {
    const saveEntered = deferred();
    const saveReleased = deferred();
    const rt = adapterRuntime(undefined, { saveCookie: () => {
      saveEntered.resolve();
      return saveReleased.promise;
    } });
    const token = new RequestCancellation();
    const pending = rt.adapter.recoverSession(token);
    await settle();
    assert.equal(rt.adapter.pending.size, 1, reason);
    rt.completeCsrf();
    await saveEntered.promise;
    if (reason === 'page_begin_error') { rt.adapter.pageStarted(); rt.location.origin = 'null'; }
    if (reason === 'page_begin_only') { rt.adapter.pageStarted(); }
    if (reason === 'error_origin_only') { rt.location.origin = 'null'; }
    if (reason === 'new_commit') { rt.adapter.pageCommitted(); }
    if (reason === 'parent_cancel') { token.cancel(); }
    if (reason === 'deadline') { rt.clock.advance(READ_SESSION_RECOVERY_TIMEOUT_MS - rt.clock.now()); }
    if (reason === 'disposed') { rt.adapter.dispose(); }
    if (reason === 'untrusted_url') { rt.controller.getUrl = () => 'https://other.example/'; }
    let finished = false;
    const outcome = pending.finally(() => { finished = true; });
    saveReleased.resolve();
    await settle();
    // If recovery continues, no replacement response is fabricated: a real pending
    // bridge request must expire under the original deadline before the result is false.
    if (!finished) { rt.clock.advance(Math.max(0, READ_SESSION_RECOVERY_TIMEOUT_MS - rt.clock.now())); }
    assert.equal(await outcome, false, reason);
    assert.equal(rt.saved(), 1, reason);
    assert.equal(rt.adapter.pending.size, 0, reason);
    assert.equal(token.handlers.size, 0, reason);
    assert.equal(rt.clock.timers.size, 0, reason);
  }
});

test('one main-frame connection reset can reload once and verify the next committed document', async () => {
  let probes = 0;
  const rt = adapterRuntime(async () => {
    probes++;
    return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' });
  }, { onLoad({ adapter, clock, location, urls }) {
    adapter.pageStarted();
    const first = urls.length === 1;
    clock.setTimeout(() => {
      if (first) {
        adapter.pageFailed(-101);
        adapter.pageFailed(-2); // A subsequent error callback must not erase the reset already observed.
        location.origin = 'null';
      } else { location.origin = 'https://linux.do'; }
      adapter.pageCommitted();
    }, 1);
  } });
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), true);
  assert.deepEqual(rt.urls, ['https://linux.do/', 'https://linux.do/']);
  assert.equal(probes, 1, 'Only the valid replacement document may dispatch CSRF.');
  assert.equal(rt.saved(), 1);
  assert.equal(rt.clock.timers.size, 0);
});

test('two consecutive main-frame connection resets stop after the one permitted navigation retry', async () => {
  let probes = 0;
  const rt = adapterRuntime(async () => { probes++; throw new Error('An error document must not be probed.'); },
    { onLoad({ adapter, clock, location }) {
      adapter.pageStarted();
      clock.setTimeout(() => {
        adapter.pageFailed(-101);
        location.origin = 'null';
        adapter.pageCommitted();
      }, 1);
    } });
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(rt.urls.length, 2);
  assert.equal(probes, 0);
  assert.equal(rt.saved(), 0);
  assert.ok(rt.clock.now() < READ_SESSION_RECOVERY_TIMEOUT_MS, 'A repeated reset stops without waiting out the deadline.');
  assert.equal(rt.clock.timers.size, 0);
});

test('certificate and other browser errors never trigger navigation retry, and an HTTP challenge does not reconnect', async () => {
  for (const code of [-202, -105, -2, -7]) {
    let probes = 0;
    const rt = adapterRuntime(async () => { probes++; throw new Error('An error document must not be probed.'); },
      { onLoad({ adapter, clock, location }) {
        adapter.pageStarted();
        clock.setTimeout(() => {
          adapter.pageFailed(code);
          location.origin = 'null';
          adapter.pageCommitted();
        }, 1);
      } });
    assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false, String(code));
    assert.equal(rt.urls.length, 1, String(code));
    assert.equal(probes, 0, String(code));
    assert.equal(rt.clock.timers.size, 0, String(code));
  }
  const challenged = adapterRuntime(async () => challenge());
  assert.equal(await challenged.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(challenged.urls.length, 1);
  assert.equal(challenged.saved(), 0);
});

test('cancellation or the shared deadline prevents a reset marker from reconnecting', async () => {
  for (const reason of ['cancel', 'deadline']) {
    const token = new RequestCancellation();
    const rt = adapterRuntime(async () => { throw new Error('No probe is permitted.'); },
      { onLoad({ adapter, clock }) {
        adapter.pageStarted();
        clock.setTimeout(() => {
          adapter.pageFailed(-101);
          if (reason === 'cancel') { token.cancel(); }
        }, reason === 'cancel' ? 1 : READ_SESSION_RECOVERY_TIMEOUT_MS);
      } });
    assert.equal(await rt.adapter.recoverSession(token), false, reason);
    assert.equal(rt.urls.length, 1, reason);
    assert.equal(rt.clock.timers.size, 0, reason);
    assert.equal(token.handlers.size, 0, reason);
  }
});

test('a reset never reconnects over a request that became active while the document was loading', async () => {
  const write = { request: { method: 'POST' }, fixture: 'already-dispatched' };
  const rt = adapterRuntime(async () => { throw new Error('No probe is permitted.'); },
    { onLoad({ adapter, clock }) {
      adapter.pageStarted();
      clock.setTimeout(() => {
        adapter.pending.set('existing-write', write);
        adapter.pageFailed(-101);
      }, 1);
    } });
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(rt.urls.length, 1);
  assert.strictEqual(rt.adapter.pending.get('existing-write'), write);
  assert.equal(rt.clock.timers.size, 0);
});

test('only a new main-frame document commitment advances recovery readiness', () => {
  const index = readFileSync(new URL('../app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const handler = /\.onNavigationEntryCommitted\(\(event: [^)]+\) => \{([\s\S]*?)\n\s{10}\}\)/.exec(index);
  assert.ok(handler, 'The production navigation-commit callback must remain extractable.');
  const callback = load('exports.committed = function(event) {' + handler[1] + '\n};', {}).committed;
  let commits = 0;
  const context = { browserAdapter: { pageCommitted() { commits++; } } };
  for (const event of [{ isMainFrame: false, isSameDocument: false },
    { isMainFrame: true, isSameDocument: true }, { isMainFrame: false, isSameDocument: true }]) {
    callback.call(context, event);
  }
  assert.equal(commits, 0);
  callback.call(context, { isMainFrame: true, isSameDocument: false });
  assert.equal(commits, 1);
  const failed = /\.onErrorReceive\(\(event: [^)]+\) => \{([\s\S]*?)\n\s{10}\}\)/.exec(index);
  assert.ok(failed, 'The production main-frame failure callback must remain extractable.');
  const failureCallback = load('exports.failed = function(event) {' + failed[1] + '\n};', {}).failed;
  const errors = [];
  context.browserAdapter.pageFailed = code => errors.push(code);
  failureCallback.call(context, { request: { isMainFrame: () => false }, error: { getErrorCode: () => -101 } });
  assert.deepEqual(errors, [], 'A failed subresource cannot trigger a document navigation retry.');
  failureCallback.call(context, { request: { isMainFrame: () => true }, error: { getErrorCode: () => -101 } });
  assert.deepEqual(errors, [-101]);
});

test('cancellation while inspecting the newly committed document prevents the CSRF request', async () => {
  let probes = 0;
  const token = new RequestCancellation();
  const rt = adapterRuntime(async () => { probes++; throw new Error('cancelled'); });
  rt.controller.runJavaScript = async () => { token.cancel(); return 'true'; };
  assert.equal(await rt.adapter.recoverSession(token), false);
  assert.equal(probes, 0);
});

test('a navigation-interrupted probe is removed and recovery retries on the next committed document', async () => {
  const rt = adapterRuntime();
  const token = new RequestCancellation();
  const pending = rt.adapter.recoverSession(token);
  await settle();
  assert.equal(rt.adapter.pending.size, 1);
  assert.equal(rt.injections(), 1);
  rt.adapter.pageStarted();
  assert.equal(rt.adapter.pending.size, 0, 'A document replacement must not leave the old CSRF promise hanging.');
  rt.adapter.pageCommitted();
  await settle();
  assert.equal(rt.injections(), 2);
  assert.equal(rt.adapter.pending.size, 1);
  rt.completeCsrf();
  assert.equal(await pending, true);
  assert.equal(rt.saved(), 1);
  assert.equal(rt.adapter.pending.size, 0);
  assert.equal(token.handlers.size, 0);
  assert.equal(rt.clock.timers.size, 0);
});

test('a document replacement releases pending reads while leaving an already dispatched write untouched', async () => {
  const rt = adapterRuntime();
  rt.adapter.pageCommitted();
  const write = rt.adapter.request({ path: '/posts.json', method: 'POST', body: '{"raw":"fixture"}', csrf: '' });
  const read = rt.adapter.request({ path: '/session/csrf.json', method: 'GET', body: '', csrf: '' });
  const rejectedRead = assert.rejects(read, { kind: Kind.Network });
  await settle();
  assert.equal(rt.adapter.pending.size, 2);
  rt.adapter.pageStarted();
  await rejectedRead;
  assert.equal(rt.adapter.pending.size, 1);
  const [writeId, writeEntry] = [...rt.adapter.pending][0];
  assert.equal(writeEntry.request.method, 'POST');
  rt.adapter.pageCommitted();
  rt.adapter.receive(writeId, JSON.stringify({ status: 200, body: '{"accepted":true}', headers: { contentType: 'application/json' } }));
  assert.equal((await write).body, '{"accepted":true}');
  assert.equal(rt.injections(), 2, 'The document event cannot issue or replay a write.');
  assert.equal(rt.clock.timers.size, 0);
});

test('temporary read-only probe failures retry at most three times without treating unrelated failures as retryable', async () => {
  for (const kind of [Kind.Network, Kind.Timeout, Kind.VerificationRequired]) {
    let probes = 0;
    const rt = adapterRuntime(async () => {
      if (++probes === 1) { throw new ForumApiError(kind, 0, 'fixture temporary failure'); }
      return response(200, '{"csrf":"valid"}', { 'content-type': 'application/json' });
    });
    assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), true, kind);
    assert.equal(probes, 2, kind);
    assert.equal(rt.clock.timers.size, 0, kind);
  }
  let probes = 0;
  const failed = adapterRuntime(async () => { probes++; throw new ForumApiError(Kind.Network, 0, 'fixture offline'); });
  assert.equal(await failed.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(probes, 3);
  assert.equal(failed.clock.timers.size, 0);
  for (const kind of [Kind.Forbidden, Kind.AuthenticationRequired, Kind.InvalidResponse, Kind.Cancelled]) {
    let calls = 0;
    const rejected = adapterRuntime(async () => { calls++; throw new ForumApiError(kind, 0, 'fixture terminal failure'); });
    assert.equal(await rejected.adapter.recoverSession(new RequestCancellation()), false, kind);
    assert.equal(calls, 1, kind);
    assert.equal(rejected.saved(), 0, kind);
  }
});

test('parent cancellation and session reset stop an in-flight probe without starting another request', async () => {
  for (const reason of ['parent', 'session']) {
    const rt = adapterRuntime();
    const token = new RequestCancellation();
    const api = new ForumApi();
    api.registerBrowserRecovery(request => rt.adapter.recoverSession(request));
    const pending = reason === 'session' ? api.recoverReadSession(token) : rt.adapter.recoverSession(token);
    await settle();
    assert.equal(rt.injections(), 1, reason);
    if (reason === 'session') { api.resetSessionContext(); } else { token.cancel(); }
    assert.equal(await pending, false, reason);
    assert.equal(rt.injections(), 1, reason);
    assert.equal(rt.adapter.pending.size, 0, reason);
    assert.equal(rt.clock.timers.size, 0, reason);
    assert.equal(token.handlers.size, 0, reason);
    assert.equal(api.browserTransportEnabled, false, reason);
  }
});

test('the remaining total recovery budget cancels an in-flight probe and clears pending requests and timers', async () => {
  const rt = adapterRuntime(undefined, { commitDelay: 24000 });
  const token = new RequestCancellation();
  const pending = rt.adapter.recoverSession(token);
  await settle();
  assert.equal(rt.clock.now(), 24000, 'A document that takes 24 seconds leaves one second for CSRF.');
  assert.equal(rt.adapter.pending.size, 1);
  rt.clock.advance(999);
  assert.equal(rt.adapter.pending.size, 1, 'The in-flight probe remains valid before its remaining deadline.');
  rt.clock.advance(1);
  assert.equal(await pending, false);
  assert.equal(rt.adapter.pending.size, 0);
  assert.equal(rt.injections(), 1);
  assert.equal(token.handlers.size, 0);
  assert.equal(rt.clock.timers.size, 0);
  assert.equal(token.isCancelled, false, 'The probe timeout must not cancel its parent consumer.');
});

test('only same-site images join recovery and scope changes prevent their retry', async () => {
  const media = source('ForumMedia');
  const start = media.indexOf('async function requestMediaWithRecovery(');
  const end = media.indexOf('async function fetchAndCache(', start);
  const production = media.slice(start, end) + '\nexports.requestImage = requestMediaWithRecovery;';
  for (const [host, changed, recoveries, requests] of [
    ['linux.do', false, 1, 2], ['cdn.example.test', false, 0, 1], ['linux.do', true, 1, 1]
  ]) {
    let reads = 0;
    let repairs = 0;
    const module = load(production, {}, {
      ForumApiError, ForumErrorKind: Kind,
      requestMedia: async () => { if (++reads === 1) { throw new ForumApiError(Kind.VerificationRequired, 403, 'challenge'); } return new ArrayBuffer(1); },
      forumApi: { getReadRecoveryVersion: () => 0, canUseBrowserMedia: () => false,
        async recoverReadSession() { repairs++; return true; } },
      ensureScope: () => { if (changed) { throw new ForumApiError(Kind.Cancelled, 0, 'account changed'); } }
    });
    const result = module.requestImage({ hostname: host }, {}, new RequestCancellation());
    if (host === 'linux.do' && !changed) { await result; }
    else { await assert.rejects(result, { kind: changed ? Kind.Cancelled : Kind.VerificationRequired }); }
    assert.equal(reads, requests);
    assert.equal(repairs, recoveries);
  }
});

test('a late native image challenge uses the browser session another read already restored once', async () => {
  const media = source('ForumMedia');
  const start = media.indexOf('async function requestMediaWithRecovery(');
  const end = media.indexOf('async function fetchAndCache(', start);
  const production = media.slice(start, end) + '\nexports.requestImage = requestMediaWithRecovery;';
  let version = 0, reads = 0, recoveries = 0;
  const module = load(production, {}, {
    ForumApiError, ForumErrorKind: Kind,
    requestMedia: async () => {
      if (++reads === 1) { version++; throw new ForumApiError(Kind.VerificationRequired, 403, 'old native challenge'); }
      return new Uint8Array([71, 73, 70]).buffer;
    },
    forumApi: { getReadRecoveryVersion: () => version, canUseBrowserMedia: () => version > 0,
      async recoverReadSession() { recoveries++; return false; } },
    ensureScope() {}
  });
  const bytes = await module.requestImage({ hostname: 'linux.do' }, {}, new RequestCancellation());
  assert.equal(bytes.byteLength, 3);
  assert.equal(reads, 2);
  assert.equal(recoveries, 0);
});
