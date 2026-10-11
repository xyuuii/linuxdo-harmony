import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Reuse DevEco's installed compiler. These tests do not run ArkUI or native I/O.
const require = createRequire(import.meta.url);
const compiler = [
  process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required; set DEVECO_TYPESCRIPT_PATH for another installation.');
const ts = require(compiler);
const sourceRoot = fileURLToPath(new URL('../app/entry/src/main/ets/', import.meta.url));

function source(relativeName) {
  return readFileSync(path.join(sourceRoot, relativeName + '.ets'), 'utf8');
}

function extract(value, startMarker, endMarker) {
  const start = value.indexOf(startMarker);
  const end = value.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Production source extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}

function withoutImports(value) {
  return value.replace(/^import [^\n]*;\r?\n/gm, '');
}

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    fileName: 'production-extract.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length,
    0, 'Extracted production code must transpile. ArkTS compilation is verified separately.');
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const richSource = source('components/RichPostContent');
const topicSource = source('pages/TopicPage');
const rich = load(withoutImports(extract(richSource, 'export interface PostInline', '@ComponentV2')));
const tree = load(extract(topicSource, 'export interface TopicTreeRow', 'class TopicRowsSource'));
const links = load(extract(topicSource, 'interface TopicLink', '@ComponentV2'));
const cancellation = load(extract(source('services/ForumApi'), 'export enum ForumErrorKind', 'export interface BrowserRequest'));

test('cooked content preserves headings, inline styles, quotes, code, lists, pictures and links', () => {
  const blocks = rich.parsePostContent('<h2>标题</h2><p>正文<strong>粗体</strong><em>斜体</em>' +
    '<code>foo()</code><a href="/t/123/9">站内</a></p><blockquote><p>引用</p></blockquote>' +
    '<pre>x\n  y</pre><ol start="3"><li>第三</li><li>第四</li></ol><img src="/uploads/a.png" alt="图">');
  assert.ok(blocks.some(block => block.heading));
  assert.ok(blocks.some(block => block.runs.some(run => run.text === '粗体' && run.bold)));
  assert.ok(blocks.some(block => block.runs.some(run => run.text === '斜体' && run.italic)));
  assert.ok(blocks.some(block => block.runs.some(run => run.text === 'foo()' && run.code)));
  assert.ok(blocks.some(block => block.quote));
  assert.ok(blocks.some(block => block.kind === 'code' && block.runs.some(run => run.text.includes('\n  y'))));
  assert.ok(blocks.some(block => block.runs.some(run => run.text === '3. ')));
  assert.ok(blocks.some(block => block.kind === 'image' && block.url === 'https://linux.do/uploads/a.png'));
  assert.ok(blocks.some(block => block.runs.some(run => run.href === 'https://linux.do/t/123/9')));
});

test('onebox site-icon at 32 pixels and emoji stay inline while the normal thumbnail remains a picture', () => {
  // The site-icon class, empty alt and dimensions match the actual forum post;
  // fixture image addresses never perform network requests in these tests.
  const blocks = rich.parsePostContent('<header><img src="https://images.example.test/app-store.png" ' +
    'class="site-icon" alt="" data-dominant-color="3DA0F8" width="32" height="32">' +
    '<a href="https://apps.example.test/app">App Store</a></header>' +
    '<p><img src="/images/emoji/smile.png" class="emoji" alt=":smile:">' +
    '<img src="/uploads/custom-emoji.png" class="emoji emoji-custom" alt=":custom:"></p>' +
    '<img src="https://images.example.test/thumbnail.png" class="thumbnail" width="690" height="362">');
  const pictures = blocks.filter(block => block.kind === 'image');
  assert.equal(pictures.length, 1, 'The onebox site icon must not occupy a full-width picture block.');
  assert.equal(pictures[0].url, 'https://images.example.test/thumbnail.png');
  const inline = blocks.flatMap(block => block.runs).filter(run => run.emojiUrl);
  assert.deepEqual(inline.map(run => run.emojiUrl), [
    'https://images.example.test/app-store.png',
    'https://linux.do/images/emoji/smile.png',
    'https://linux.do/uploads/custom-emoji.png'
  ]);
  const ordinarySmallImage = rich.parsePostContent('<img src="/uploads/small.png" width="32" height="32">');
  assert.equal(ordinarySmallImage[0].kind, 'image', 'Dimensions alone must not turn ordinary pictures into emoji.');
  const largeSiteImage = rich.parsePostContent('<img src="/uploads/large.png" class="site-icon" width="690" height="362">');
  assert.equal(largeSiteImage[0].kind, 'image', 'The site-icon class only uses inline rendering with known small dimensions.');
});

test('executable markup and unsafe links are omitted, including an unterminated script', () => {
  const blocks = rich.parsePostContent('<p>visible</p><script>alert(1)</script><style>bad</style>' +
    '<img src="javascript:evil" alt="safe"><a href="file:///tmp/a">safe</a>' +
    '<iframe src="https://example.test">hidden</iframe>');
  const text = blocks.flatMap(block => block.runs.map(run => run.text)).join('');
  assert.ok(text.includes('visible'));
  for (const forbidden of ['alert', 'bad', 'hidden']) { assert.ok(!text.includes(forbidden)); }
  assert.ok(blocks.every(block => block.url === '' && block.runs.every(run => run.href === '')));
  const unclosed = rich.parsePostContent('<p>A</p><script>unterminated');
  assert.equal(unclosed.flatMap(block => block.runs.map(run => run.text)).join(''), 'A');
});

test('content URLs reject executable, local, credential-bearing and control-character addresses', () => {
  for (const value of [
    'data:image/png;base64,a', 'file:///tmp/a', 'javascript:evil',
    'https://user:password@linux.do/a', 'https://linux.do@evil.test/a',
    'https://example.test/a\nb', 'https://example.test\\a'
  ]) { assert.equal(rich.postContentUrl(value), '', value); }
  assert.equal(rich.postContentUrl('/uploads/a.png'), 'https://linux.do/uploads/a.png');
  assert.equal(rich.postContentUrl('HTTPS://linux.do/t/1'), 'https://linux.do/t/1');
});

test('internal topic links retain topic and post numbers and reject lookalike domains', () => {
  assert.deepEqual(links.parseTopicLink('https://linux.do/t/2998703/147'), { id: 2998703, number: 147 });
  assert.deepEqual(links.parseTopicLink('https://linux.do/t/topic/2998703/147'), { id: 2998703, number: 147 });
  assert.equal(links.parseTopicLink('https://linux.do.evil.test/t/1/2'), undefined);
});

test('threaded replies preview three, expand and collapse, preserve missing parents and support linear order', () => {
  const post = (id, postNumber, replyToPostNumber = 0, replyCount = 0) =>
    ({ id, postNumber, replyToPostNumber, replyCount, cooked: '', topicId: 10 });
  const posts = [post(1, 1, 0, 99), post(2, 2, 0, 5), post(3, 3, 2), post(4, 4, 3),
    post(5, 5, 2), post(6, 6, 2), post(7, 7, 999)];
  let rows = tree.topicTreeRows(posts, [], [], true);
  assert.ok(rows.some(row => row.post.id === 7 && row.depth === 0));
  assert.equal(rows.filter(row => row.rootId === 2 && row.depth > 0).length, 3);
  assert.equal(rows.find(row => row.post.id === 1).totalReplies, 0);
  assert.ok(rows.find(row => row.post.id === 2).unloadedIds.includes(2));
  rows = tree.topicTreeRows(posts, [2], [], true);
  assert.equal(rows.filter(row => row.rootId === 2 && row.depth > 0).length, 4);
  rows = tree.topicTreeRows(posts, [2], [2], true);
  assert.equal(rows.filter(row => row.rootId === 2 && row.depth > 0).length, 0);
  rows = tree.topicTreeRows(posts, [], [], false);
  assert.equal(rows.length, 7);
  assert.ok(rows.every(row => row.depth === 0));
  assert.deepEqual(rows.map(row => row.post.postNumber), [1, 2, 3, 4, 5, 6, 7]);
});

test('paragraph-wrapped list items retain numbering and an ordinary aside retains the outer quote', () => {
  const blocks = rich.parsePostContent('<ol start="3"><li><p>第三项</p></li><li>第四项</li></ol>');
  assert.equal(blocks[0].runs.map(run => run.text).join(''), '3. 第三项');
  assert.equal(blocks[1].runs.map(run => run.text).join(''), '4. 第四项');
  const quote = rich.parsePostContent('<blockquote><aside><p>quote A</p></aside><p>quote B</p></blockquote>');
  assert.ok(quote.every(block => block.quote));
});

test('first-post navigation keeps the header and resets a retained-root tail slice while other posts retain their exact index', async () => {
  const frames = [];
  const topicReads = [];
  const session = { user: { id: 1 }, revision: 0 };
  const posts = [1, 2, 3].map(number => ({ id: number, postNumber: number, replyToPostNumber: 0,
    replyCount: 0, cooked: '', topicId: 100 }));
  const declarations = extract(topicSource, 'export interface TopicTreeRow', '@ComponentV2');
  const page = (extract(topicSource, 'export struct TopicPage', '  @Builder\n') + '\n}\n')
    .replace('export struct TopicPage', 'export class TopicPage')
    .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
    .replace(/@(Param|Event|Local) /g, '');
  const exports = load(declarations + '\n' + page, {
    forumSession: session,
    loadAppearanceSettings: () => ({}),
    RequestCancellation: cancellation.RequestCancellation,
    forumApi: { async fetchTopic(id, number) {
      topicReads.push({ id, number });
      return { postStream: { posts, stream: [1, 2, 3] } };
    } },
    Scroller: class {
      calls = [];
      scrollToIndex(...args) { this.calls.push(args); }
    },
    ScrollAlign: { START: 'start' },
    setTimeout(callback) { frames.push(callback); return frames.length; }
  });
  const topic = new exports.TopicPage();
  topic.topicId = 100;
  const layout = () => { while (frames.length > 0) { frames.shift()(); } };
  await topic.reload(1);
  layout();
  assert.equal(topic.scroller.calls.at(-1)[0], 0, 'Initial first-post reading must include the title header.');
  topic.jump(1);
  layout();
  assert.equal(topic.scroller.calls.at(-1)[0], 0, 'Returning to the first post must scroll to the header.');
  topic.jump(3);
  layout();
  assert.equal(topic.scroller.calls.at(-1)[0], 4, 'A numbered post still uses the two leading header items.');
  assert.equal(topic.highlightedId, 3);

  // tail() retains the original post before the final window. Its presence
  // alone must not make jump(1) reuse that tail window through reveal(1).
  topic.posts = [posts[0], { id: 1596, postNumber: 1596, replyToPostNumber: 0,
    replyCount: 0, cooked: '', topicId: 100 }];
  topic.sliceStart = 1561;
  topic.sliceEnd = 1581;
  topic.consumed = [1, 1596];
  topic.currentNumber = 1596;
  topic.rebuild();
  topic.jump(1);
  // Let the production reload Promise finish against the immediate fixture API.
  await new Promise(resolve => setImmediate(resolve));
  layout();
  assert.deepEqual(topicReads.at(-1), { id: 100, number: 1 });
  assert.equal(topicReads.length, 2, 'A retained first post must still request the initial slice after viewing the tail.');
  assert.equal(topic.sliceStart, 0);
  assert.equal(topic.sliceEnd, 2);
  assert.deepEqual(topic.posts.map(post => post.postNumber), [1, 2, 3]);
  assert.deepEqual(topic.previousIds, [], 'The first slice must not retain the tail gap before its replies.');
  assert.equal(topic.currentNumber, 1);
  assert.equal(topic.scroller.calls.at(-1)[0], 0);
});

function composerRuntime() {
  const calls = [];
  const session = { user: { id: 1 }, revision: 0 };
  const forbidden = () => { throw new Error('Native I/O is prohibited in this test.'); };
  const api = {
    async fetchTopic(...args) { calls.push({ method: 'fetchTopic', args }); return { canReply: true }; },
    async fetchPosts(...args) { calls.push({ method: 'fetchPosts', args }); return []; },
    async createPost(...args) { calls.push({ method: 'createPost', args }); return { postNumber: 23 }; },
    async updatePost(...args) { calls.push({ method: 'updatePost', args }); return { postNumber: 1 }; },
    async uploadFile(...args) {
      calls.push({ method: 'uploadFile', args });
      return { fileName: 'a.png', shortUrl: 'upload://a.png', width: 0, height: 0 };
    }
  };
  // Only UI syntax is removed. The production fields, permission checks, async
  // submission, draft cleanup and account-change callback execute unchanged.
  const prefix = extract(source('pages/ComposerPage'), 'interface DraftAttachment', '  @Builder\n');
  const plainClass = (prefix + '\n}\n')
    .replace(/^@ComponentV2\s*$/gm, '')
    .replace('export struct ComposerPage', 'export class ComposerPage')
    .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n')
    .replace(/@(Param|Event|Local) /g, '');
  const exports = load(plainClass, {
    forumApi: api, forumSession: session, RequestCancellation: cancellation.RequestCancellation,
    loadAppearanceSettings: () => ({}), setTimeout, clearTimeout,
    preferences: { getPreferences: forbidden }, fileIo: { open: forbidden },
    picker: { DocumentViewPicker: forbidden }, photoAccessHelper: { PhotoViewPicker: forbidden }
  });
  const composer = new exports.ComposerPage();
  composer.ownerId = 1;
  composer.prepareGeneration = 1;
  composer.draftKey = 'draft_1_100_0_0';
  composer.session = session;
  composer.permitted = true;
  composer.topicId = 100;
  composer.draft = 'private draft';
  composer.getUIContext = () => ({ getPromptAction: () => ({ showToast() {} }), showAlertDialog: forbidden });
  return { composer, calls, session };
}

test('changing account during attachment read cancels upload and post and clears private composer state', async () => {
  const { composer, calls, session } = composerRuntime();
  let readEntered;
  let releaseRead;
  const entered = new Promise(resolve => { readEntered = resolve; });
  composer.attachments = [{ id: 'one', name: 'a.png', uri: 'file://private-fixture', mime: 'image/png', size: 3 }];
  composer.attachmentBytes = async () => {
    readEntered();
    return new Promise(resolve => { releaseRead = resolve; });
  };
  const sending = composer.submit();
  await entered;
  const request = composer.writeRequest;
  assert.ok(request instanceof cancellation.RequestCancellation);
  session.user = { id: 2 };
  session.revision++;
  // ArkUI invokes this production monitor when the observed session changes.
  composer.accountChanged();
  assert.equal(request.isCancelled, true);
  releaseRead(new ArrayBuffer(3));
  await sending;
  assert.ok(!calls.some(call => call.method === 'uploadFile' || call.method === 'createPost' || call.method === 'updatePost'));
  assert.equal(composer.draft, '');
  assert.deepEqual(composer.attachments, []);
  assert.equal(composer.permitted, false);
  assert.equal(composer.canSubmit, false);
  assert.equal(composer.submitting, false);
});

test('a successful post remains successful when local draft cleanup fails and cannot submit again', async () => {
  const { composer, calls } = composerRuntime();
  let done = 0;
  const submitted = [];
  composer.store = { async delete() { throw new Error('fixture disk failure'); }, async flush() {} };
  composer.onDone = () => { done++; };
  composer.onSubmitted = number => { submitted.push(number); };
  await composer.submit();
  assert.equal(calls.filter(call => call.method === 'createPost').length, 1);
  assert.equal(done, 1);
  assert.deepEqual(submitted, [23]);
  assert.equal(composer.error, '');
  assert.equal(composer.draft, '');
  assert.equal(composer.permitted, false);
  assert.equal(composer.canSubmit, false);
  assert.equal(composer.submitting, false);
  await composer.submit();
  assert.equal(calls.filter(call => call.method === 'createPost').length, 1);
});
