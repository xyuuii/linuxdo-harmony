import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// Execute the production mutation handler with a local-only transport. No forum
// write is sent, and success must come from its actual receipt rather than an
// optimistic client count. Native feedback rendering is checked on the device.
const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'The fixture compiler is required.');
const ts = require(compiler);
const source = readFileSync(new URL('../app/entry/src/main/ets/pages/TopicPage.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async react(');
const end = source.indexOf('  private async solution(', start);
assert.ok(start >= 0 && end > start);
const primaryGetter = /  get primaryReaction\(\): string \{[\s\S]*?\n  \}/.exec(source);
assert.ok(primaryGetter, 'The production primary-reaction choice must remain extractable.');
const production = ts.transpileModule('export class ReactionHarness {\n' + primaryGetter[0] + '\n' + source.slice(start, end) + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
class ForumApiError extends Error { constructor(kind, message) { super(message); this.kind = kind; } }
const ForumErrorKind = { Cancelled: 'cancelled', UnknownResult: 'unknown_result', RateLimited: 'rate_limited' };

function harness(respond) {
  const requests = [];
  const messages = [];
  const merged = [];
  const token = { isCancelled: false };
  const module = { exports: {} };
  const api = { async toggleReaction(...args) { requests.push(args); return respond(...args); } };
  new Function('module', 'exports', 'forumApi', 'ForumApiError', 'ForumErrorKind', 'failureMessage', production)
    (module, module.exports, api, ForumApiError, ForumErrorKind, error => error.message);
  const page = new module.exports.ReactionHarness();
  Object.assign(page, { generation: 4, writeBusy: false, hidden: false, error: '', signedIn: () => true,
    startWrite: () => token, endWrite: () => { page.writeBusy = false; },
    mergePosts: posts => merged.push(...posts), getUIContext: () => ({
      getPromptAction: () => ({ showToast: options => messages.push(options.message) })
    }) });
  return { page, requests, messages, merged, token };
}

test('the primary button undoes the selected emoji instead of replacing it with a heart', () => {
  const rt = harness(async () => { throw new Error('No write is needed for a primary-choice fixture.'); });
  rt.page.post = { id: 71, currentUserReaction: undefined };
  assert.equal(rt.page.primaryReaction, 'heart');
  rt.page.post = { id: 71, currentUserReaction: { id: 'laughing', canUndo: true } };
  assert.equal(rt.page.primaryReaction, 'laughing');
  rt.page.post = { id: 71, currentUserReaction: { id: 'heart', canUndo: true } };
  assert.equal(rt.page.primaryReaction, 'heart');
  assert.equal(rt.requests.length, 0);
});

test('successful reactions visibly confirm only the returned server state, and undo confirms removal', async () => {
  const selected = { id: 71, reactions: [{ id: 'heart', count: 9 }],
    currentUserReaction: { id: 'heart', canUndo: true } };
  const first = harness(async () => selected);
  await first.page.react({ id: 71, yours: false }, 'heart');
  assert.deepEqual(first.messages, ['已喜欢']);
  assert.deepEqual(first.merged, [selected]);
  assert.equal(first.page.writeBusy, false);
  const second = harness(async () => ({ ...selected, currentUserReaction: undefined }));
  await second.page.react(selected, 'heart');
  assert.deepEqual(second.messages, ['已取消回应']);
  assert.equal(second.requests.length, 1);
});

test('rate-limit and uncertain receipts give immediate feedback without retrying or fabricating likes', async () => {
  for (const kind of [ForumErrorKind.RateLimited, ForumErrorKind.UnknownResult]) {
    const rt = harness(async () => { throw new ForumApiError(kind, 'Fixture: check the current server state.'); });
    await rt.page.react({ id: 71, yours: false }, 'heart');
    assert.deepEqual(rt.messages, ['Fixture: check the current server state.']);
    assert.equal(rt.requests.length, 1);
    assert.equal(rt.merged.length, 0);
    assert.equal(rt.page.writeBusy, false);
  }
});

test('busy or irreversible reactions never submit, and stale, hidden or cancelled receipts cannot show feedback', async () => {
  for (const gate of [
    { busy: true, post: { id: 71 } }, { busy: false, post: { id: 71, yours: true } },
    { busy: false, post: { id: 71, currentUserReaction: { id: 'heart', canUndo: false } } }
  ]) {
    const rt = harness(async () => { throw new Error('Writes are prohibited by this gate.'); });
    rt.page.writeBusy = gate.busy;
    await rt.page.react(gate.post, 'heart');
    assert.equal(rt.requests.length, 0);
  }
  for (const change of ['generation', 'hidden', 'cancelled']) {
    let release;
    const rt = harness(() => new Promise(resolve => { release = resolve; }));
    const pending = rt.page.react({ id: 71, yours: false }, 'heart');
    if (change === 'generation') { rt.page.generation++; }
    if (change === 'hidden') { rt.page.hidden = true; }
    if (change === 'cancelled') { rt.token.isCancelled = true; }
    release({ id: 71, currentUserReaction: { id: 'heart', canUndo: true } });
    await pending;
    assert.equal(rt.messages.length, 0);
    assert.equal(rt.merged.length, 0);
  }
  const cancelled = harness(async () => { throw new ForumApiError(ForumErrorKind.Cancelled, 'cancelled'); });
  await cancelled.page.react({ id: 71 }, 'heart');
  assert.equal(cancelled.messages.length, 0);
});
