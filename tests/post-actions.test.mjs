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
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');

function compile(value, bindings) {
  const result = ts.transpileModule(value, {
    fileName: 'post-actions-production.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), result.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

function sharingRuntime({ supported = true, copyError, showError } = {}) {
  const copied = [];
  const shared = [];
  const modules = {
    '@kit.BasicServicesKit': { pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain',
      createData(mimeType, value) { return { mimeType, value }; },
      getSystemPasteboard() { return { async setData(data) { if (copyError) { throw copyError; } copied.push(data); } }; }
    } },
    '@kit.ArkData': { uniformTypeDescriptor: { UniformDataType: { HYPERLINK: 'general.hyperlink' } } },
    '@kit.ShareKit': { systemShare: {
      SharedData: class { constructor(record) { this.record = record; } },
      ShareController: class {
        constructor(data) { this.data = data; }
        on(event, callback) { assert.equal(event, 'dismiss'); this.dismiss = callback; }
        off(event, callback) { assert.equal(event, 'dismiss'); assert.strictEqual(callback, this.dismiss); this.dismiss = undefined; }
        async show(context, options) { if (showError) { throw showError; } shared.push({ data: this.data, context, options, controller: this }); }
      },
      SelectionMode: { SINGLE: 0 }, SharePreviewMode: { DEFAULT: 0 }
    } }
  };
  const exports = compile(source('services/PostSharing'), {
    require: name => { assert.ok(Object.hasOwn(modules, name), `Unexpected I/O: ${name}`); return modules[name]; },
    canIUse: capability => { assert.equal(capability, 'SystemCapability.Collaboration.SystemShare'); return supported; }
  });
  return { ...exports, copied, shared };
}

test('copy and system share use a canonical HTTPS floor link without account or session parameters', async () => {
  const rt = sharingRuntime();
  assert.equal(rt.canonicalPostUrl(42, 7), 'https://linux.do/t/42/7');
  await rt.copyPostLink(42, 7);
  assert.deepEqual(rt.copied, [{ mimeType: 'text/plain', value: 'https://linux.do/t/42/7' }]);
  const context = { id: 'fixture-ability' };
  await rt.sharePostLink(context, 42, 7, '  Fixture topic  ', 'post_more_71');
  assert.equal(rt.shared.length, 1);
  assert.deepEqual(rt.shared[0].data.record, { utd: 'general.hyperlink', content: 'https://linux.do/t/42/7',
    title: 'Fixture topic', description: 'LINUX DO · 第 7 楼' });
  assert.strictEqual(rt.shared[0].context, context);
  assert.deepEqual(rt.shared[0].options, { anchor: 'post_more_71', selectionMode: 0, previewMode: 0 });
});

test('invalid floor IDs cannot reach the clipboard or system sharing boundary', async () => {
  const rt = sharingRuntime();
  for (const value of [0, -1, NaN, Infinity, 1.2, '42', Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => rt.canonicalPostUrl(value, 7));
    await assert.rejects(() => rt.copyPostLink(42, value));
    await assert.rejects(() => rt.sharePostLink({}, value, 7, 'Fixture', 'post_more_71'));
  }
  assert.equal(rt.copied.length, 0); assert.equal(rt.shared.length, 0);
});

test('clipboard failure, unsupported sharing and native panel failure are returned without fabricating completion', async () => {
  const copyError = new Error('fixture clipboard denied');
  await assert.rejects(() => sharingRuntime({ copyError }).copyPostLink(42, 7), error => error === copyError);
  const unsupported = sharingRuntime({ supported: false });
  await assert.rejects(() => unsupported.sharePostLink({}, 42, 7, 'Fixture', 'post_more_71'), /复制楼层链接/);
  assert.equal(unsupported.shared.length, 0);
  const showError = new Error('fixture panel unavailable');
  await assert.rejects(() => sharingRuntime({ showError }).sharePostLink({}, 42, 7, 'Fixture', 'post_more_71'),
    /fixture panel unavailable/);
});

test('the native dismiss event releases the share listener and restores the covered-reader lifecycle once', async () => {
  const rt = sharingRuntime();
  let dismisses = 0;
  await rt.sharePostLink({}, 42, 7, 'Fixture', 'post_more_71', () => { dismisses++; });
  assert.equal(dismisses, 0, 'Opening the panel does not mean it has closed.');
  const controller = rt.shared[0].controller;
  controller.dismiss();
  assert.equal(dismisses, 1); assert.equal(controller.dismiss, undefined);
});

const pageSource = source('pages/TopicPage');
const helpersStart = pageSource.indexOf('function postWithBoosts(');
const helpersEnd = pageSource.indexOf('interface TopicLink', helpersStart);
const actionsStart = pageSource.indexOf('  private async quotePost(');
const actionsEnd = pageSource.indexOf('  private async react(', actionsStart);
const mergeStart = pageSource.indexOf('  private mergePosts(');
const mergeEnd = pageSource.indexOf('  private reveal(', mergeStart);
assert.ok(helpersStart >= 0 && helpersEnd > helpersStart && actionsStart >= 0 && actionsEnd > actionsStart && mergeEnd > mergeStart);

class ForumApiError extends Error { constructor(kind, message) { super(message); this.kind = kind; } }
function readerActions({ create = async () => 81, remove = async () => {}, copy = async () => {}, share = async () => {},
  readRaw = async () => 'Fixture raw' } = {}) {
  const calls = [];
  const messages = [];
  const merged = [];
  const token = { isCancelled: false };
  const quotes = [];
  const exports = compile(pageSource.slice(helpersStart, helpersEnd) + '\nexport class PostActionsHarness {\n' +
    pageSource.slice(actionsStart, actionsEnd) + pageSource.slice(mergeStart, mergeEnd) + '\n}', {
    forumApi: {
      async createPostBookmark(...args) { calls.push(['create', ...args]); return create(...args); },
      async deleteBookmark(...args) { calls.push(['delete', ...args]); return remove(...args); },
      async fetchPostRaw(...args) { calls.push(['raw', ...args]); return readRaw(...args); }
    },
    copyPostLink: (...args) => { calls.push(['copy', ...args]); return copy(...args); },
    sharePostLink: (...args) => { calls.push(['share', ...args]); return share(...args); },
    RequestCancellation: class { isCancelled = false; cancel() { this.isCancelled = true; } },
    ForumApiError, ForumErrorKind: { Cancelled: 'cancelled' }, failureMessage: error => error.message
  });
  const page = new exports.PostActionsHarness();
  const mergeProduction = page.mergePosts.bind(page);
  Object.assign(page, { topicId: 42, topic: { title: 'Fixture topic', canReply: true }, generation: 4, writeBusy: false,
    hidden: false, error: '', posts: [], rebuild: () => {}, signedIn: () => true, syncReadingContext: () => {},
    session: { user: { id: 7 } }, onQuote: (...args) => { quotes.push(args); },
    startWrite: () => token, endWrite: () => { page.writeBusy = false; },
    mergePosts: posts => merged.push(...posts), getUIContext: () => ({
      getHostContext: () => ({ id: 'fixture-ability' }),
      getPromptAction: () => ({ showToast: options => messages.push(options.message) })
    }) });
  return { page, calls, messages, merged, token, mergeProduction, quotes };
}

const basePost = { id: 71, topicId: 42, postNumber: 7, boosts: [] };

test('reader bookmark controls commit only confirmed receipts and delete by bookmark ID instead of post ID', async () => {
  const create = readerActions();
  await create.page.bookmark(basePost);
  assert.deepEqual(create.messages, ['已收藏']);
  assert.equal(create.merged[0].bookmarked, true); assert.equal(create.merged[0].bookmarkId, 81);
  assert.deepEqual(create.calls[0].slice(0, 2), ['create', 71]);
  const remove = readerActions();
  await remove.page.bookmark({ ...basePost, bookmarked: true, bookmarkId: 81 });
  assert.deepEqual(remove.messages, ['已取消收藏']);
  assert.equal(remove.merged[0].bookmarked, false); assert.equal(remove.merged[0].bookmarkId, undefined);
  assert.deepEqual(remove.calls[0].slice(0, 2), ['delete', 81]);
});

test('unconfirmed bookmarks keep the old state and actionable error without replay, including missing delete metadata', async () => {
  const fixture = readerActions({ create: async () => { throw new ForumApiError('unknown_result', 'Fixture: refresh before retry.'); } });
  await fixture.page.bookmark(basePost);
  assert.deepEqual(fixture.messages, ['Fixture: refresh before retry.']);
  assert.equal(fixture.calls.length, 1); assert.equal(fixture.merged.length, 0); assert.equal(fixture.page.writeBusy, false);
  const missing = readerActions();
  await missing.page.bookmark({ ...basePost, bookmarked: true });
  assert.equal(missing.calls.length, 0); assert.equal(missing.merged.length, 0);
  assert.match(missing.messages[0], /刷新帖子/);
});

test('bookmark receipts cannot update a hidden, cancelled or different-account reader and busy controls cannot submit twice', async () => {
  for (const change of ['generation', 'hidden', 'cancelled']) {
    let release;
    const fixture = readerActions({ create: () => new Promise(resolve => { release = resolve; }) });
    const pending = fixture.page.bookmark(basePost);
    await fixture.page.bookmark(basePost);
    assert.equal(fixture.calls.length, 1);
    if (change === 'generation') { fixture.page.generation++; }
    if (change === 'hidden') { fixture.page.hidden = true; }
    if (change === 'cancelled') { fixture.token.isCancelled = true; }
    release(81); await pending;
    assert.equal(fixture.messages.length, 0); assert.equal(fixture.merged.length, 0);
  }
  const signedOut = readerActions(); signedOut.page.signedIn = () => false;
  await signedOut.page.bookmark(basePost); assert.equal(signedOut.calls.length, 0);
});

test('partial reaction receipts preserve a saved bookmark while explicit server removal clears it', () => {
  const fixture = readerActions();
  fixture.page.posts = [{ ...basePost, bookmarked: true, bookmarkId: 81 }];
  fixture.mergeProduction([{ ...basePost, reactions: [{ id: 'heart', count: 2 }] }]);
  assert.equal(fixture.page.posts[0].bookmarkId, 81); assert.equal(fixture.page.posts[0].bookmarked, true);
  fixture.mergeProduction([{ ...basePost, bookmarked: false }]);
  assert.equal(fixture.page.posts[0].bookmarked, false); assert.equal(fixture.page.posts[0].bookmarkId, undefined);
});

test('nickname metadata survives partial reaction receipts and local bookmark updates without overriding an explicit change', async () => {
  const fixture = readerActions();
  fixture.page.posts = [{ ...basePost, username: 'luokakale', displayName: '洛卡卡了' }];
  fixture.mergeProduction([{ ...basePost, username: 'luokakale', reactions: [{ id: 'heart', count: 2 }] }]);
  assert.equal(fixture.page.posts[0].displayName, '洛卡卡了');
  await fixture.page.bookmark(fixture.page.posts[0]);
  assert.equal(fixture.merged[0].displayName, '洛卡卡了');
  fixture.mergeProduction([{ ...basePost, username: 'luokakale', displayName: '' }]);
  assert.equal(fixture.page.posts[0].displayName, '');
});

test('post-card author and response summaries use real metadata and count positive hearts alongside other reactions', () => {
  const start = pageSource.indexOf('struct TopicPostCard');
  const end = pageSource.indexOf('  @Builder', start);
  assert.ok(start > 0 && end > start);
  const cardSource = ('export ' + pageSource.slice(start, end) + '\n}')
    .replace('struct TopicPostCard', 'class TopicPostCard')
    .replace(/^\s*@Computed\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
  const Card = compile(cardSource, {}).TopicPostCard;
  const card = new Card();
  card.post = { ...basePost, username: 'luokakale', displayName: '洛卡卡了', reactions: [
    { id: 'heart', count: 2 }, { id: 'laughing', count: 3 }, { id: 'zero', count: 0 }, { id: 'invalid', count: NaN }
  ] };
  assert.equal(card.postDisplayName, '洛卡卡了'); assert.equal(card.totalReactions, 5);
  assert.deepEqual(card.visibleReactions.map(reaction => reaction.id), ['heart', 'laughing']);
  assert.equal(card.reactionSummary, '喜欢 2，laughing 3');
  card.post = { ...card.post, displayName: '', reactions: [{ id: 'heart', count: 4 }] };
  assert.equal(card.postDisplayName, 'luokakale'); assert.equal(card.totalReactions, 4);
  assert.equal(card.visibleReactions.length, 1, 'Heart-only reactions now have a real visible summary.');
  card.post = { ...card.post, reactions: [{ id: 'heart', count: 0 }] };
  assert.equal(card.totalReactions, 0); assert.deepEqual(card.visibleReactions, []);
});

test('copy confirms only the completed clipboard write and opening a share panel never claims content was sent', async () => {
  let release;
  const copying = readerActions({ copy: () => new Promise(resolve => { release = resolve; }) });
  const pending = copying.page.copyLink(basePost);
  assert.equal(copying.messages.length, 0);
  release(); await pending;
  assert.deepEqual(copying.messages, ['楼层链接已复制']);
  assert.deepEqual(copying.calls[0], ['copy', 42, 7]);
  const sharing = readerActions(); await sharing.page.sharePost(basePost);
  assert.equal(sharing.messages.length, 0);
  assert.deepEqual(sharing.calls[0].slice(2, 6), [42, 7, 'Fixture topic', 'post_more_71']);
  assert.equal(typeof sharing.calls[0][6], 'function');
  const failing = readerActions({ copy: async () => { throw new Error('fixture denied'); },
    share: async () => { throw new Error('fixture unavailable'); } });
  await failing.page.copyLink(basePost); await failing.page.sharePost(basePost);
  assert.match(failing.messages[0], /未完成/); assert.match(failing.messages[1], /无法打开分享面板/);
});

test('quote reply inserts the real raw post and floor identity into a local draft without posting', async () => {
  const fixture = readerActions();
  await fixture.page.quotePost({ ...basePost, username: 'fixture-user', raw: '**Original**\nSecond line' });
  assert.deepEqual(fixture.quotes, [[42, 7,
    '[quote="fixture-user, post:7, topic:42"]\n**Original**\nSecond line\n[/quote]\n\n']]);
  assert.equal(fixture.calls.length, 0, 'A loaded raw body needs no fetch or mutation.');
  const unloaded = readerActions({ readRaw: async () => 'Server original' });
  await unloaded.page.quotePost({ ...basePost, username: 'fixture-user' });
  assert.deepEqual(unloaded.calls[0].slice(0, 2), ['raw', 71]);
  assert.match(unloaded.quotes[0][2], /Server original/);
  assert.ok(unloaded.calls.every(call => call[0] === 'raw'), 'Quote preparation never submits a post.');
});

test('quote preparation respects reply permission and discards stale, covered-navigation or failed raw reads', async () => {
  const forbidden = readerActions(); forbidden.page.topic.canReply = false;
  await forbidden.page.quotePost(basePost); assert.equal(forbidden.calls.length, 0); assert.equal(forbidden.quotes.length, 0);
  for (const change of ['generation', 'hidden', 'account']) {
    let release;
    const fixture = readerActions({ readRaw: () => new Promise(resolve => { release = resolve; }) });
    const operation = fixture.page.quotePost({ ...basePost, username: 'fixture-user' });
    if (change === 'generation') { fixture.page.generation++; }
    if (change === 'hidden') { fixture.page.hidden = true; }
    if (change === 'account') { fixture.page.session.user = { id: 8 }; }
    release('Server original'); await operation;
    assert.equal(fixture.quotes.length, 0); assert.equal(fixture.messages.length, 0);
  }
  const failure = readerActions({ readRaw: async () => { throw new Error('Fixture original unavailable'); } });
  await failure.page.quotePost(basePost);
  assert.equal(failure.quotes.length, 0); assert.deepEqual(failure.messages, ['Fixture original unavailable']);
});
