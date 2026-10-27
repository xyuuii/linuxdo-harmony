import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// Exercise the actual catalog implementation with fixture JSON, never native I/O.
const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required.');
const ts = require(compiler);
const source = readFileSync(new URL('../app/entry/src/main/ets/services/ForumApi.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source.replace(/^import [\s\S]*?;\r?\n/gm, ''), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const module = { exports: {} };
new Function('module', 'exports', 'urlUtils', 'decodeObject', 'decodeArray', 'text', 'list', compiled)
  (module, module.exports, { URL }, JSON.parse, JSON.parse,
    value => typeof value === 'string' ? value : '', value => Array.isArray(value) ? value : []);
const { ForumApi, ForumErrorKind, RequestCancellation, emojiImageUrl } = module.exports;
const catalog = JSON.stringify({ default: [
  { name: 'hugs', url: '/images/emoji/twemoji/hugs.png?v=15' },
  { name: 'bili_057', url: 'https://emoji.example.test/custom/bili_057.gif' },
  { name: 'bad', url: 'https://user:secret@example.test/a.png' }
] });

test('the reaction catalog keeps standard and custom CDN images without admitting unsafe sources', () => {
  assert.equal(emojiImageUrl('/images/emoji/twemoji/hugs.png?v=15'),
    'https://linux.do/images/emoji/twemoji/hugs.png?v=15');
  assert.equal(emojiImageUrl('//emoji.example.test/bili.gif#preview'), 'https://emoji.example.test/bili.gif');
  for (const value of ['http://emoji.example.test/a.png', 'file:///tmp/a', 'data:image/png;base64,AAA',
    'javascript:evil', 'https://u:p@emoji.example.test/a', 'https://emoji.example.test:8443/a',
    'https://emoji.example.test/a\nb', 'https://emoji.example.test\\a']) {
    assert.equal(emojiImageUrl(value), '', value);
  }
});

test('concurrent reaction readers share the catalog, receive separate maps and reuse the result', async () => {
  const api = new ForumApi();
  let count = 0;
  let finish;
  api.get = async path => { assert.equal(path, '/emojis.json'); count++; return new Promise(resolve => { finish = resolve; }); };
  const first = api.emojiUrls();
  const second = api.emojiUrls();
  assert.equal(count, 1);
  finish(catalog);
  const [a, b] = await Promise.all([first, second]);
  assert.equal(a.get('hugs'), 'https://linux.do/images/emoji/twemoji/hugs.png?v=15');
  assert.equal(b.get('bili_057'), 'https://emoji.example.test/custom/bili_057.gif');
  assert.equal(a.has('bad'), false);
  a.clear();
  assert.equal(b.size, 2);
  assert.equal((await api.emojiUrls()).size, 2);
  assert.equal(count, 1);
});

test('a failed directory read can recover and reset discards the old account catalog', async () => {
  const api = new ForumApi();
  let calls = 0;
  api.get = async () => { if (++calls === 1) { throw new Error('fixture offline'); } return catalog; };
  await assert.rejects(api.emojiUrls(), /fixture offline/);
  assert.equal((await api.emojiUrls()).size, 2);
  api.resetSessionContext();
  assert.equal((await api.emojiUrls()).size, 2);
  assert.equal(calls, 3);
});

test('an obsolete catalog response cannot fill the new account cache or reach another consumer', async () => {
  const api = new ForumApi();
  let finish;
  api.get = async () => new Promise(resolve => { finish = resolve; });
  const a = api.emojiUrls();
  const b = api.emojiUrls();
  api.resetSessionContext();
  const rejected = Promise.all([
    assert.rejects(a, error => error.kind === ForumErrorKind.Cancelled),
    assert.rejects(b, error => error.kind === ForumErrorKind.Cancelled)
  ]);
  finish(catalog);
  await rejected;
  api.get = async () => JSON.stringify([{ name: 'new', url: '/images/new.png' }]);
  assert.deepEqual([...await api.emojiUrls()], [['new', 'https://linux.do/images/new.png']]);
});

test('a cancelled consumer cannot cancel another reader or return a cached catalog', async () => {
  const api = new ForumApi();
  const token = new RequestCancellation();
  const finishes = [];
  api.get = async (_path, cancellation) => new Promise(resolve => { finishes.push({ resolve, cancellation }); });
  const isolated = api.emojiUrls(token);
  const shared = api.emojiUrls();
  token.cancel();
  const rejected = assert.rejects(isolated, error => error.kind === ForumErrorKind.Cancelled);
  finishes.forEach(item => item.resolve(catalog));
  await rejected;
  assert.equal((await shared).size, 2);
  await assert.rejects(api.emojiUrls(token), error => error.kind === ForumErrorKind.Cancelled);
  assert.equal(finishes[1].cancellation, undefined);
});
