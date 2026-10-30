import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(value => value && existsSync(value));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
function load(value, modules = {}, globals = {}) {
  const compiled = ts.transpileModule(value, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  const allowedRequire = name => { assert.ok(Object.hasOwn(modules, name), `Unexpected native/module access: ${name}`); return modules[name]; };
  new Function('module', 'exports', 'require', ...Object.keys(globals), compiled.outputText)
    (module, module.exports, allowedRequire, ...Object.values(globals));
  return module.exports;
}
const forbidden = () => { throw new Error('Native network, storage, publication and uploads are forbidden in this fixture.'); };
const apiExports = load(source('services/ForumApi'), {
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' }, createHttp: forbidden } },
  '@kit.ArkWeb': { webview: {} }, '@kit.ArkTS': { url: { URL } }, '@kit.BasicServicesKit': {},
  '../models/ForumModels': {}, './ForumWire': {}, '../models/UserProfileModels': {}, './UserProfileWire': {},
  '../models/DirectoryModels': {}, './DirectoryWire': {}, './PostRevisionWire': {}
});
const { ForumApi, RequestCancellation, ForumErrorKind: Kind } = apiExports;
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(finish => { resolve = finish; }); return { promise, resolve }; };

function browserRuntime({ cooked = '<h2>Heading</h2><blockquote><p>Quote</p></blockquote>', gate, missing = '',
  child = false, origin = 'https://linux.do', fetch = forbidden } = {}) {
  const timers = new Map(); const calls = []; const frames = []; let timerId = 0;
  const clock = { setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); } };
  const { BrowserTransportAdapter } = load(source('services/BrowserTransportAdapter'), {
    './ForumApi': apiExports, '@kit.ArkWeb': { webview: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ async generateRandom(size) { return { data: randomBytes(size) }; } }) } },
    './BrowserMediaTransfer': { BrowserMediaTransfer: class { constructor() { forbidden(); } } }, './BrowserMediaPolicy': {}
  }, { ...clock, canIUse: () => true });
  const page = { top: null }; page.top = child ? {} : page;
  const module = missing === 'export' ? {} : { async generateCookFunction(options) {
    calls.push({ operation: 'factory', options: JSON.parse(JSON.stringify(options)) });
    if (gate) { await gate.promise; }
    return raw => { calls.push({ operation: 'cook', raw }); return cooked; };
  } };
  if (missing !== 'loader') {
    page.require = name => { assert.equal(name, 'discourse/lib/text'); return module; };
    page.require.has = name => { assert.equal(name, 'discourse/lib/text'); return missing !== 'module'; };
  }
  const sandbox = vm.createContext({ window: page, location: { origin }, Map, ...clock, fetch,
    URL, AbortController, TextDecoder, setImmediate });
  const controller = { url: 'https://linux.do/', getUrl() { return this.url; },
    runJavaScript(script) { return Promise.resolve(vm.runInContext(script, sandbox)); }, deleteJavaScriptRegister() {} };
  const adapter = new BrowserTransportAdapter(controller);
  page.LinuxDoNativeResponse = { receive(id, serialized) { frames.push({ id, serialized }); adapter.bridge.receive(id, serialized); } };
  return { adapter, controller, page, sandbox, calls, frames, timers };
}

test('preview executes only the documented official cooker and passes user text as data with no fetch', async () => {
  const state = browserRuntime();
  const raw = '[quote="author, post:2, topic:42"]\n**Title**\n[/quote]\n"; window.pwned=true; // ` ${danger} \u2028';
  const output = await state.adapter.cookPreview(raw, new RequestCancellation());
  assert.equal(output, '<h2>Heading</h2><blockquote><p>Quote</p></blockquote>');
  assert.deepEqual(state.calls, [{ operation: 'factory', options: { previewing: true } }, { operation: 'cook', raw }]);
  assert.equal(state.page.pwned, undefined); assert.equal(state.frames.length, 1);
  assert.equal(state.adapter.cookPending.size, 0); assert.equal(state.timers.size, 0);
});

test('unavailable loader, module or stable export fails clearly without guessing private page objects', async () => {
  for (const missing of ['loader', 'module', 'export']) {
    const state = browserRuntime({ missing });
    await assert.rejects(() => state.adapter.cookPreview('raw', new RequestCancellation()), error => error.kind === Kind.Unsupported);
    assert.deepEqual(state.calls, []); assert.equal(state.adapter.cookPending.size, 0);
  }
});

test('both native URL and script origin/top-frame checks gate preview execution', async () => {
  for (const scenario of ['native-origin', 'script-origin', 'child-frame']) {
    const state = browserRuntime({ origin: scenario === 'script-origin' ? 'https://evil.example' : 'https://linux.do', child: scenario === 'child-frame' });
    if (scenario === 'native-origin') { state.controller.url = 'https://linux.do.evil.example/'; }
    await assert.rejects(() => state.adapter.cookPreview('private draft', new RequestCancellation()), error => error.kind === Kind.VerificationRequired);
    assert.deepEqual(state.calls, []);
  }
});

test('raw and cooked size limits reject instead of silently truncating preview content', async () => {
  const state = browserRuntime({ cooked: 'x'.repeat(262145) });
  await assert.rejects(() => state.adapter.cookPreview('x'.repeat(65537), new RequestCancellation()), error => error.kind === Kind.Rejected);
  assert.deepEqual(state.calls, []);
  await assert.rejects(() => state.adapter.cookPreview('raw', new RequestCancellation()), error => error.kind === Kind.InvalidResponse);
  assert.equal(state.adapter.cookPending.size, 0);
});

test('cancel, document navigation and disposal discard late cooking results and release pending state', async () => {
  for (const action of ['cancel', 'page-start', 'page-commit', 'dispose']) {
    const gate = deferred(); const state = browserRuntime({ gate }); const token = new RequestCancellation();
    const promise = state.adapter.cookPreview('private raw', token); await tick();
    const rejection = assert.rejects(promise, error => error.kind === Kind.Cancelled);
    if (action === 'cancel') { token.cancel(); }
    if (action === 'page-start') { state.adapter.pageStarted(); }
    if (action === 'page-commit') { state.adapter.pageCommitted(); }
    if (action === 'dispose') { state.adapter.dispose(); }
    await rejection; gate.resolve(); await tick();
    assert.equal(state.adapter.cookPending.size, 0); assert.equal(state.frames.length, 0);
    assert.ok(!state.calls.some(call => call.operation === 'cook'), 'Cancelled work must not cook or publish the raw text.');
  }
});

test('timeout and cross-protocol result shapes fail closed; unknown nonces cannot complete a preview', async () => {
  for (const response of ['timeout', 'api-frame', 'media-frame']) {
    const gate = deferred(); const state = browserRuntime({ gate });
    const promise = state.adapter.cookPreview('private raw', new RequestCancellation()); await tick();
    const id = [...state.adapter.cookPending.keys()][0];
    state.adapter.bridge.receive('0'.repeat(32), JSON.stringify({ type: 'cook', cooked: 'wrong nonce' }));
    assert.equal(state.adapter.cookPending.size, 1);
    const expected = response === 'timeout' ? Kind.Timeout : Kind.InvalidResponse;
    const rejected = assert.rejects(promise, error => error.kind === expected);
    if (response === 'timeout') { [...state.timers.values()].find(timer => timer.delay === 15000).fn(); }
    else { state.adapter.bridge.receive(id, JSON.stringify(response === 'api-frame' ? { status: 200, body: 'api', headers: {} } : { type: 'start', status: 200 })); }
    await rejected; gate.resolve(); await tick(); assert.equal(state.adapter.cookPending.size, 0);
  }
});

test('ForumApi preview registration alone cannot enable the transport, and preview performs no HTTP operations', async () => {
  const api = new ForumApi(); const token = new RequestCancellation(); let calls = 0;
  api.registerBrowserCookTransport(async raw => { calls++; assert.equal(raw, 'draft'); return '<p>draft</p>'; });
  await assert.rejects(() => api.previewDraft('draft', token), error => error.kind === Kind.VerificationRequired);
  assert.equal(calls, 0);
  api.setBrowserTransportEnabled(true);
  assert.equal(await api.previewDraft('draft', token), '<p>draft</p>'); assert.equal(calls, 1);
  assert.equal(api.activeRequests.size, 0); assert.equal(api.previewRequests.size, 0);
});

test('ForumApi preview results cannot survive an account generation reset or background transition', async () => {
  for (const action of ['account', 'background']) {
    const api = new ForumApi(); const gate = deferred(); const token = new RequestCancellation();
    api.setBrowserTransportEnabled(true); api.registerBrowserCookTransport(async () => gate.promise);
    const pending = api.previewDraft('private draft', token);
    if (action === 'account') { api.resetSessionContext(); } else { api.setForeground(false); }
    assert.equal(token.isCancelled, true);
    gate.resolve('<p>old private preview</p>');
    await assert.rejects(pending, error => error.kind === Kind.Cancelled);
    assert.equal(api.activeRequests.size, 0); assert.equal(api.previewRequests.size, 0);
  }
});

const composerSource = source('pages/ComposerPage');
const classStart = composerSource.indexOf('interface DraftAttachment'); const classEnd = composerSource.indexOf('  @Builder\n', classStart);
const plainComposer = (composerSource.slice(classStart, classEnd) + '\n}\n')
  .replace(/^@ComponentV2\s*$/gm, '').replace('export struct ComposerPage', 'export class ComposerPage')
  .replace(/^\s*@Computed\s*\n/gm, '\n').replace(/^\s*@Monitor\([\s\S]*?\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
function composerRuntime() {
  const repository = load(source('services/DraftRepository').replace(/^import .*;\n/gm, ''));
  const calls = []; const session = { user: { id: 7 }, revision: 1, foreground: true };
  const { ComposerPage } = load(plainComposer, {}, { ...repository, forumSession: session, loadAppearanceSettings: () => ({}),
    RequestCancellation, setTimeout: () => 1, clearTimeout() {},
    forumApi: { previewDraft: (raw, token) => new Promise((resolve, reject) => calls.push({ raw, token, resolve, reject })),
      uploadFile: forbidden, createPost: forbidden, createTopic: forbidden, updatePost: forbidden }
  });
  const page = new ComposerPage(); Object.assign(page, { ownerId: 7, topicId: 42, draftLoaded: true,
    draftKey: 'draft_7_42_0_0', presentationActive: true, permitted: true, draft: 'existing account draft' });
  return { page, calls, session };
}

test('Composer preview is explicitly requested, keeps the complete draft and never uploads selected attachments', async () => {
  const state = composerRuntime(); state.page.attachments = [{ id: 'a', name: 'local.png', uri: 'local-only', size: 3, mime: 'image/png' }];
  assert.equal(state.calls.length, 0); const pending = state.page.showPreview();
  assert.equal(state.page.previewBusy, true); assert.equal(state.calls[0].raw, 'existing account draft');
  state.calls[0].resolve('<h2>Preview</h2>'); await pending;
  assert.equal(state.page.previewCooked, '<h2>Preview</h2>'); assert.equal(state.page.previewBusy, false);
  assert.equal(state.page.draft, 'existing account draft'); assert.equal(state.page.attachments.length, 1);
  state.page.cancelPreview(true); assert.equal(state.page.previewing, false); assert.equal(state.page.draft, 'existing account draft');
});

test('Composer editing, hiding, backgrounding or changing account cancels preview and ignores late HTML', async () => {
  for (const action of ['edit', 'change-text', 'hide', 'background', 'account']) {
    const state = composerRuntime(); const pending = state.page.showPreview();
    if (action === 'edit') { state.page.cancelPreview(true); }
    if (action === 'change-text') { state.page.changeDraft('newer draft'); }
    if (action === 'hide') { state.page.presentationHidden(); }
    if (action === 'background') { state.session.foreground = false; state.page.previewForegroundChanged(); }
    if (action === 'account') { state.session.user = { id: 8 }; state.session.revision++; state.page.accountChanged(); }
    assert.equal(state.calls[0].token.isCancelled, true);
    state.calls[0].resolve('<p>late old-account HTML</p>'); await pending;
    assert.equal(state.page.previewCooked, ''); assert.equal(state.page.previewing, false); assert.equal(state.page.previewBusy, false);
    if (action !== 'account') { assert.equal(state.page.draft, action === 'change-text' ? 'newer draft' : 'existing account draft'); }
    else { assert.equal(state.page.draft, ''); }
  }
});

test('Composer preview failure preserves draft and offers another explicit attempt; empty drafts never invoke cooking', async () => {
  const state = composerRuntime(); const first = state.page.showPreview(); state.calls[0].reject(new Error('fixture unavailable')); await first;
  assert.equal(state.page.previewError, 'fixture unavailable'); assert.equal(state.page.previewing, true);
  assert.equal(state.page.draft, 'existing account draft');
  const second = state.page.showPreview(); assert.equal(state.page.previewError, ''); state.calls[1].resolve('<p>ready</p>'); await second;
  assert.equal(state.page.previewCooked, '<p>ready</p>');
  const empty = composerRuntime(); empty.page.draft = '  '; await empty.page.showPreview();
  assert.equal(empty.calls.length, 0); assert.equal(empty.page.draft, '  ');
});
