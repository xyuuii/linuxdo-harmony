import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = name => readFileSync(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value.replace(/^import .*;\n/gm, ''), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const repository = load(source('services/DraftRepository'));
const topic = overrides => JSON.stringify({ version: 1, title: 'A discussion', raw: 'Topic body', categoryId: 4, tags: '鸿蒙', ...overrides });
function storeOf(values = {}) {
  const valuesMap = new Map(Object.entries(values)); const writes = []; const deletes = []; let flushes = 0;
  return { values: valuesMap, writes, deletes, get flushes() { return flushes; },
    async getAll() { return Object.fromEntries(valuesMap); },
    async put(key, value) { writes.push([key, value]); valuesMap.set(key, value); },
    async delete(key) { deletes.push(key); valuesMap.delete(key); },
    async flush() { flushes++; }
  };
}

test('legacy getAll discovery preserves existing draft keys and never leaks a similarly prefixed account', async () => {
  const store = storeOf({ draft_topic_7: topic(), draft_7_100_0_0: 'Reply body', draft_7_101_9_88: 'Edited body',
    draft_topic_70: topic({ title: 'Private other account' }), draft_70_100_0_0: 'Private other reply',
    draft_7_0_0_0: 'invalid topic', draft_7_100_0_99: 'invalid edit', unrelated: 'ignore' });
  const original = [...store.values.entries()];
  const entries = await repository.listLocalDrafts(store, 7);
  assert.equal(entries.length, 3); assert.ok(entries.every(entry => entry.target.ownerId === 7));
  assert.ok(entries.every(entry => entry.updatedAt === 0), 'No fabricated migration timestamp.');
  assert.equal(entries.find(entry => entry.target.creatingTopic).title, 'A discussion');
  assert.equal(entries.find(entry => entry.target.postId === 88).context, '编辑第 9 楼');
  assert.deepEqual([...store.values.entries()], original); assert.deepEqual(store.writes, []); assert.deepEqual(store.deletes, []);
});

test('new metadata orders local drafts while malformed stored drafts remain visible and retained', async () => {
  const store = storeOf({ draft_topic_7: '{broken json', draft_7_100_3_0: 'Continuing reply' });
  const target = repository.parseDraftTarget('draft_7_100_3_0', 7);
  await repository.recordLocalDraftMetadata(store, target, 'A real topic title', 1700000000000);
  const entries = await repository.listLocalDrafts(store, 7);
  assert.equal(entries[0].title, 'A real topic title'); assert.equal(entries[0].updatedAt, 1700000000000);
  assert.equal(entries[0].target.replyTo, 3);
  const corrupt = entries.find(entry => entry.target.creatingTopic);
  assert.equal(corrupt.readable, false); assert.match(corrupt.excerpt, /原始数据已保留/);
  assert.equal(store.values.get('draft_topic_7'), '{broken json');
});

test('empty new-topic snapshots and blank reply values do not become ghost draft entries', async () => {
  const store = storeOf({ draft_topic_7: topic({ title: '', raw: '', categoryId: 0, tags: '' }), draft_7_100_0_0: '  ' });
  assert.deepEqual(await repository.listLocalDrafts(store, 7), []);
});

test('single draft deletion checks owner and target, removes metadata and process attachments, and keeps every other draft', async () => {
  const store = storeOf({ draft_7_100_3_0: 'Delete me', draft_topic_7: topic(), draft_8_100_3_0: 'Keep other owner' });
  const target = repository.parseDraftTarget('draft_7_100_3_0', 7);
  await repository.recordLocalDraftMetadata(store, target, 'A topic', 1700000000000);
  repository.localDraftAttachments.set(target.key, [{ id: 'a', uri: 'local', name: 'file', mime: 'text/plain', size: 4 }]);
  await assert.rejects(() => repository.removeLocalDraft(store, target, 8));
  await assert.rejects(() => repository.removeLocalDraft(store, { ...target, topicId: 999 }, 7));
  assert.deepEqual(store.deletes, []);
  await repository.removeLocalDraft(store, target, 7);
  assert.equal(store.values.has(target.key), false); assert.equal(store.values.has(repository.draftMetadataKey(target.key)), false);
  assert.equal(repository.localDraftAttachments.has(target.key), false); assert.equal(store.flushes, 1);
  assert.equal(store.values.has('draft_topic_7'), true); assert.equal(store.values.has('draft_8_100_3_0'), true);
});

const pageSource = source('pages/DraftsPage');
const start = pageSource.indexOf('export struct DraftsPage'); const end = pageSource.indexOf('  build()', start);
assert.ok(start >= 0 && end > start);
const plainPage = (pageSource.slice(start, end) + '\n}\n').replace('export struct DraftsPage', 'export class DraftsPage')
  .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
function pageRuntime() {
  const session = { user: { id: 7 }, revision: 1 }; const store = storeOf({ draft_7_100_0_0: 'Private draft' });
  const opened = []; const dialogs = [];
  const { DraftsPage } = load(plainPage, { ...repository, forumSession: session, loadAppearanceSettings: () => ({}),
    preferences: { async getPreferences() { return store; } }, materialFor: () => ({}), $r: value => value });
  const page = new DraftsPage(); page.visible = true;
  page.getUIContext = () => ({ getHostContext: () => ({}), showAlertDialog: options => dialogs.push(options) });
  page.onOpenDraft = target => opened.push(target);
  return { page, session, store, opened, dialogs };
}

test('draft page opening passes the exact saved route and pending delete confirmation cannot cross accounts', async () => {
  const state = pageRuntime(); await state.page.load(); const entry = state.page.entries[0];
  state.page.openDraft(entry); assert.deepEqual(state.opened, [repository.parseDraftTarget('draft_7_100_0_0', 7)]);
  state.page.confirmDelete(entry); assert.equal(state.dialogs.length, 1);
  state.session.user = { id: 8 }; state.session.revision++; state.page.visible = false; state.page.accountChanged();
  state.dialogs[0].secondaryButton.action(); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(state.store.deletes, []); assert.deepEqual(state.page.entries, []);
});

test('a delayed getAll response cannot repopulate old private draft rows after logout', async () => {
  const state = pageRuntime(); let release; state.store.getAll = () => new Promise(resolve => { release = resolve; });
  const loading = state.page.load(); await new Promise(resolve => setImmediate(resolve));
  state.session.user = undefined; state.session.revision++; state.page.accountChanged();
  release({ draft_7_100_0_0: 'Private late response' }); await loading;
  assert.deepEqual(state.page.entries, []); assert.equal(state.page.store, undefined);
});
