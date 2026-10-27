import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(value => value && existsSync(value));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const compiled = new Map();
function load(name, modules, globals = {}) {
  if (!compiled.has(name)) {
    const source = readFileSync(new URL(`../app/entry/src/main/ets/services/${name}.ets`, import.meta.url), 'utf8');
    compiled.set(name, ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
    } }).outputText);
  }
  const module = { exports: {} };
  const nativeRequire = name => {
    assert.ok(Object.hasOwn(modules, name), `Unexpected native I/O: ${name}`);
    return modules[name];
  };
  new Function('module', 'exports', 'require', ...Object.keys(globals), compiled.get(name))
    (module, module.exports, nativeRequire, ...Object.values(globals));
  return module.exports;
}
const apiExports = load('ForumApi', {
  '@kit.ArkTS': { url: { URL } },
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' } } },
  '@kit.ArkWeb': { webview: {} }, '@kit.BasicServicesKit': {},
  '../models/ForumModels': {}, './ForumWire': {}
});
const { ForumApi, RequestCancellation, ForumErrorKind: Kind } = apiExports;
const policy = load('BrowserMediaPolicy', { '@kit.ArkTS': { url: { URL } } });
const transferExports = load('BrowserMediaTransfer', {
  '@kit.ArkTS': { util: { Base64Helper: class {
    decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
  } } }, './ForumApi': apiExports, './BrowserMediaPolicy': policy
});
const { BrowserMediaTransfer } = transferExports;
const tick = () => new Promise(resolve => setImmediate(resolve));
const start = { type: 'start', status: 200, headers: { contentType: 'image/png' } };
const frame = (transfer, value) => transfer.accept(JSON.stringify(value));

// Execute the actual injected script, bridge dispatch, transfer decoder and cancellation paths.
// Only the OS web controller, crypto RNG and HTTP response source are replaced.
function runtime({ bytes = new Uint8Array([1, 2, 3]), status = 200, mime = 'image/png',
  mitigated = '', hold = false, declared = 0 } = {}) {
  const frames = [], calls = [], timers = new Map();
  let timerId = 0, now = 0, navigations = 0;
  const clock = {
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  const { BrowserTransportAdapter } = load('BrowserTransportAdapter', {
    '@kit.ArkWeb': { webview: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {
      createRandom: () => ({ generateRandom: async size => ({ data: new Uint8Array(randomBytes(size)) }) })
    } }, './ForumApi': apiExports, './BrowserMediaPolicy': policy,
    './BrowserMediaTransfer': transferExports
  }, { ...clock, canIUse: () => true, Date: { now: () => now } });
  const window = {}; window.top = window;
  const location = { origin: 'https://linux.do' };
  let adapter;
  const context = vm.createContext({ window, location, URL, Map, Uint8Array, TextDecoder,
    AbortController, ...clock, btoa: value => Buffer.from(value, 'binary').toString('base64'),
    fetch: async (url, options) => {
      calls.push({ url, options });
      if (hold) {
        return new Promise((resolve, reject) => {
          options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
          if (options.signal.aborted) reject(new Error('aborted'));
        });
      }
      let offset = 0;
      return { url, status, ok: status >= 200 && status < 300,
        headers: { get: name => ({ 'content-type': mime, 'cf-mitigated': mitigated,
          'content-length': String(declared) })[name] || '' },
        body: { getReader: () => ({
          async read() {
            if (options.signal.aborted) throw new Error('aborted');
            if (offset >= bytes.byteLength) return { done: true };
            // Deliberately cross the 48 KiB frame boundary on each network read.
            const value = bytes.subarray(offset, Math.min(offset + 66665, bytes.byteLength));
            offset += value.byteLength;
            return { done: false, value };
          }, async cancel() {}
        }) }
      };
    }
  });
  const controller = { getUrl: () => location.origin + '/',
    async runJavaScript(script) { return JSON.stringify(vm.runInContext(script, context)); },
    loadUrl() { navigations++; }, deleteJavaScriptRegister() {}
  };
  adapter = new BrowserTransportAdapter(controller);
  window[adapter.bridgeName] = { receive(id, serialized) {
    const value = JSON.parse(serialized);
    frames.push({ id, type: value.type, index: value.index, offset: value.offset,
      encodedLength: value.data?.length, total: value.total, error: value.error });
    adapter.bridge.receive(id, serialized);
  } };
  return { adapter, frames, calls, timers, location,
    navigations: () => navigations,
    expire() { const entry = [...adapter.mediaPending.values()][0]; assert.ok(entry); timers.get(entry.timer)(); },
    advanceRecovery() { adapter.recoveryPause = async () => { now += 250; }; }
  };
}

test('the real page script preserves bytes across network/frame boundaries and omits CDN credentials', async () => {
  for (const [length, host] of [[1, 'linux.do'], [49152, 'linux.do'], [49153, 'cdn3.ldstatic.com'], [131099, 'linux.do']]) {
    const bytes = Uint8Array.from({ length }, (_, i) => i % 251);
    const rt = runtime({ bytes });
    const result = await rt.adapter.requestImage(`https://${host}/fixture.png`, new RequestCancellation());
    assert.deepEqual(new Uint8Array(result.bytes), bytes);
    assert.equal(result.headers['content-type'], 'image/png');
    assert.equal(rt.frames[0].type, 'start');
    assert.equal(rt.frames.at(-1).type, 'done');
    assert.ok(rt.frames.filter(value => value.type === 'chunk').every(value => value.encodedLength <= 65536));
    const options = rt.calls[0].options;
    assert.equal(options.method, 'GET');
    assert.equal(options.credentials, host === 'linux.do' ? 'include' : 'omit');
    assert.equal(options.mode, host === 'linux.do' ? 'same-origin' : 'cors');
    assert.equal(options.redirect, 'error');
    assert.equal(options.referrerPolicy, host === 'linux.do' ? 'same-origin' : 'no-referrer');
    assert.deepEqual(Object.keys(options.headers), ['Accept']);
    assert.equal(rt.adapter.mediaPending.size, 0);
    assert.equal(rt.timers.size, 0);
  }
});

test('20 MiB succeeds exactly while undeclared and declared excess are rejected before caching', async () => {
  const length = policy.MAX_BROWSER_MEDIA_BYTES;
  const bytes = Uint8Array.from({ length }, (_, i) => i % 251);
  const exact = runtime({ bytes });
  assert.deepEqual(new Uint8Array((await exact.adapter.requestImage('/exact.png', new RequestCancellation())).bytes), bytes);
  for (const options of [{ bytes: new Uint8Array(length + 1) }, { declared: length + 1 }]) {
    const rt = runtime(options);
    await assert.rejects(rt.adapter.requestImage('/large.png', new RequestCancellation()), { kind: Kind.InvalidResponse });
    assert.equal(rt.frames.at(-1).error, 'too_large');
    assert.equal(rt.adapter.mediaPending.size, 0);
    assert.equal(rt.timers.size, 0);
  }
});

test('HTML, challenge responses, empty images and HTTP errors never become image bytes', async () => {
  for (const [options, kind] of [[{ mime: 'text/html' }, Kind.InvalidResponse],
    [{ mitigated: 'challenge' }, Kind.VerificationRequired], [{ status: 403 }, Kind.VerificationRequired],
    [{ status: 401 }, Kind.AuthenticationRequired], [{ status: 429 }, Kind.RateLimited],
    [{ status: 302 }, Kind.Rejected], [{ bytes: new Uint8Array() }, Kind.InvalidResponse]]) {
    const rt = runtime(options);
    await assert.rejects(rt.adapter.requestImage('/fixture.png', new RequestCancellation()), { kind });
    assert.equal(rt.adapter.mediaPending.size, 0);
    assert.equal(rt.timers.size, 0);
    assert.equal(rt.frames.some(value => value.type === 'chunk'), false);
  }
});

test('media allowlisting does not expand the ordinary JSON request destination boundary', async () => {
  const rt = runtime();
  for (const url of ['https://other.test/a.png', 'https://linux.do.evil.test/a.png',
    'http://linux.do/a.png', 'https://linux.do:444/a.png', 'https://user:secret@linux.do/a.png',
    'https://linux.do\\@other.test/a.png']) {
    await assert.rejects(rt.adapter.requestImage(url, new RequestCancellation()), { kind: Kind.Rejected });
  }
  for (const path of ['https://cdn3.ldstatic.com/a.json', '//cdn3.ldstatic.com/a.json', '/\\other.test/a']) {
    await assert.rejects(rt.adapter.request({ path, method: 'GET', body: '', csrf: '' }), { kind: Kind.Rejected });
  }
  assert.equal(rt.calls.length, 0);
});

test('API and media nonces cannot accept each other\'s response shape; unknown nonces are ignored', async () => {
  for (const media of [true, false]) {
    const rt = runtime({ hold: true });
    const token = new RequestCancellation();
    const pending = media ? rt.adapter.requestImage('/held.png', token) :
      rt.adapter.request({ path: '/latest.json', method: 'GET', body: '', csrf: '' }, token);
    const rejected = assert.rejects(pending, { kind: Kind.InvalidResponse });
    await tick();
    const entries = media ? rt.adapter.mediaPending : rt.adapter.pending;
    const [id] = entries.keys(); assert.match(id, /^[0-9a-f]{32}$/);
    rt.adapter.bridge.receive('0'.repeat(32), JSON.stringify(start));
    assert.equal(entries.size, 1);
    rt.adapter.bridge.receive(id, JSON.stringify(media ?
      { status: 200, body: '{}', headers: {} } : start));
    await rejected;
    assert.equal(entries.size, 0);
    await tick();
    assert.equal(rt.timers.size, 0);
  }
});

test('invalid, duplicate, out-of-order and truncated frames are rejected without a partial result', () => {
  const chunk = { type: 'chunk', index: 0, offset: 0, data: 'AQ==' };
  for (const values of [[null], [[]], [{}], [chunk], [start, start],
    [start, { ...chunk, index: 1 }], [start, { ...chunk, offset: 1 }],
    [start, { ...chunk, data: '!' }], [start, { ...chunk, data: 'A===' }],
    [start, { ...chunk, data: 'A'.repeat(65540) }], [start, chunk, chunk],
    [start, chunk, { type: 'done', total: 2 }], [start, { type: 'done', total: 0 }]]) {
    const transfer = new BrowserMediaTransfer();
    assert.throws(() => values.forEach(value => frame(transfer, value)), { kind: Kind.InvalidResponse });
  }
  const transfer = new BrowserMediaTransfer();
  assert.equal(frame(transfer, start), undefined);
  assert.equal(frame(transfer, chunk), undefined, 'A chunk alone is never a completed response.');
  transfer.dispose();
  assert.throws(() => frame(transfer, { type: 'done', total: 1 }), { kind: Kind.InvalidResponse });
});

test('cancellation, navigation, disposal and timeout discard in-flight media and ignore late frames', async () => {
  for (const action of ['cancel', 'navigate', 'dispose', 'timeout']) {
    const rt = runtime({ hold: true });
    const token = new RequestCancellation();
    const pending = rt.adapter.requestImage('/held.png', token);
    const rejected = assert.rejects(pending, { kind: action === 'timeout' ? Kind.Timeout : Kind.Cancelled });
    await tick();
    const [id] = rt.adapter.mediaPending.keys();
    if (action === 'cancel') token.cancel();
    else if (action === 'navigate') rt.adapter.pageStarted();
    else if (action === 'dispose') rt.adapter.dispose();
    else rt.expire();
    await rejected;
    rt.adapter.bridge.receive(id, JSON.stringify(start));
    rt.adapter.bridge.receive(id, JSON.stringify({ type: 'done', total: 1 }));
    await tick();
    assert.equal(rt.adapter.mediaPending.size, 0);
    assert.equal(token.handlers.size, 0);
    assert.equal(rt.timers.size, 0);
  }
});

test('owner reset cancels the actual ForumApi media registration and its pending decoder', async () => {
  const rt = runtime({ hold: true });
  const api = new ForumApi(), token = new RequestCancellation();
  api.registerBrowserMediaTransport((url, cancellation) => rt.adapter.requestImage(url, cancellation));
  api.setBrowserTransportEnabled(true);
  const pending = api.requestBrowserMedia('/held.png', token);
  const rejected = assert.rejects(pending, { kind: Kind.Cancelled });
  await tick();
  const before = api.getSessionGeneration();
  api.resetSessionContext();
  await rejected; await tick();
  assert.equal(api.getSessionGeneration(), before + 1);
  assert.equal(token.isCancelled, true);
  assert.equal(api.activeRequests.size, 0);
  assert.equal(rt.adapter.mediaPending.size, 0);
  assert.equal(rt.timers.size, 0);
});

test('recovery refuses to navigate while image reads are still active', async () => {
  const rt = runtime({ hold: true });
  const token = new RequestCancellation();
  const pending = rt.adapter.requestImage('/held.png', token);
  const rejected = assert.rejects(pending, { kind: Kind.Cancelled });
  await tick(); rt.advanceRecovery();
  assert.equal(await rt.adapter.recoverSession(new RequestCancellation()), false);
  assert.equal(rt.navigations(), 0);
  assert.equal(rt.adapter.mediaPending.size, 1);
  token.cancel(); await rejected; await tick();
  assert.equal(rt.timers.size, 0);
});
