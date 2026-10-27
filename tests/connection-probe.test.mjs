import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(value => value && existsSync(value));
assert.ok(compiler);
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
function load(value, bindings = {}) {
  const production = ts.transpileModule(value.replace(/^import [\s\S]*? from [^;]+;\n/gm, '')
    .replace(/@(Local|Param) /g, ''), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), production)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
class RequestCancellation {
  isCancelled = false;
  handlers = new Set();
  onCancel(fn) { if (this.isCancelled) fn(); else this.handlers.add(fn); }
  offCancel(fn) { this.handlers.delete(fn); }
  cancel() { this.isCancelled = true; for (const fn of this.handlers) fn(); }
}
const trace = 'h=linux.do\nip=192.0.2.10\ntls=TLSv1.3\nsni=encrypted\n';
function probeRuntime(respond = async () => ({ responseCode: 200, result: trace })) {
  const calls = [];
  let destroyed = 0;
  const exports = load(source('services/ConnectionProbe'), { RequestCancellation, http: {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' },
    createHttp: () => ({ request: (url, options) => { calls.push({ url, options }); return respond(); },
      destroy() { destroyed++; } })
  } });
  return { ...exports, calls, destroyed: () => destroyed };
}

test('only validated server handshake fields appear in summaries, never trace addresses or HTML', () => {
  const rt = probeRuntime();
  assert.equal(rt.connectionTraceSummary(trace), 'TLSv1.3 · 服务端确认域名已加密');
  assert.equal(rt.browserTraceSummary(JSON.stringify(trace)), rt.connectionTraceSummary(trace));
  assert.match(rt.connectionTraceSummary(trace.replace('encrypted', 'plaintext')), /未加密目标域名/);
  for (const invalid of ['<html>Just a moment</html>', trace.replace('linux.do', 'evil.test'),
    trace.replace('TLSv1.3', 'private-data'), trace.replace('sni=encrypted', 'sni=untrusted')]) {
    assert.match(rt.connectionTraceSummary(invalid), /未取得有效握手回执/);
  }
  assert.equal(rt.connectionTraceSummary(trace).includes('192.0.2.10'), false);
  // Hidden Web components may have no rendered innerText while the trace DOM is valid.
  const page = { location: { origin: 'https://linux.do' }, document: { body: { innerText: '', textContent: trace } } };
  const filtered = new Function('location', 'document', `return ${rt.connectionTraceScript()}`)(page.location, page.document);
  assert.equal(filtered.includes('ip='), false);
  assert.equal(filtered, 'h=linux.do\ntls=TLSv1.3\nsni=encrypted');
  const control = trace.replace('h=linux.do', 'h=crypto.cloudflare.com');
  assert.match(rt.connectionTraceSummary(control), /未取得/);
  assert.match(rt.connectionTraceSummary(control, true), /域名已加密/);
});

test('native probes use per-request DoH without cookies, auth headers, redirects or forum writes', async () => {
  for (const doh of [false, true]) {
    const rt = probeRuntime();
    const token = new RequestCancellation();
    assert.match(await rt.probeNativeConnection(doh, token), /域名已加密/);
    const { url, options } = rt.calls[0];
    assert.equal(url, 'https://linux.do/cdn-cgi/trace');
    assert.deepEqual(options.header, { Accept: 'text/plain' });
    assert.equal(options.method, 'GET');
    assert.equal(options.maxRedirects, 0);
    assert.equal(options.dnsOverHttps, doh ? rt.CONNECTION_PROBE_DOH : undefined);
    assert.equal(token.handlers.size, 0);
    assert.equal(rt.destroyed(), 1);
  }
});

test('cancelled and blocked probes do not claim encrypted connectivity', async () => {
  const rt = probeRuntime(() => new Promise(() => {}));
  const token = new RequestCancellation();
  const pending = rt.probeNativeConnection(true, token);
  token.cancel();
  assert.equal(await pending, '检测已取消');
  assert.equal(token.handlers.size, 0);
  const blocked = probeRuntime(async () => ({ responseCode: 403, result: trace }));
  assert.equal(await blocked.probeNativeConnection(true, new RequestCancellation()), 'HTTP 403 · 未取得有效握手回执');
  const failed = probeRuntime(async () => { throw { code: 2300035, message: 'private URL or certificate detail' }; });
  assert.equal(await failed.probeNativeConnection(true, new RequestCancellation()), '连接未完成（错误码 2300035）');
});

test('leaving diagnostics cancels pending work, removes its private Web and resets DNS', async () => {
  const pageSource = source('pages/ConnectionProbePage');
  const start = pageSource.indexOf('export struct ConnectionProbePage');
  const end = pageSource.indexOf('  build()', start);
  const dns = [];
  const pageClass = pageSource.slice(start, end).replace('export struct', 'export class') + '\n}';
  const { ConnectionProbePage } = load(pageClass, {
    CONNECTION_PROBE_DOH: 'https://dns.alidns.com/dns-query',
    webview: { WebviewController: class { static setHttpDns(...args) { dns.push(args); } }, SecureDnsMode: { OFF: 0 } }
  });
  const page = new ConnectionProbePage();
  const token = new RequestCancellation();
  page.cancellation = token;
  page.webEnabled = true; page.busy = true;
  page.stop();
  assert.equal(token.isCancelled, true);
  assert.equal(page.webEnabled, false);
  assert.equal(page.busy, false);
  assert.deepEqual(dns, [[0, 'https://dns.alidns.com/dns-query']]);
  assert.match(pageSource, /incognitoMode: true/);
});
