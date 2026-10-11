import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';

// Uses DevEco's existing TypeScript runtime; no npm install or alternate toolchain.
const require = createRequire(import.meta.url);
const sdkTypeScript = [
  process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(sdkTypeScript, 'DevEco SDK TypeScript is required; set DEVECO_TYPESCRIPT_PATH for another installation.');
const ts = require(sdkTypeScript);
const sourceRoot = fileURLToPath(new URL('../app/entry/src/main/ets/', import.meta.url));

function runtime(nativeResponse) {
  const modules = new Map();
  const nativeCalls = [];
  let destroyCount = 0;
  let nextFileId = 1;
  let nextUuid = 1;
  const files = new Map();
  const directories = new Set();
  const openFiles = new Map();
  const mediaSession = { user: undefined, revision: 0 };
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
    HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
    createHttp() {
      return {
        async request(url, options) {
          nativeCalls.push({ url, options });
          assert.ok(nativeResponse, 'Tests prohibit real network access.');
          return typeof nativeResponse === 'function' ? nativeResponse(url, options) : nativeResponse;
        },
        destroy() { destroyCount++; }
      };
    }
  };
  const webview = {
    WebCookieManager: {
      async fetchCookie() { return 'app_session=test_fixture'; },
      async configCookie() {},
      configCookieSync() {},
      async clearAllCookies() {}
    },
    WebviewController: { getDefaultUserAgent() { return 'fixture-only-webview'; } }
  };
  const fileIo = {
    OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
    async access(filePath) { return files.has(filePath) || directories.has(filePath); },
    async mkdir(directory) {
      const parts = directory.split('/');
      for (let index = 2; index <= parts.length; index++) { directories.add(parts.slice(0, index).join('/')); }
    },
    async rmdir(directory) {
      for (const filePath of files.keys()) { if (filePath.startsWith(directory + '/')) { files.delete(filePath); } }
      for (const filePath of directories) { if (filePath === directory || filePath.startsWith(directory + '/')) { directories.delete(filePath); } }
    },
    async open(filePath) { const fd = nextFileId++; openFiles.set(fd, filePath); return { fd }; },
    async write(fd, data) { files.set(openFiles.get(fd), data.slice(0)); return data.byteLength; },
    async close(file) { openFiles.delete(typeof file === 'number' ? file : file.fd); },
    async unlink(filePath) { files.delete(filePath); }
  };
  const arkts = {
    url: { URL },
    util: {
      generateRandomUUID() { return 'fixture-process-' + nextUuid++; },
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } }
    }
  };
  const cryptoFramework = {
    createMd(algorithm) {
      assert.equal(algorithm, 'SHA256');
      const digest = createHash('sha256');
      return { async update(blob) { digest.update(blob.data); }, async digest() { return { data: new Uint8Array(digest.digest()) }; } };
    }
  };
  function load(relativeName) {
    if (modules.has(relativeName)) { return modules.get(relativeName); }
    const source = readFileSync(path.join(sourceRoot, relativeName + '.ets'), 'utf8');
    const result = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    });
    const module = { exports: {} };
    modules.set(relativeName, module.exports);
    const dependency = id => {
      if (id === '@kit.NetworkKit') { return { http }; }
      if (id === '@kit.ArkWeb') { return { webview }; }
      if (id === '@kit.BasicServicesKit') { return {}; }
      if (id === '@kit.AbilityKit') { return {}; }
      if (id === '@kit.CoreFileKit') { return { fileIo, fileUri: { getUriFromPath(filePath) { return 'file://app.test' + filePath; } } }; }
      if (id === '@kit.ArkTS') { return arkts; }
      if (id === '@kit.CryptoArchitectureKit') { return { cryptoFramework }; }
      if (id.endsWith('/ForumSession')) { return { forumSession: mediaSession }; }
      if (id.startsWith('.')) { return load(path.normalize(path.join(path.dirname(relativeName), id))); }
      throw new Error('Unexpected test dependency: ' + id);
    };
    new Function('require', 'module', 'exports', result.outputText)(dependency, module, module.exports);
    modules.set(relativeName, module.exports);
    return module.exports;
  }
  return {
    models: load('models/ForumModels'), wire: load('services/ForumWire'), api: load('services/ForumApi'),
    nativeCalls, files, directories, openFiles, mediaSession, load,
    get destroyCount() { return destroyCount; }
  };
}

function browserApi(rt, respond) {
  const api = new rt.api.ForumApi();
  const requests = [];
  // Only pacing is removed: requests still run through production path checks,
  // response checks and mapping, with a local fixture transport replacing I/O.
  api.waitForSlot = async cancellation => {
    if (cancellation?.isCancelled) {
      throw new rt.api.ForumApiError(rt.api.ForumErrorKind.Cancelled, 0, '请求已取消');
    }
  };
  api.registerBrowserTransport(async (request, cancellation) => {
    requests.push(request);
    return respond(request, cancellation);
  });
  api.setBrowserTransportEnabled(true);
  return { api, requests };
}

function json(payload, status = 200, headers = {}) {
  return { status, body: JSON.stringify(payload), headers };
}

test('reaction toggles preserve official receipts, CSRF, undo state and exactly one PUT per action', async () => {
  const rt = runtime();
  let reacted = false;
  const { api, requests } = browserApi(rt, async request => {
    if (request.path === '/session/csrf.json') { return json({ csrf: 'fixture-only-csrf' }); }
    assert.equal(request.path, '/discourse-reactions/posts/71/custom-reactions/heart/toggle.json');
    reacted = !reacted;
    return json({ id: 71, topic_id: 42, post_number: 3, cooked: '<p>fixture post</p>',
      reactions: reacted ? [{ id: 'heart', type: 'emoji', count: 2 }] : [{ id: 'heart', count: 1 }],
      current_user_reaction: reacted ? { id: 'heart', type: 'emoji', can_undo: true } : null });
  });
  const selected = await api.toggleReaction(71, 'heart');
  assert.equal(selected.currentUserReaction.id, 'heart');
  assert.equal(selected.currentUserReaction.canUndo, true);
  assert.equal(selected.reactions[0].count, 2);
  const removed = await api.toggleReaction(71, 'heart');
  assert.equal(removed.currentUserReaction, undefined);
  assert.equal(removed.reactions[0].count, 1);
  const writes = requests.filter(request => request.method === 'PUT');
  assert.equal(writes.length, 2);
  assert.ok(writes.every(request => request.csrf === 'fixture-only-csrf' && request.body === ''));
  assert.equal(rt.nativeCalls.length, 0);
});

test('failed or unconfirmed reaction writes do not retry a toggle or return a fabricated selected state', async () => {
  for (const [response, kind] of [
    [json({ errors: ['fixture rejected'] }, 403), 'forbidden'],
    [json({ errors: ['fixture quota'] }, 429), 'rate_limited'],
    [json({ errors: ['fixture upstream error'] }, 502), 'unknown_result'],
    [json({ id: 72, reactions: [] }), 'unknown_result'],
    [json({ id: 71, reactions: [], current_user_reaction: null }), 'unknown_result'],
    [json({ id: 71, topic_id: 42, post_number: 3, cooked: '<p>fixture</p>', reactions: [] }), 'unknown_result'],
    [json({ success: 'OK' }), 'unknown_result'],
    [{ status: 200, body: 'not a post receipt', headers: {} }, 'unknown_result']
  ]) {
    const rt = runtime();
    const { api, requests } = browserApi(rt, async request => request.method === 'GET' ?
      json({ csrf: 'fixture-only-csrf' }) : response);
    await assert.rejects(() => api.toggleReaction(71, 'heart'), error => error.kind === kind);
    assert.equal(requests.filter(request => request.method === 'PUT').length, 1, 'A toggle cannot be retried automatically.');
  }
});

test('reaction cancellation during CSRF fetch cannot issue a write under a changed account', async () => {
  const rt = runtime();
  let release;
  const { api, requests } = browserApi(rt, () => new Promise(resolve => { release = resolve; }));
  const pending = api.toggleReaction(71, 'heart').then(value => ({ value }), error => ({ error }));
  await Promise.resolve();
  api.resetSessionContext();
  release(json({ csrf: 'old-account-fixture-only' }));
  assert.equal((await pending).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.filter(request => request.method === 'PUT').length, 0);
});

test('my liked posts use Discourse LIKE=1 activity and keep pagination separate from received-like notifications', async () => {
  const rt = runtime();
  const actions = Array.from({ length: 30 }, (_unused, index) => ({
    post_id: 100 + index, topic_id: 42, post_number: index + 1,
    title: 'Fixture &amp; title', excerpt: '<p>Liked excerpt</p>', action_type: 1, created_at: '2026-10-11T11:00:00Z'
  }));
  const { api, requests } = browserApi(rt, async request => request.path.startsWith('/user_actions.json') ?
    json({ user_actions: actions }) : json({ notifications: [] }));
  const page = await api.fetchProfile('fixture user', rt.models.ProfileSection.Likes, 2);
  const query = new URL('https://linux.do' + requests[0].path).searchParams;
  assert.equal(query.get('username'), 'fixture user');
  assert.equal(query.get('filter'), '1');
  assert.equal(query.get('offset'), '60');
  assert.equal(query.get('limit'), '30');
  assert.equal(page.nextCursor, 3);
  assert.equal(page.hasMore, true);
  assert.equal(page.entries[0].title, 'Fixture & title');
  assert.equal(page.entries[0].topicId, 42);
  assert.equal(page.entries[0].postNumber, 1);
  assert.match(page.entries[0].subtitle, /点赞.*Liked excerpt/);
  const refreshed = await api.fetchProfile('fixture user', rt.models.ProfileSection.Likes, 0);
  assert.equal(refreshed.entries[0].id, page.entries[0].id, 'Duplicate likes retain a stable key across refreshed offsets.');
  await api.fetchNotifications(0, rt.models.NotificationFilter.Likes);
  assert.ok(requests[2].path.startsWith('/notifications.json?'));
  assert.equal(requests[2].path.includes('user_actions'), false);
  assert.equal(rt.models.notificationFilters.find(item => item.value === rt.models.NotificationFilter.Likes).label, '收到的赞');
});

test('a missing liked-activity receipt is an error rather than a false empty history', async () => {
  const rt = runtime();
  const { api } = browserApi(rt, async () => json({ success: true }));
  await assert.rejects(() => api.fetchProfile('fixture-user', rt.models.ProfileSection.Likes),
    error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
});

test('native bodyless PUT and DELETE omit SDK-rejected empty extraData while nonempty JSON POST preserves its payload', async () => {
  const receipt = { id: 71, topic_id: 42, post_number: 3, cooked: '<p>fixture post</p>',
    reactions: [{ id: 'heart', count: 1 }], current_user_reaction: { id: 'heart', can_undo: true } };
  const rt = runtime((_url, options) => {
    // Official NetStack GetRequestBody rejects string.empty() before any I/O.
    if (options.extraData === '') { return Promise.reject({ code: 401 }); }
    return { responseCode: 200, header: {}, cookies: '', result: JSON.stringify(receipt) };
  });
  const api = new rt.api.ForumApi();
  api.waitForSlot = async () => {}; api.fetchCsrf = async () => 'fixture-only-csrf';
  await api.toggleReaction(71, 'heart');
  await api.deletePost(71);
  await api.createPost(42, 'fixture reply');
  assert.deepEqual(rt.nativeCalls.map(call => call.options.method), ['PUT', 'DELETE', 'POST']);
  for (const call of rt.nativeCalls.slice(0, 2)) {
    assert.equal(Object.hasOwn(call.options, 'extraData'), false, 'Bodyless writes must not reach the SDK with an empty string.');
    assert.equal(call.options.header['X-CSRF-Token'], 'fixture-only-csrf');
    assert.equal(call.options.maxRedirects, 0);
  }
  assert.deepEqual(JSON.parse(rt.nativeCalls[2].options.extraData), { raw: 'fixture reply', topic_id: 42 });
  assert.equal(rt.nativeCalls[2].options.header['X-CSRF-Token'], 'fixture-only-csrf');
  assert.equal(rt.destroyCount, 3);
});

test('SDK parameter error 401 is a local unsubmitted rejection, HTTP 401 remains authentication, and neither retries a toggle', async () => {
  const sdk = runtime(() => Promise.reject({ code: 401 }));
  const api = new sdk.api.ForumApi();
  api.waitForSlot = async () => {}; api.fetchCsrf = async () => 'fixture-only-csrf';
  await assert.rejects(() => api.toggleReaction(71, 'heart'), error =>
    error.kind === sdk.api.ForumErrorKind.Rejected && error.status === 0 && error.message.includes('未提交'));
  assert.equal(sdk.nativeCalls.length, 1);
  const http = runtime({ responseCode: 401, header: {}, cookies: '', result: '{"errors":["fixture unauthenticated"]}' });
  const second = new http.api.ForumApi();
  second.waitForSlot = async () => {}; second.fetchCsrf = async () => 'fixture-only-csrf';
  await assert.rejects(() => second.toggleReaction(71, 'heart'), error =>
    error.kind === http.api.ForumErrorKind.AuthenticationRequired && error.status === 401);
  assert.equal(http.nativeCalls.length, 1);
});

test('Linux.do object tags and standard Discourse string tags coexist', () => {
  const { wire } = runtime();
  const topic = wire.topicFromWire({
    id: 42, title: 'A &amp; B', tags: ['development', { id: 444, name: '人工智能' }], posts_count: 7
  });
  assert.deepEqual(topic.tags, ['development', '人工智能']);
  assert.equal(topic.title, 'A & B');
  assert.equal(topic.postsCount, 7);
  assert.equal(topic.categoryId, 0);
});

test('Discourse system author with signed ID maps into the feed alongside ordinary authors', async () => {
  const rt = runtime();
  const { api } = browserApi(rt, async () => json({
    topic_list: { topics: [
      { id: 42, title: 'System announcement', posters: [{ user_id: -1 }] },
      { id: 43, title: 'Community discussion', posters: [{ user_id: 7 }] }
    ] },
    users: [
      { id: -1, username: 'system', name: 'system', avatar_template: '/user_avatar/linux.do/system/{size}/1.png' },
      { id: 7, username: 'community' }
    ]
  }));
  const page = await api.fetchLatest();
  assert.deepEqual(page.items.map(item => item.authorUsername), ['system', 'community']);
  assert.equal(page.items[0].avatarUrl, 'https://linux.do/user_avatar/linux.do/system/144/1.png');
  assert.equal(rt.wire.userFromWire({ id: -1, username: 'system' }).id, -1);
});

test('signed user IDs still reject malformed numbers and content IDs remain strictly positive', () => {
  const { wire } = runtime();
  for (const id of [undefined, null, '1', 0, NaN, Infinity, -Infinity, 1.5, -1.5,
    Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1]) {
    assert.throws(() => wire.userFromWire({ id, username: 'invalid' }));
  }
  assert.equal(wire.userFromWire({ id: 7, username: 'community' }).id, 7);
  for (const id of [-1, 0, 1.5, NaN]) {
    assert.throws(() => wire.topicFromWire({ id, title: 'Invalid' }));
    assert.throws(() => wire.postFromWire({ id }));
    assert.throws(() => wire.categoryFromWire({ id, name: 'Invalid' }));
  }
});

test('nested category requests use the complete canonical parent slug path without redirects', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.path.startsWith('/categories.json')) {
      return json({ category_list: { categories: [{ id: 5, name: 'Development', slug: 'develop',
        subcategory_list: [{ id: 31, name: 'Development Lv2', slug: 'develop-lv2', parent_category_id: 5 }] }] } });
    }
    return json({ topic_list: { topics: [{ id: 42, title: 'Nested category topic', category_id: 31 }] } });
  });
  const page = await api.fetchCategoryTopics('stale-leaf-slug', 31, 0);
  assert.equal(page.items[0].category.id, 31);
  assert.deepEqual(requests.map(request => request.path), [
    '/categories.json?include_subcategories=true', '/c/develop/develop-lv2/31.json?page=0'
  ]);
  await api.fetchCategoryTopics('develop-lv2', 31, 1);
  assert.equal(requests.at(-1).path, '/c/develop/develop-lv2/31.json?page=1');
  assert.equal(requests.filter(request => request.path.startsWith('/categories.json')).length, 1, 'existing category cache is reused');
});

test('canonical category path encodes each Unicode slug independently and preserves path separators', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.path.startsWith('/categories.json')) {
      return json({ category_list: { categories: [
        { id: 1, name: '中文', slug: '开发 调优' },
        { id: 2, name: 'Child', slug: '移动&端', parent_category_id: 1 }
      ] } });
    }
    return json({ topic_list: { topics: [] } });
  });
  await api.fetchCategoryTopics('ignored', 2);
  assert.equal(requests.at(-1).path, `/c/${encodeURIComponent('开发 调优')}/${encodeURIComponent('移动&端')}/2.json?page=0`);
  assert.equal(requests.at(-1).path.includes('%2F'), false);
});

test('empty category slugs use Discourse id-category fallback for every parent and child segment', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.path.startsWith('/categories.json')) {
      return json({ category_list: { categories: [
        { id: 5, name: 'Parent without slug', slug: '' },
        { id: 31, name: 'Child without slug', slug: '', parent_category_id: 5 }
      ] } });
    }
    return json({ topic_list: { topics: [] } });
  });
  await api.fetchCategoryTopics('', 31);
  assert.equal(requests.at(-1).path, '/c/5-category/31-category/31.json?page=0');
});

test('unknown parent, cycle and excessive category depth fail before a category HTTP request', async () => {
  const fixtures = [
    [{ id: 31, name: 'Missing parent', slug: 'child', parent_category_id: 99 }],
    [{ id: 31, name: 'First', slug: 'first', parent_category_id: 32 },
      { id: 32, name: 'Second', slug: 'second', parent_category_id: 31 }],
    Array.from({ length: 18 }, (_, index) => ({ id: index + 1, name: 'Deep', slug: 'depth-' + index,
      parent_category_id: index === 0 ? 0 : index }))
  ];
  for (let index = 0; index < fixtures.length; index++) {
    const rt = runtime();
    const { api, requests } = browserApi(rt, async () => json({ category_list: { categories: fixtures[index] } }));
    const id = index === 2 ? 18 : 31;
    await assert.rejects(() => api.fetchCategoryTopics('child', id), error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
    assert.equal(requests.length, 1);
    assert.ok(requests[0].path.startsWith('/categories.json'));
  }
});

test('session reset during canonical category bootstrap cannot issue an old-account category request', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ topic_list: { topics: [] } }));
  let release;
  api.fetchCategories = () => new Promise(resolve => { release = resolve; });
  const outcome = api.fetchCategoryTopics('develop-lv2', 31).then(value => ({ value }), error => ({ error }));
  api.resetSessionContext();
  release([rt.wire.categoryFromWire({ id: 31, name: 'Lv2', slug: 'develop-lv2' })]);
  assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.length, 0);
});

test('SDK redirect-limit error offers verification for GET and never retries a write', async () => {
  const rt = runtime(() => Promise.reject({ code: 2300047 }));
  const api = new rt.api.ForumApi(); api.waitForSlot = async () => {};
  await assert.rejects(() => api.fetchLatest(), error => error.kind === rt.api.ForumErrorKind.VerificationRequired);
  api.fetchCsrf = async () => 'fixture-csrf';
  await assert.rejects(() => api.createPost(42, 'fixture reply'), error => error.kind === rt.api.ForumErrorKind.UnknownResult);
  assert.equal(rt.nativeCalls.length, 2, 'exactly one native request per user action, no redirect retry');
  assert.equal(rt.nativeCalls[0].options.maxRedirects, 0);
  assert.equal(rt.nativeCalls[1].options.maxRedirects, 0);
});

test('nested categories retain parent relations and flatten without duplicates', () => {
  const { wire, models } = runtime();
  const parent = wire.categoryFromWire({
    id: 1, name: '开发调优', color: '0088CC',
    subcategory_list: [{ id: 2, name: '开发调优, Lv1', parent_category_id: 1 }]
  });
  const flat = models.flattenCategories([parent, parent.subcategoryList[0]]);
  assert.deepEqual(flat.map(category => category.id), [1, 2]);
  assert.equal(flat[1].parentCategoryId, 1);
  assert.equal(parent.color, '0088CC');
});

test('missing or malformed permissions fail closed; closed topics cannot reply', () => {
  const { wire } = runtime();
  const missing = wire.detailFromWire({ id: 3, title: 'Thread', post_stream: {} });
  assert.equal(missing.details.canCreatePost, false);
  assert.equal(missing.canReply, false);
  assert.equal(wire.detailFromWire({
    id: 3, title: 'Thread', post_stream: {}, details: { can_create_post: true }
  }).canReply, true);
  for (const restriction of [{ closed: true }, { archived: true }]) {
    assert.equal(wire.detailFromWire({
      id: 3, title: 'Thread', post_stream: {}, details: { can_create_post: true }, ...restriction
    }).canReply, false);
  }
  const post = wire.postFromWire({ id: 10, can_edit: 'true', can_delete: 'yes' });
  assert.equal(post.canEdit, false);
  assert.equal(post.canDelete, false);
  assert.equal(post.canBoost, false);
  assert.equal(post.canAcceptAnswer, false);
});

test('empty post streams are valid and only safe positive integer IDs survive', () => {
  const { wire } = runtime();
  assert.deepEqual(wire.streamFromWire({ posts: [], stream: [] }), { posts: [], stream: [] });
  assert.deepEqual(wire.streamFromWire({ stream: [1, -1, 0, 1.5, '2', NaN, Infinity, 3] }).stream, [1, 3]);
  assert.throws(() => wire.postFromWire({ id: 0 }));
  assert.throws(() => wire.topicFromWire({ id: Number.MAX_SAFE_INTEGER + 1, title: 'Broken' }));
  assert.throws(() => wire.decodeObject('null'));
  assert.throws(() => wire.decodeObject('[]'));
  assert.throws(() => wire.decodeArray('{}'));
});

test('stream pagination preserves source paths, requested IDs and empty responses', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ post_stream: { posts: [] } }));
  assert.deepEqual(await api.fetchPosts(8, [91, 92]), []);
  assert.equal(requests[0].path, '/t/8/posts.json?post_ids%5B%5D=91&post_ids%5B%5D=92&track_visit=false');
  await assert.rejects(() => api.fetchPosts(8, []));
  await assert.rejects(() => api.fetchPosts(8, Array.from({ length: 21 }, (_, index) => index + 1)));
  await assert.rejects(() => api.fetchPosts(8, [-1]));
  assert.equal(requests.length, 1, 'invalid requests are rejected before transport');
});

test('notification filtering advances server offset by limit despite removed or nonmatching rows', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    const offset = Number(/offset=(\d+)/.exec(request.path)[1]);
    return json({ total_rows_notifications: 120, notifications: [{
      id: offset + 1, notification_type: offset === 0 ? 5 : 2, read: false,
      data: { topic_title: 'Reply', display_username: 'friend' }
    }] });
  });
  const page = await api.fetchNotifications(0, rt.models.NotificationFilter.Replies);
  assert.deepEqual(page.notifications.map(notice => notice.type), [2]);
  assert.equal(page.nextOffset, 120);
  assert.equal(page.hasMore, false);
  assert.ok(requests[0].path.includes('filter_by_types=mentioned%2Creplied'));
  assert.ok(requests[1].path.includes('offset=60'));
});

test('bell unread count excludes likes while category unread counts include them', async () => {
  const rt = runtime();
  const { api } = browserApi(rt, async () => json({ total_rows_notifications: 3, notifications: [
    { id: 1, notification_type: 5, read: false },
    { id: 2, notification_type: 2, read: false },
    { id: 3, notification_type: 6, read: true }
  ] }));
  const summary = await api.fetchUnreadSummary();
  assert.equal(summary.count, 1);
  assert.equal(summary.unreadByFilter.get(rt.models.NotificationFilter.All), 2);
  assert.equal(summary.unreadByFilter.get(rt.models.NotificationFilter.Likes), 1);
  assert.equal(summary.unreadByFilter.get(rt.models.NotificationFilter.Messages), 0);
});

test('repeating unread pages cannot produce an inflated count or infinite loop', async () => {
  const rt = runtime();
  const { api } = browserApi(rt, async () => json({ total_rows_notifications: 120, notifications: [
    { id: 1, notification_type: 2, read: false }
  ] }));
  await assert.rejects(() => api.fetchUnreadSummary(), error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
});

test('boost limits count Unicode emoji sequences, flags and shortcodes separately from visible text', () => {
  const { models } = runtime();
  assert.equal(models.measureBoost('字'.repeat(16)).submittable, true);
  assert.equal(models.measureBoost('字'.repeat(17)).submittable, false);
  assert.deepEqual(models.measureBoost('🇨🇳👨‍👩‍👧‍👦👍🏽:smile:'), { visible: 0, emoji: 4, submittable: true });
  assert.equal(models.measureBoost('😀'.repeat(5)).submittable, true);
  assert.equal(models.measureBoost('😀'.repeat(6)).submittable, false);
  assert.equal(models.measureBoost(':smile:'.repeat(6)).submittable, false);
  assert.equal(models.measureBoost('   ').submittable, false);
});

test('upload markdown retains Discourse upload shortcodes and sanitizes display names', () => {
  const { models } = runtime();
  assert.equal(models.uploadedFileMarkdown({ fileName: 'diagram.png', shortUrl: 'upload://abc.png', width: 120, height: 80 }),
    '![diagram.png|120x80](upload://abc.png)');
  assert.equal(models.uploadedFileMarkdown({ fileName: 'note.pdf', shortUrl: 'upload://abc.pdf', width: 0, height: 0 }),
    '[note.pdf|attachment](upload://abc.pdf)');
  assert.equal(models.uploadedFileMarkdown({ fileName: '[bad]|\n.md', shortUrl: 'upload://abc.md', width: 0, height: 0 }),
    '[_bad___.md|attachment](upload://abc.md)');
});

test('forum URL helper blocks alternate schemes, hostile authority and ambiguous separators', () => {
  const { models } = runtime();
  assert.equal(models.safeForumUrl('/t/topic/123'), 'https://linux.do/t/topic/123');
  assert.equal(models.safeForumUrl('https://linux.do/t/123'), 'https://linux.do/t/123');
  for (const value of ['', '//evil.example/a', 'http://linux.do/a', 'https://linux.do.evil.example/a',
    'https://linux.do@evil.example/a', 'https://linux.do:443/a', 'javascript:alert(1)', '/\\evil.example/a',
    '/a\r\nCookie:secret']) {
    assert.equal(models.safeForumUrl(value), '', value);
  }
});

test('write payloads and two-factor method match the source without sending any server request', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.path === '/session/csrf.json') { return json({ csrf: 'fixture-csrf' }); }
    if (request.path === '/posts.json') { return json({ id: 42, post_number: 2, topic_id: 9 }); }
    if (request.path === '/posts/42.json' && request.method === 'PUT') { return json({ post: { id: 42, raw: 'edited' } }); }
    if (request.path === '/session.json') { return json({ totp_enabled: true, backup_enabled: true }); }
    return json({});
  });
  assert.equal((await api.createPost(9, ' reply ', 2)).id, 42);
  const create = requests.find(request => request.path === '/posts.json');
  assert.deepEqual(JSON.parse(create.body), { topic_id: 9, raw: 'reply', reply_to_post_number: 2 });
  assert.equal(create.csrf, 'fixture-csrf');
  assert.equal((await api.updatePost(42, 'edited')).raw, 'edited');
  await api.deletePost(42);
  assert.equal(requests.at(-1).method, 'DELETE');
  await assert.rejects(() => api.loginWithPassword('demo', 'fixture-password'), error =>
    error.kind === rt.api.ForumErrorKind.SecondFactorRequired && error.totpEnabled && error.backupEnabled);
  assert.equal(JSON.parse(requests.at(-1).body).second_factor_method, 1);
});

test('HTTP status and cancellation distinctions remain actionable', async () => {
  const rt = runtime();
  const cases = [
    [401, {}, {}, rt.api.ForumErrorKind.AuthenticationRequired],
    [403, {}, {}, rt.api.ForumErrorKind.Forbidden],
    [429, {}, { 'retry-after': '60' }, rt.api.ForumErrorKind.RateLimited],
    [503, {}, { 'cf-mitigated': 'challenge' }, rt.api.ForumErrorKind.VerificationRequired]
  ];
  for (const [status, body, headers, expected] of cases) {
    const { api } = browserApi(rt, async () => json(body, status, headers));
    await assert.rejects(() => api.fetchLatest(), error => error.kind === expected && error.status === status);
  }
  const { api, requests } = browserApi(rt, async () => json({}));
  const cancellation = new rt.api.RequestCancellation(); cancellation.cancel();
  await assert.rejects(() => api.fetchLatest(0, cancellation), error => error.kind === rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.length, 0);
});

test('native multipart is bounded, disables redirects and releases the request', async () => {
  const rt = runtime({ responseCode: 200, header: {}, cookies: '', result: JSON.stringify({
    short_url: 'upload://fixture.png', original_filename: 'fixture.png', width: 10, height: 10
  }) });
  const api = new rt.api.ForumApi(); api.waitForSlot = async () => {}; api.fetchCsrf = async () => 'fixture-csrf';
  await assert.rejects(() => api.uploadFile('fixture.png', 'image/png', new ArrayBuffer(0)));
  await assert.rejects(() => api.uploadFile('fixture.png', 'image/png', new ArrayBuffer(4 * 1024 * 1024 + 1)));
  const result = await api.uploadFile('fixture.png', 'image/png', new Uint8Array([1, 2]).buffer);
  assert.equal(result.shortUrl, 'upload://fixture.png');
  assert.equal(rt.nativeCalls.length, 1);
  const { url, options } = rt.nativeCalls[0];
  assert.equal(url, 'https://linux.do/uploads.json');
  assert.equal(options.maxRedirects, 0);
  assert.equal(options.multiFormDataList[2].name, 'files[]');
  assert.equal(options.header['X-CSRF-Token'], 'fixture-csrf');
  assert.equal(rt.destroyCount, 1);
});

test('owner reset cancels stale category responses without clearing the new owner in-flight cache', async () => {
  const rt = runtime();
  const releases = [];
  const signals = [];
  let firstStarted;
  const started = new Promise(resolve => { firstStarted = resolve; });
  const { api, requests } = browserApi(rt, (request, cancellation) => {
    assert.equal(request.path, '/categories.json?include_subcategories=true');
    signals.push(cancellation);
    return new Promise(resolve => {
      releases.push(resolve);
      if (releases.length === 1) { firstStarted(); }
    });
  });
  const oldOutcome = api.fetchCategories().then(value => ({ value }), error => ({ error }));
  await started;
  api.resetSessionContext();
  assert.equal(signals[0].isCancelled, true);
  assert.deepEqual(api.cachedCategories(), []);
  const fresh = api.fetchCategories();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(requests.length, 2, 'fresh account starts a distinct category request');
  releases[0](json({ category_list: { categories: [{ id: 1, name: 'Old private category' }] } }));
  const old = await oldOutcome;
  assert.equal(old.error.kind, rt.api.ForumErrorKind.Cancelled);
  const sharedFresh = api.fetchCategories();
  await Promise.resolve();
  assert.equal(requests.length, 2, 'old finally cannot clear the new owner in-flight request');
  releases[1](json({ category_list: { categories: [{ id: 2, name: 'New private category' }] } }));
  assert.deepEqual((await fresh).map(category => category.id), [2]);
  assert.deepEqual((await sharedFresh).map(category => category.id), [2]);
  assert.deepEqual(api.cachedCategories().map(category => category.id), [2]);
  assert.equal(rt.nativeCalls.length, 0, 'browser registration and enabled setting survive reset');
});

test('owner reset cancels requests still queued by the source request interval', async () => {
  const rt = runtime();
  const api = new rt.api.ForumApi();
  let dispatched = false;
  api.registerBrowserTransport(async () => { dispatched = true; return json({}); });
  api.setBrowserTransportEnabled(true);
  api.nextRequestAt = Date.now() + 60000;
  const queuedOutcome = api.fetchLatest().then(value => ({ value }), error => ({ error }));
  await Promise.resolve();
  api.resetSessionContext();
  const queued = await queuedOutcome;
  assert.equal(queued.error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(dispatched, false);
});

test('owner reset between CSRF and submission prevents a write under the new account', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ id: 42 }));
  let releaseCsrf;
  api.fetchCsrf = () => new Promise(resolve => { releaseCsrf = resolve; });
  const outcome = api.createPost(9, 'old-account draft').then(value => ({ value }), error => ({ error }));
  api.resetSessionContext();
  releaseCsrf('old-account-csrf');
  assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.length, 0);
});

function gifResponse() {
  return { responseCode: 200, header: { 'content-type': 'image/gif' }, cookies: '',
    result: new Uint8Array([71, 73, 70, 56, 57, 97, 1, 0, 1, 0]).buffer };
}

test('shared media keeps GIF bytes and sends app cookie only to exact Linux.do HTTPS origin', async () => {
  const rt = runtime(gifResponse());
  const media = rt.load('services/ForumMedia');
  rt.api.forumApi.setUserAgent('same-app-web-ua');
  const context = { cacheDir: '/app-cache' };
  const uri = await media.loadForumMedia('https://linux.do/private.gif?token=fixture-sensitive-value', context);
  assert.ok(uri.startsWith('file://app.test/app-cache/forum-media/'));
  assert.ok(uri.includes('/owner-0/generation-0/'));
  assert.equal(uri.includes('fixture-sensitive-value'), false);
  assert.equal(uri.includes('private.gif'), false);
  assert.equal(rt.nativeCalls[0].options.header.Cookie, 'app_session=test_fixture');
  assert.equal(rt.nativeCalls[0].options.header['User-Agent'], 'same-app-web-ua');
  assert.equal(rt.nativeCalls[0].options.maxRedirects, 0);
  assert.equal(rt.nativeCalls[0].options.maxLimit, 20 * 1024 * 1024);
  assert.equal(rt.nativeCalls[0].options.header['X-CSRF-Token'], undefined);
  assert.deepEqual(Array.from(new Uint8Array([...rt.files.values()][0])), [71, 73, 70, 56, 57, 97, 1, 0, 1, 0]);
  await media.loadForumMedia('https://cdn.example.invalid/public.gif', context);
  await media.loadForumMedia('https://linux.do.evil.example.invalid/public.gif', context);
  assert.equal(rt.nativeCalls[1].options.header.Cookie, undefined);
  assert.equal(rt.nativeCalls[2].options.header.Cookie, undefined);
  assert.equal(rt.openFiles.size, 0, 'all cache file descriptors are closed');
  assert.equal(rt.destroyCount, 3, 'all HTTP media requests are released');
});

test('media cache and promise are isolated by owner and generation even when current user is still unknown', async () => {
  const rt = runtime(gifResponse());
  const media = rt.load('services/ForumMedia');
  const context = { cacheDir: '/app-cache' };
  const url = 'https://linux.do/possibly-private.gif';
  const initial = await media.loadForumMedia(url, context);
  assert.equal(await media.loadForumMedia(url, context), initial);
  assert.equal(rt.nativeCalls.length, 1);
  rt.api.forumApi.resetSessionContext();
  const afterReset = await media.loadForumMedia(url, context);
  assert.notEqual(afterReset, initial);
  assert.ok(afterReset.includes('/owner-0/generation-1/'));
  assert.equal(rt.nativeCalls.length, 2, 'guest owner zero cannot reuse a previous authenticated-unknown response');
  rt.mediaSession.user = { id: 7 };
  rt.api.forumApi.resetSessionContext();
  const otherOwner = await media.loadForumMedia(url, context);
  assert.ok(otherOwner.includes('/owner-7/generation-2/'));
  assert.equal(rt.nativeCalls.length, 3);
  assert.equal(rt.files.size, 1, 'previous scope files are invalidated');
});

test('media consumers share one request and cancelling one does not cancel the others', async () => {
  let release;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  const rt = runtime(() => new Promise(resolve => { release = resolve; started(); }));
  const media = rt.load('services/ForumMedia');
  const context = { cacheDir: '/app-cache' };
  const cancellation = new rt.api.RequestCancellation();
  const cancelledOutcome = media.loadForumMedia('https://linux.do/shared.gif', context, cancellation)
    .then(value => ({ value }), error => ({ error }));
  const other = media.loadForumMedia('https://linux.do/shared.gif', context);
  await startedPromise;
  cancellation.cancel();
  assert.equal((await cancelledOutcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(rt.destroyCount, 0, 'another consumer still owns the native request');
  release(gifResponse());
  assert.ok((await other).startsWith('file://'));
  assert.equal(rt.nativeCalls.length, 1);
  assert.equal(rt.destroyCount, 1);
});

test('owner reset cancels in-flight media and stale responses cannot write files', async () => {
  let release;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  const rt = runtime(() => new Promise(resolve => { release = resolve; started(); }));
  const media = rt.load('services/ForumMedia');
  const outcome = media.loadForumMedia('https://linux.do/old-private.gif', { cacheDir: '/app-cache' })
    .then(value => ({ value }), error => ({ error }));
  await startedPromise;
  rt.api.forumApi.resetSessionContext();
  assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  release(gifResponse());
  await Promise.resolve();
  assert.equal(rt.files.size, 0);
  assert.equal(rt.openFiles.size, 0);
  assert.ok(rt.destroyCount >= 1);
});

test('media rejects HTTP, redirect, challenge HTML and excessive responses before caching', async () => {
  const cases = [
    { responseCode: 302, header: { location: 'https://evil.example.invalid/a.gif' }, result: new ArrayBuffer(1) },
    { responseCode: 403, header: { 'cf-mitigated': 'challenge' }, result: new ArrayBuffer(1) },
    { responseCode: 200, header: { 'content-type': 'text/html' }, result: new ArrayBuffer(1) },
    { responseCode: 200, header: { 'content-type': 'image/png' }, result: new ArrayBuffer(20 * 1024 * 1024 + 1) }
  ];
  for (const response of cases) {
    const rt = runtime(response);
    const media = rt.load('services/ForumMedia');
    const context = { cacheDir: '/app-cache' };
    await assert.rejects(() => media.loadForumMedia('http://linux.do/a.gif', context));
    assert.equal(rt.nativeCalls.length, 0);
    await assert.rejects(() => media.loadForumMedia('https://linux.do/a.gif', context));
    assert.equal(rt.files.size, 0);
    assert.equal(rt.destroyCount, 1);
  }
});
