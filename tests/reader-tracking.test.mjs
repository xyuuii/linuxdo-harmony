import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler);
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const tracker = load(source('services/TopicReadTracker'));
const scroll = load(source('services/TopicScrollPolicy'));
const topic = source('pages/TopicPage');
const declarations = topic.slice(topic.indexOf('export interface TopicTreeRow'), topic.indexOf('@ComponentV2'));
const prefix = topic.slice(topic.indexOf('export struct TopicPage'), topic.indexOf('  @Builder\n', topic.indexOf('export struct TopicPage')));
const hide = /\.onHidden\(\(\) => \{([\s\S]*?)\}\)/.exec(topic);
assert.ok(hide);
const production = (declarations + '\n' + prefix + `\nhideFromNavigation():void {${hide[1]}}\n}`)
  .replace('export struct TopicPage', 'export class TopicPage')
  .replace(/^\s*@(?:ObservedV2|Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local|Trace) /g, '');

function runtime(respond = async () => {}) {
  let now = 0;
  let sessionGeneration = 2;
  const timers = new Map();
  let nextTimer = 0;
  const writes = [];
  const session = { user: { id: 7 }, revision: 1 };
  const exports = load(production, {
    ...tracker, ...scroll, forumSession: session, loadAppearanceSettings: () => ({ reduceMotion: true }),
    Scroller: class {},
    Date: class extends Date { static now() { return now; } },
    RequestCancellation: class { isCancelled = false; cancel() { this.isCancelled = true; } },
    forumApi: { getSessionGeneration: () => sessionGeneration,
      async recordTopicReadTimings(batch, token) { writes.push({ batch, token }); return respond(batch, token); } },
    setInterval(callback) { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearInterval(id) { timers.delete(id); }, clearTimeout() {},
    setTimeout() { throw new Error('No native I/O or layout timing is needed in this integration fixture.'); }
  });
  const page = new exports.TopicPage();
  Object.assign(page, { topicId: 42, topicOwnerId: 7, entered: true, hidden: false,
    topic: { id: 42, postStream: { posts: [], stream: [] } }, foreground: true, readerCovered: false });
  page.aboutToAppear(); page.startReadingTimer();
  return { page, session, timers, writes,
    setGeneration(value) { sessionGeneration = value; },
    async advance(milliseconds) {
      for (let elapsed = 0; elapsed < milliseconds; elapsed += 1000) {
        now += Math.min(1000, milliseconds - elapsed);
        for (const callback of [...timers.values()]) { callback(); }
        await Promise.resolve(); await Promise.resolve();
      }
    }
  };
}

test('loaded floors and current progress never substitute for a native visible-floor observation', async () => {
  const rt = runtime();
  rt.page.posts = [{ id: 71, postNumber: 1 }, { id: 72, postNumber: 7 }, { id: 73, postNumber: 20 }];
  rt.page.currentNumber = 20;
  await rt.advance(15000);
  assert.equal(rt.writes.length, 0);
  rt.page.postVisibilityChanged(7, true);
  await rt.advance(15000);
  await rt.page.flushReadingTimings(true);
  assert.ok(rt.writes.length > 0);
  assert.ok(rt.writes.every(write => write.batch.postTimings.length === 1 && write.batch.postTimings[0].postNumber === 7));
  assert.equal(rt.writes.reduce((sum, write) => sum + write.batch.topicTimeMs, 0), 15000);
});

test('all reader overlays pause timing and hold pending intervals until the real viewport returns', async () => {
  for (const state of ['readerCovered', 'showPicture', 'showJump', 'showTopicOptions', 'showFlag', 'showHistory', 'sharingPanelOpen']) {
    const rt = runtime(); rt.page.postVisibilityChanged(7, true);
    await rt.advance(5000);
    rt.page[state] = true; rt.page.readingVisibilityChanged();
    await rt.advance(20000);
    assert.equal(rt.writes.length, 0, state);
    rt.page[state] = false; rt.page.readingVisibilityChanged();
    await rt.advance(1000);
    assert.equal(rt.writes.length, 1, state);
    assert.equal(rt.writes[0].batch.postTimings[0].milliseconds, 6000, state);
  }
});

test('background stops the timer and cancels pending writes without counting the elapsed background gap', async () => {
  let release;
  let first = true;
  const rt = runtime(() => {
    if (first) { first = false; return new Promise(resolve => { release = resolve; }); }
    return Promise.resolve();
  });
  rt.page.postVisibilityChanged(7, true); await rt.advance(15000);
  assert.equal(rt.writes.length, 1);
  rt.page.foreground = false; rt.page.readingVisibilityChanged();
  assert.equal(rt.writes[0].token.isCancelled, true); assert.equal(rt.timers.size, 0);
  await rt.advance(60000); release(); await Promise.resolve();
  rt.page.foreground = true; rt.page.readingVisibilityChanged();
  await rt.advance(15000);
  await rt.page.flushReadingTimings(true);
  assert.equal(rt.writes.slice(1).reduce((sum, write) => sum + write.batch.topicTimeMs, 0), 15000,
    'The 60-second background gap is not reading evidence.');
});

test('identity changes discard former floors and pending time before accepting new viewport callbacks', async () => {
  const rt = runtime(); rt.page.postVisibilityChanged(7, true); await rt.advance(10000);
  rt.session.user = { id: 8 }; rt.setGeneration(3); rt.page.syncReadingContext();
  rt.page.topicOwnerId = 8;
  await rt.advance(15000);
  assert.equal(rt.writes.length, 0);
  rt.page.postVisibilityChanged(9, true); await rt.advance(15000);
  await rt.page.flushReadingTimings(true);
  assert.ok(rt.writes.every(write => write.batch.ownerId === 8 && write.batch.sessionGeneration === 3));
  assert.ok(rt.writes.every(write => write.batch.postTimings.length === 1 && write.batch.postTimings[0].postNumber === 9));
  assert.equal(rt.writes.reduce((sum, write) => sum + write.batch.topicTimeMs, 0), 15000);
});

test('leaving flushes only the observed closing interval and stops further collection', async () => {
  const rt = runtime(); rt.page.postVisibilityChanged(7, true); await rt.advance(10000);
  rt.page.hideFromNavigation(); await Promise.resolve(); await Promise.resolve();
  assert.equal(rt.writes.length, 1); assert.equal(rt.writes[0].batch.topicTimeMs, 10000);
  assert.equal(rt.timers.size, 0);
  await rt.advance(60000);
  assert.equal(rt.writes.length, 1);
});

test('a failed consumed timing batch is never retried and later genuine time forms a separate batch', async () => {
  const rt = runtime(async () => { throw new Error('fixture unknown write result'); });
  rt.page.postVisibilityChanged(7, true); await rt.advance(30000);
  assert.equal(rt.writes.length, 2);
  assert.ok(rt.writes.every(write => write.batch.topicTimeMs === 15000));
  assert.notStrictEqual(rt.writes[0].batch, rt.writes[1].batch);
});
