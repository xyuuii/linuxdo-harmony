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

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    fileName: 'post-revision-production.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const models = load(source('models/ForumModels'));
const policy = load(source('models/PostRevisionModels'));
const wire = load(source('services/PostRevisionWire'), {
  require: name => { assert.equal(name, '../models/ForumModels'); return models; }
});
const richSource = source('components/RichPostContent');
const rich = load(richSource.slice(richSource.indexOf('export interface PostInline'), richSource.indexOf('@ComponentV2')));

function receipt(overrides = {}) {
  return { post_id: 71, current_revision: 5, first_revision: 2, previous_revision: 2, next_revision: 9,
    last_revision: 9, current_version: 3, version_count: 4, username: 'fixture-editor', display_username: 'FixtureEditor',
    acting_user_name: 'Fixture Name', avatar_template: '/avatar/{size}.png', created_at: '2026-10-28T12:00:00Z',
    edit_reason: 'Fixture correction', body_changes: { inline: '<p>Before<ins>after</ins></p>' }, ...overrides };
}

test('revision receipts preserve real editor, time, reason and nonconsecutive server pointers', () => {
  const revision = wire.postRevisionFromWire(receipt(), 71, 5);
  assert.equal(revision.currentRevision, 5); assert.equal(revision.previousRevision, 2); assert.equal(revision.nextRevision, 9);
  assert.equal(revision.currentVersion, 3); assert.equal(revision.versionCount, 4);
  assert.equal(revision.editorUsername, 'FixtureEditor'); assert.equal(revision.editorName, 'Fixture Name');
  assert.equal(revision.createdAt, '2026-10-28T12:00:00Z'); assert.equal(revision.editReason, 'Fixture correction');
  assert.equal(revision.avatarUrl, 'https://linux.do/avatar/144.png');
  assert.deepEqual(wire.postRevisionFromWire(receipt({ previous_revision: null, current_revision: 2 }), 71).previousRevision, undefined);
});

test('revision mapping rejects another post, mismatched requested version and invalid navigation ranges', () => {
  for (const overrides of [{ post_id: 72 }, { current_revision: 1 }, { first_revision: 7 }, { last_revision: 4 },
    { previous_revision: 5 }, { previous_revision: 1 }, { next_revision: 4 }, { next_revision: 10 },
    { next_revision: 6.5 }, { current_version: 1 }, { current_version: 5 }, { version_count: undefined }]) {
    assert.throws(() => wire.postRevisionFromWire(receipt(overrides), 71));
  }
  assert.throws(() => wire.postRevisionFromWire(receipt(), 71, 4));
});

test('hidden-side or failed diff receipts do not reconstruct content from raw, markdown or alternate versions', () => {
  const revision = wire.postRevisionFromWire(receipt({ previous_hidden: true, current_hidden: true, diff_error: true,
    edit_reason: undefined, body_changes: { inline: undefined, side_by_side: 'PRIVATE BODY', side_by_side_markdown: 'PRIVATE RAW' },
    title_changes: null, raw: 'PRIVATE FALLBACK', username: undefined, display_username: undefined }), 71);
  assert.equal(revision.previousHidden, true); assert.equal(revision.currentHidden, true); assert.equal(revision.diffError, true);
  assert.equal(revision.bodyDiffHtml, ''); assert.equal(revision.titleDiffHtml, ''); assert.equal(revision.editReason, '');
  assert.equal(revision.editorUsername, '');
  assert.equal(JSON.stringify(revision).includes('PRIVATE'), false);
});

test('metadata changes preserve missing values and display server-visible tags, authors and wiki state', () => {
  const revision = wire.postRevisionFromWire(receipt({ tags_changes: { previous: ['old'], current: ['new', 'visible'] },
    wiki_changes: { previous: undefined, current: true },
    user_changes: { previous: { username: 'old-author' }, current: { display_username: 'NewAuthor' } },
    locale_changes: { previous: 'en', current: 'zh_CN' } }), 71);
  assert.deepEqual(revision.metadataChanges, [
    { label: '标签', previous: 'old', current: 'new、visible' }, { label: '维基模式', previous: '未提供', current: '开启' },
    { label: '作者', previous: 'old-author', current: 'NewAuthor' }, { label: '语言', previous: 'en', current: 'zh_CN' }
  ]);
});

test('inline and block diff markings survive safe native rendering without executing scripts or unsafe links', () => {
  const html = '<div class="inline-diff"><p class="diff-del">Old block</p><p class="diff-ins">New block</p>' +
    '<p>Common <del>removed</del> <ins>added</ins> tail.</p>' +
    '<script>PRIVATE_SCRIPT</script><iframe src="https://evil.example/">PRIVATE_FRAME</iframe>' +
    '<a href="javascript:alert(1)" onclick="bad()">safe label</a><img src="javascript:bad()"></div>';
  const blocks = rich.parsePostContent(wire.revisionDiffForReading(html));
  const text = blocks.flatMap(block => block.runs.map(run => run.text)).join('');
  for (const content of ['【删除】Old block【/删除】', '【新增】New block【/新增】',
    '【删除】removed【/删除】', '【新增】added【/新增】', 'tail.', 'safe label']) { assert.ok(text.includes(content), content); }
  assert.equal(text.includes('PRIVATE_SCRIPT'), false); assert.equal(text.includes('PRIVATE_FRAME'), false);
  assert.ok(blocks.flatMap(block => block.runs).every(run => !run.href.startsWith('javascript:')));
  assert.ok(blocks.every(block => !block.url.startsWith('javascript:')));
});

const sheetSource = source('components/PostRevisionSheet');
const sheetClass = (sheetSource.slice(sheetSource.indexOf('export struct PostRevisionSheet'), sheetSource.indexOf('  build()')) + '\n}')
  .replace('export struct PostRevisionSheet', 'export class PostRevisionSheet')
  .replace(/^\s*@(?:Computed|Monitor\([^\n]*\))\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');

class ForumApiError extends Error { constructor(kind, message) { super(message); this.kind = kind; } }
function sheetRuntime(respond = async (_postId, revision) => wire.postRevisionFromWire(receipt({ current_revision: revision || 5 }), 71)) {
  const requests = [];
  const closes = [];
  let generation = 4;
  const session = { user: { id: 7 }, revision: 1 };
  const exports = load(sheetClass, {
    forumSession: session, canReadPostHistory: policy.canReadPostHistory, revisionDiffForReading: wire.revisionDiffForReading,
    RequestCancellation: class { isCancelled = false; cancel() { this.isCancelled = true; } },
    forumApi: { getSessionGeneration: () => generation,
      async fetchPostRevision(...args) { requests.push(args); return respond(...args); } },
    ForumApiError, ForumErrorKind: { AuthenticationRequired: 'auth', VerificationRequired: 'verify' }
  });
  const sheet = new exports.PostRevisionSheet();
  Object.assign(sheet, { post: { id: 71, postNumber: 7, canViewEditHistory: true, version: 3 }, visible: true,
    session, onClose: () => closes.push(true) });
  return { sheet, requests, closes, session, setGeneration(number) { generation = number; } };
}

test('the native history sheet gates loading on permission, keeps public version separate and follows only returned pointers', async () => {
  const rt = sheetRuntime(async (_postId, number) => wire.postRevisionFromWire(receipt({
    current_revision: number || 5, previous_revision: number === 2 ? null : 2,
    next_revision: number === 2 ? 5 : 9
  }), 71));
  await rt.sheet.load(0);
  assert.equal(rt.requests[0][1], 0, 'Public version 3 cannot stand in for the latest server revision.');
  rt.sheet.move(true); await Promise.resolve(); await Promise.resolve();
  assert.equal(rt.requests[1][1], 2, 'Older revisions may be separated by hidden versions.');
  rt.sheet.move(true); assert.equal(rt.requests.length, 2, 'No pointer means no inferred revision request.');
  const denied = sheetRuntime(); denied.sheet.post.canViewEditHistory = false;
  await denied.sheet.load(0); assert.equal(denied.requests.length, 0);
  denied.sheet.post.canViewEditHistory = true; denied.sheet.post.version = 1;
  await denied.sheet.load(0); assert.equal(denied.requests.length, 0);
});

test('account changes, cancellation, closure and session-generation changes cannot disclose late revision content', async () => {
  for (const change of ['account', 'generation', 'closed', 'cancelled']) {
    let release;
    const rt = sheetRuntime(() => new Promise(resolve => { release = resolve; }));
    const pending = rt.sheet.load(0);
    if (change === 'account') { rt.session.user = { id: 8 }; rt.sheet.accountChanged(); }
    if (change === 'generation') { rt.setGeneration(5); }
    if (change === 'closed') { rt.sheet.visible = false; }
    if (change === 'cancelled') { rt.requests[0][2].cancel(); }
    release(wire.postRevisionFromWire(receipt(), 71)); await pending;
    assert.equal(rt.sheet.revision, undefined, change); assert.equal(rt.sheet.error, '', change);
  }
});

test('history errors remain actionable, clear stale content and require an explicit retry after foreground interruption', async () => {
  const rt = sheetRuntime(async () => { throw new ForumApiError('verify', 'Fixture verification required'); });
  rt.sheet.revision = wire.postRevisionFromWire(receipt(), 71);
  await rt.sheet.load(2);
  assert.equal(rt.sheet.revision, undefined); assert.equal(rt.sheet.error, 'Fixture verification required');
  assert.equal(rt.sheet.needsLogin, true); assert.equal(rt.requests.length, 1);
  let release;
  const interrupted = sheetRuntime(() => new Promise(resolve => { release = resolve; }));
  const operation = interrupted.sheet.load(0);
  interrupted.sheet.foreground = false; interrupted.sheet.foregroundChanged();
  assert.equal(interrupted.requests[0][2].isCancelled, true); assert.match(interrupted.sheet.error, /重新读取/);
  release(wire.postRevisionFromWire(receipt(), 71)); await operation;
  assert.equal(interrupted.sheet.revision, undefined);
});
