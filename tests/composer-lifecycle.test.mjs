import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [
  process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'DevEco SDK TypeScript is required; set DEVECO_TYPESCRIPT_PATH for another installation.');
const ts = require(compiler);
const source = name => readFileSync(fileURLToPath(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url)), 'utf8');

function extract(value, startMarker, endMarker) {
  const start = value.indexOf(startMarker);
  const end = value.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Production extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}

function load(value, bindings = {}) {
  const result = ts.transpileModule(value, {
    fileName: 'composer-lifecycle-production-extract.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  assert.equal((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), result.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const plainComposer = (extract(source('pages/ComposerPage'), 'interface DraftAttachment', '  @Builder\n') + '\n}\n')
  .replace(/^@ComponentV2\s*$/gm, '').replace('export struct ComposerPage', 'export class ComposerPage')
  .replace(/^\s*@Computed\s*\n/gm, '\n').replace(/^\s*@Monitor\([\s\S]*?\)\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');
const cancellation = load(extract(source('services/ForumApi'), 'export enum ForumErrorKind', 'export interface BrowserRequest'));
const settle = () => new Promise(resolve => setImmediate(resolve));

function runtime({ delayedGet = false, creatingTopic = false, savedDraft } = {}) {
  const replyKey = 'draft_7_100_0_0';
  const key = creatingTopic ? 'draft_topic_7' : replyKey;
  const saved = new Map([[replyKey, 'previously saved draft']]);
  if (creatingTopic) {
    saved.set(key, savedDraft ?? JSON.stringify({ version: 1, title: 'A new discussion', categoryId: 4, tags: '鸿蒙,开发', raw: 'new topic draft' }));
  }
  const puts = [];
  const gets = [];
  const dialogs = [];
  const done = [];
  const submitted = [];
  const created = [];
  const toasts = [];
  const writes = [];
  const categoryReads = [];
  const permissions = { categories: [{ id: 4, name: '开发调优', canCreateTopic: true }],
    result: { queued: false, topicId: 567, postNumber: 1, pendingCount: 0 } };
  const timers = new Map();
  let timerId = 0;
  let releaseGet;
  let enteredGet;
  const getEntered = new Promise(resolve => { enteredGet = resolve; });
  const session = { user: { id: 7 }, revision: 1 };
  const forbidden = () => { throw new Error('Native, device and real network I/O is prohibited in this fixture.'); };
  const store = {
    async get(draftKey, fallback) {
      gets.push(draftKey);
      enteredGet();
      if (delayedGet) { return new Promise(resolve => { releaseGet = resolve; }); }
      return saved.get(draftKey) ?? fallback;
    },
    async put(draftKey, value) { puts.push({ key: draftKey, value }); saved.set(draftKey, value); },
    async flush() {},
    async delete(draftKey) { saved.delete(draftKey); }
  };
  const api = {
      async fetchTopic() {
        assert.equal(creatingTopic, false, 'New-topic preparation and submission must never request topic 0.');
        return { title: 'fixture topic', canReply: true };
      },
      async fetchCreateTopicCategories(request) { categoryReads.push(request); return permissions.categories; },
      async createTopic(title, raw, categoryId, tags, request) {
        writes.push({ title, raw, categoryId, tags, request });
        return permissions.result;
      },
      async createPost(topicId, raw, replyTo, request) {
        writes.push({ topicId, raw, replyTo, request });
        return { postNumber: 9 };
      },
      fetchPosts: forbidden, fetchPostRaw: forbidden, updatePost: forbidden, uploadFile: forbidden
  };
  const { ComposerPage } = load(plainComposer, {
    forumSession: session, loadAppearanceSettings: () => ({}), ...cancellation,
    forumApi: api,
    preferences: { async getPreferences() { return store; } },
    fileIo: { open: forbidden }, picker: { DocumentViewPicker: forbidden },
    photoAccessHelper: { PhotoViewPicker: forbidden },
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  const page = new ComposerPage();
  page.presentedAsSheet = true;
  page.creatingTopic = creatingTopic;
  page.topicId = creatingTopic ? 0 : 100;
  page.getUIContext = () => ({
    getHostContext: () => ({}), showAlertDialog: options => dialogs.push(options),
    getPromptAction: () => ({ showToast(options) { toasts.push(options.message); } })
  });
  page.onSubmitted = number => submitted.push(number);
  page.onTopicCreated = (topicId, postNumber) => created.push({ topicId, postNumber });
  page.onDone = () => {
    done.push({ submitting: page.submitting, receipt: page.submissionSucceeded });
    // Mimic the native sheet disappearing immediately after the parent accepts onDone.
    page.presentationHidden();
  };
  return { page, session, key, replyKey, saved, puts, gets, dialogs, done, submitted, created, toasts,
    writes, timers, getEntered, permissions, categoryReads, api,
    releaseGet: value => releaseGet(value) };
}

test('loaded drafts survive permission rechecks and keep-close saves their current text', async () => {
  const state = runtime();
  state.page.presentationShown();
  await settle();
  assert.equal(state.page.draftLoaded, true);
  assert.equal(state.page.draft, 'previously saved draft');
  let stops = 0;
  state.page.textAreaController = { stopEditing() { stops++; } };
  state.page.toggleEmoji();
  assert.equal(state.page.showEmoji, true);
  assert.equal(stops, 1, 'Opening the inline palette releases editing before showing emoji.');
  state.page.toggleEmoji();
  assert.equal(state.page.showEmoji, false);
  assert.equal(stops, 1, 'Closing the palette does not repeat keyboard dismissal.');
  state.page.changeDraft('current edited draft');
  state.page.initialized = false;
  await state.page.prepare();
  assert.equal(state.page.draftLoaded, true);
  assert.equal(state.page.draft, 'current edited draft', 'A permission recheck must not reload an older stored value.');
  assert.deepEqual(state.gets, [state.key]);
  state.page.requestClose();
  assert.equal(state.done.length, 0);
  assert.equal(state.dialogs.length, 1);
  state.dialogs[0].primaryButton.action();
  await settle();
  assert.equal(state.done.length, 1);
  assert.equal(state.saved.get(state.key), 'current edited draft');
  assert.ok(state.puts.every(item => item.value === 'current edited draft'));
  assert.equal(state.page.draftLoaded, false);
  assert.equal(state.timers.size, 0);
});

test('discard-close removes a loaded draft without recreating it during sheet cleanup', async () => {
  const state = runtime();
  state.page.presentationShown();
  await settle();
  state.page.requestClose();
  assert.equal(state.dialogs.length, 1);
  state.dialogs[0].secondaryButton.action();
  await settle();
  assert.equal(state.done.length, 1);
  assert.equal(state.saved.has(state.key), false);
  assert.deepEqual(state.puts, [], 'Disappear cleanup must not write back a discarded draft.');
  assert.equal(state.page.discardedDraft, true);
  assert.equal(state.page.draftLoaded, false);
});

test('successful submission can close while busy without cancelling its receipt or saving an empty draft', async () => {
  const state = runtime();
  state.page.presentationShown();
  await settle();
  await state.page.submit();
  assert.deepEqual(state.done, [{ submitting: true, receipt: true }]);
  assert.deepEqual(state.submitted, [9]);
  assert.equal(state.writes.length, 1);
  assert.equal(state.writes[0].request.isCancelled, false);
  assert.equal(state.page.submitting, false);
  assert.equal(state.page.canSubmit, false);
  assert.equal(state.saved.has(state.key), false);
  assert.deepEqual(state.puts, []);
  await state.page.submit();
  assert.equal(state.writes.length, 1, 'The closed successful composer cannot resubmit the same receipt.');
});

test('closing or changing account during store.get never overwrites an unrestored saved draft', async () => {
  for (const interrupt of ['close', 'account']) {
    const state = runtime({ delayedGet: true });
    state.page.presentationActive = true;
    const preparing = state.page.prepare();
    await state.getEntered;
    assert.ok(state.page.store, 'The preferences object is acquired while its restore read remains pending.');
    assert.equal(state.page.loading, true);
    assert.equal(state.page.draftLoaded, false);
    assert.equal(state.page.draft, '');
    if (interrupt === 'close') {
      state.page.requestClose();
      assert.equal(state.dialogs.length, 0, 'An unloaded draft cannot be mistaken for a user edit or offered for discard.');
      assert.equal(state.done.length, 1);
    } else {
      state.session.user = { id: 8 };
      state.session.revision++;
      state.page.accountChanged();
    }
    assert.deepEqual(state.puts, []);
    assert.equal(state.saved.get(state.key), 'previously saved draft');
    state.releaseGet('previously saved draft');
    await preparing;
    assert.equal(state.page.draftLoaded, false, 'A cancelled or former-owner read cannot mark the new state ready.');
    assert.deepEqual(state.puts, []);
    assert.equal(state.saved.get(state.key), 'previously saved draft');
  }
});

test('new-topic drafts restore and save all metadata under an account key without changing reply drafts', async () => {
  const state = runtime({ creatingTopic: true });
  state.page.presentationShown();
  await settle();
  assert.equal(state.page.title, '发表话题');
  assert.equal(state.page.newTopicTitle, 'A new discussion');
  assert.equal(state.page.categoryId, 4);
  assert.equal(state.page.tagsText, '鸿蒙,开发');
  assert.equal(state.page.draft, 'new topic draft');
  assert.equal(state.page.canSubmit, true);
  state.page.changeTopicTitle('Edited discussion title');
  state.page.changeTags('鸿蒙，开发, 鸿蒙');
  state.page.changeDraft('Edited discussion body');
  state.page.initialized = false;
  await state.page.prepare();
  assert.deepEqual(state.gets, [state.key], 'A permission refresh must not restore an older draft over current edits.');
  state.page.requestClose();
  assert.equal(state.dialogs.length, 1);
  state.dialogs[0].primaryButton.action();
  await settle();
  assert.deepEqual(JSON.parse(state.saved.get(state.key)), {
    version: 1, title: 'Edited discussion title', categoryId: 4, tags: '鸿蒙，开发, 鸿蒙', raw: 'Edited discussion body'
  });
  assert.equal(state.saved.get(state.replyKey), 'previously saved draft');
  assert.equal(state.done.length, 1);
  assert.equal(state.writes.length, 0);
});

test('title, category and tags alone all trigger draft confirmation and discard removes their saved metadata', async () => {
  for (const field of ['title', 'category', 'tags']) {
    const state = runtime({ creatingTopic: true, savedDraft: '' });
    state.page.presentationShown();
    await settle();
    if (field === 'title') { state.page.changeTopicTitle('Only a title so far'); }
    if (field === 'category') { state.page.changeCategory(0); }
    if (field === 'tags') { state.page.changeTags('鸿蒙'); }
    await state.page.saveDraft();
    assert.equal(state.page.draft, '');
    assert.equal(state.page.canSubmit, false);
    state.page.requestClose();
    assert.equal(state.dialogs.length, 1, `${field} edits need keep/discard confirmation even without body text.`);
    state.dialogs[0].secondaryButton.action();
    await settle();
    assert.equal(state.saved.has(state.key), false);
    assert.equal(state.page.newTopicTitle, '');
    assert.equal(state.page.categoryId, 0);
    assert.equal(state.page.tagsText, '');
    assert.equal(state.done.length, 1);
    assert.equal(state.saved.get(state.replyKey), 'previously saved draft');
  }
});

test('restored categories are revalidated and new-topic submission requires title, category and content', async () => {
  const state = runtime({ creatingTopic: true });
  state.permissions.categories = [{ id: 9, name: '可用分类' }];
  state.page.presentationShown();
  await settle();
  assert.equal(state.page.categoryId, 0, 'A category removed from live permissions cannot stay selected.');
  assert.equal(state.page.newTopicTitle, 'A new discussion');
  assert.equal(state.page.draft, 'new topic draft');
  assert.match(state.page.error, /重新选择分类/);
  await state.page.submit();
  assert.equal(state.writes.length, 0);
  state.page.changeCategory(0);
  state.page.changeTopicTitle('   ');
  await state.page.submit();
  assert.equal(state.writes.length, 0);
  state.page.changeTopicTitle('Title restored');
  state.page.changeDraft('');
  await state.page.submit();
  assert.equal(state.writes.length, 0);
  state.page.changeDraft('Body restored');
  assert.equal(state.page.canSubmit, true);
});

test('a created new topic uses the dedicated callback only after receipt, then clears its draft', async () => {
  const state = runtime({ creatingTopic: true });
  state.page.presentationShown();
  await settle();
  state.page.changeTopicTitle('  Ready to publish  ');
  state.page.changeTags('鸿蒙,开发，鸿蒙');
  assert.equal(state.writes.length, 0, 'Typing or restoring a draft cannot publish it.');
  await state.page.submit();
  assert.equal(state.categoryReads.length, 2, 'Fetch permissions once when opening and once before explicit publication.');
  assert.equal(state.writes.length, 1);
  assert.deepEqual({ ...state.writes[0], request: undefined }, {
    title: 'Ready to publish', raw: 'new topic draft', categoryId: 4, tags: ['鸿蒙', '开发'], request: undefined
  });
  assert.deepEqual(state.created, [{ topicId: 567, postNumber: 1 }]);
  assert.deepEqual(state.submitted, []);
  assert.deepEqual(state.toasts, ['话题已发表']);
  assert.deepEqual(state.done, [{ submitting: true, receipt: true }]);
  assert.equal(state.writes[0].request.isCancelled, false);
  assert.equal(state.saved.has(state.key), false);
  assert.equal(state.saved.get(state.replyKey), 'previously saved draft');
  await state.page.submit();
  assert.equal(state.writes.length, 1, 'A successful closed composer cannot resubmit.');
});

test('queued new topics clear the draft and explain moderation without navigating or sending a reply receipt', async () => {
  const state = runtime({ creatingTopic: true });
  state.permissions.result = { queued: true, topicId: 0, postNumber: 0, pendingCount: 1 };
  state.page.presentationShown();
  await settle();
  await state.page.submit();
  assert.equal(state.writes.length, 1);
  assert.deepEqual(state.created, []);
  assert.deepEqual(state.submitted, []);
  assert.deepEqual(state.toasts, ['话题已提交，等待审核后显示']);
  assert.equal(state.done.length, 1);
  assert.equal(state.saved.has(state.key), false);
});

test('permission loss before publication prevents both attachment uploads and topic creation while retaining the draft', async () => {
  const state = runtime({ creatingTopic: true });
  state.page.presentationShown();
  await settle();
  state.page.attachments = [{ id: 'selected', name: 'local.png' }];
  state.permissions.categories = [];
  await state.page.submit();
  assert.equal(state.writes.length, 0);
  assert.equal(state.page.attachments.length, 1);
  assert.equal(state.page.permitted, false);
  assert.equal(state.page.categoryId, 0);
  assert.match(state.page.error, /不可发帖/);
  assert.equal(JSON.parse(state.saved.get(state.key)).raw, 'new topic draft');
  assert.deepEqual(state.done, []);
});

test('validation or unknown publication results retain all draft metadata and do not retry automatically', async () => {
  for (const message of ['标题不符合分类要求', '无法确认发表结果，请先核对个人话题，避免重复发布。']) {
    const state = runtime({ creatingTopic: true });
    state.api.createTopic = async (...args) => { state.writes.push(args); throw new Error(message); };
    state.page.presentationShown();
    await settle();
    await state.page.submit();
    await settle();
    assert.equal(state.writes.length, 1);
    assert.equal(state.page.submissionSucceeded, false);
    assert.equal(state.page.error, message);
    assert.deepEqual(state.created, []);
    assert.deepEqual(state.done, []);
    assert.deepEqual(JSON.parse(state.saved.get(state.key)), {
      version: 1, title: 'A new discussion', categoryId: 4, tags: '鸿蒙,开发', raw: 'new topic draft'
    });
  }
});

test('an account switch while new-topic permissions are pending stops publication and saves only the original owner draft', async () => {
  const state = runtime({ creatingTopic: true });
  state.page.presentationShown();
  await settle();
  let release;
  state.api.fetchCreateTopicCategories = () => new Promise(resolve => { release = resolve; });
  const submitting = state.page.submit();
  await settle();
  state.session.user = { id: 8 };
  state.session.revision++;
  state.page.accountChanged();
  release([{ id: 4, name: '开发调优' }]);
  await submitting;
  await settle();
  assert.equal(state.writes.length, 0);
  assert.equal(state.page.newTopicTitle, '');
  assert.equal(state.page.categoryId, 0);
  assert.equal(state.page.tagsText, '');
  assert.equal(state.page.draftLoaded, false);
  assert.equal(state.saved.has('draft_topic_8'), false);
  assert.equal(JSON.parse(state.saved.get(state.key)).title, 'A new discussion');
  assert.deepEqual(state.done, []);
});

test('confirmed publication remains successful when its draft flush outlives the account or sheet, without stale UI callbacks', async () => {
  for (const interrupt of ['account', 'hidden']) {
    const state = runtime({ creatingTopic: true });
    state.page.presentationShown();
    await settle();
    let releaseFlush;
    state.page.store.flush = () => new Promise(resolve => { releaseFlush = resolve; });
    const submitting = state.page.submit();
    await settle();
    assert.equal(state.writes.length, 1);
    assert.equal(state.page.submissionSucceeded, true, 'The server receipt precedes local cleanup.');
    assert.equal(state.saved.has(state.key), false);
    if (interrupt === 'account') {
      state.session.user = { id: 8 };
      state.session.revision++;
      state.page.accountChanged();
      // Another account can restore its editor after this request loses ownership.
      state.page.draft = 'new owner body';
      state.page.newTopicTitle = 'new owner title';
      state.page.categoryId = 12;
      state.page.tagsText = 'new-owner-tag';
    } else {
      state.page.presentationHidden();
    }
    releaseFlush();
    await submitting;
    assert.equal(state.page.submissionSucceeded, true, 'An invalid UI owner must not turn a confirmed server success into failure.');
    assert.equal(state.page.submitting, false);
    assert.equal(state.saved.has(state.key), false, 'Account changes cannot re-save the published draft.');
    assert.deepEqual(state.puts, []);
    assert.deepEqual(state.toasts, []);
    assert.deepEqual(state.created, []);
    assert.deepEqual(state.submitted, []);
    assert.deepEqual(state.done, []);
    if (interrupt === 'account') {
      assert.equal(state.page.draft, 'new owner body');
      assert.equal(state.page.newTopicTitle, 'new owner title');
      assert.equal(state.page.categoryId, 12);
      assert.equal(state.page.tagsText, 'new-owner-tag');
    }
  }
});

test('known category tag requirements count distinct tags and block publication before attachment I/O', async () => {
  const state = runtime({ creatingTopic: true });
  state.permissions.categories = [{ id: 4, name: '开发调优', minimumRequiredTags: 2 }];
  state.page.presentationShown();
  await settle();
  state.page.attachments = [{ id: 'selected', name: 'local.png' }];
  state.page.changeTags('鸿蒙，鸿蒙');
  assert.equal(state.page.canSubmit, false);
  await state.page.submit();
  assert.equal(state.writes.length, 0);
  assert.equal(state.categoryReads.length, 1, 'Known unmet constraints do not start publication or attachment I/O.');
  state.page.changeTags('鸿蒙，开发');
  assert.equal(state.page.canSubmit, true);
  state.permissions.categories = [{ id: 4, name: '开发调优', minimumRequiredTags: 3 }];
  await state.page.submit();
  assert.equal(state.categoryReads.length, 2);
  assert.equal(state.writes.length, 0, 'Refreshed tag requirements also run before reading or uploading attachments.');
  assert.equal(state.page.attachments.length, 1);
  assert.match(state.page.error, /至少需要 3 个不同标签/);
  assert.equal(state.page.canSubmit, false);
  assert.equal(JSON.parse(state.saved.get(state.key)).tags, '鸿蒙，开发');
});

test('empty new-topic metadata is not restored as a draft and late changes cannot resurrect discarded or published drafts', async () => {
  const state = runtime({ creatingTopic: true });
  state.page.presentationShown();
  await settle();
  state.page.draft = '';
  state.page.newTopicTitle = '';
  state.page.categoryId = 0;
  state.page.tagsText = '';
  await state.page.saveDraft();
  assert.equal(state.saved.has(state.key), false);
  assert.equal(state.page.saveMessage, '');
  state.page.discardedDraft = true;
  state.page.draft = 'late text-change callback';
  await state.page.saveDraft();
  assert.equal(state.saved.has(state.key), false);
  state.page.discardedDraft = false;
  state.page.submissionSucceeded = true;
  await state.page.saveDraft();
  assert.equal(state.saved.has(state.key), false);
});
