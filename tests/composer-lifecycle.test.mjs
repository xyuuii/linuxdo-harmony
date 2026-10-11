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

function runtime({ delayedGet = false } = {}) {
  const key = 'draft_7_100_0_0';
  const saved = new Map([[key, 'previously saved draft']]);
  const puts = [];
  const gets = [];
  const dialogs = [];
  const done = [];
  const submitted = [];
  const writes = [];
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
  const { ComposerPage } = load(plainComposer, {
    forumSession: session, loadAppearanceSettings: () => ({}), ...cancellation,
    forumApi: {
      async fetchTopic() { return { title: 'fixture topic', canReply: true }; },
      async createPost(topicId, raw, replyTo, request) {
        writes.push({ topicId, raw, replyTo, request });
        return { postNumber: 9 };
      },
      fetchPosts: forbidden, fetchPostRaw: forbidden, updatePost: forbidden, uploadFile: forbidden
    },
    preferences: { async getPreferences() { return store; } },
    fileIo: { open: forbidden }, picker: { DocumentViewPicker: forbidden },
    photoAccessHelper: { PhotoViewPicker: forbidden },
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  const page = new ComposerPage();
  page.presentedAsSheet = true;
  page.topicId = 100;
  page.getUIContext = () => ({
    getHostContext: () => ({}), showAlertDialog: options => dialogs.push(options),
    getPromptAction: () => ({ showToast() {} })
  });
  page.onSubmitted = number => submitted.push(number);
  page.onDone = () => {
    done.push({ submitting: page.submitting, receipt: page.submissionSucceeded });
    // Mimic the native sheet disappearing immediately after the parent accepts onDone.
    page.presentationHidden();
  };
  return { page, session, key, saved, puts, gets, dialogs, done, submitted, writes, timers, getEntered,
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
