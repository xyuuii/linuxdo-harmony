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

test('animated avatar metadata preserves the explicit GIF and WebP upload for feed and post authors', async () => {
  const rt = runtime();
  const template = '/user_avatar/linux.do/animated/{size}/9.png';
  const { api } = browserApi(rt, async () => json({
    topic_list: { topics: [{ id: 42, title: 'Animated author', posters: [{ user_id: 7 }] }] },
    users: [{ id: 7, username: 'animated', avatar_template: template,
      animated_avatar: '/uploads/default/original/1X/animated.gif' }]
  }));
  const page = await api.fetchLatest();
  assert.equal(page.items[0].avatarUrl, 'https://linux.do/uploads/default/original/1X/animated.gif');
  const post = rt.wire.postFromWire({ id: 71, avatar_template: template,
    animated_avatar: '//cdn.example.test/original/animated.webp?version=2#preview' });
  assert.equal(post.avatarUrl, 'https://cdn.example.test/original/animated.webp?version=2#preview');
  assert.equal(post.avatarTemplate, template);
});

test('avatar uploads require valid GIF or WebP metadata and retain static or existing animated templates as fallback', () => {
  const { models, wire } = runtime();
  const template = '/user_avatar/linux.do/fixture/{size}/9.png?version=2#avatar';
  const staticUrl = 'https://linux.do/user_avatar/linux.do/fixture/72/9.png?version=2#avatar';
  for (const metadata of ['', '/uploads/static.png', '/uploads/static.png?name=animated.gif', '/uploads/animated.gif/not-an-image']) {
    assert.equal(models.avatarUrlOf(template, 72, metadata), staticUrl);
  }
  assert.equal(models.avatarUrlOf(template, 72, '/uploads/ANIMATED.WEBP?version=3'),
    'https://linux.do/uploads/ANIMATED.WEBP?version=3');
  assert.equal(wire.userFromWire({ id: 7, username: 'fixture', avatar_template: template, animated_avatar: null }).avatarUrl,
    'https://linux.do/user_avatar/linux.do/fixture/144/9.png?version=2#avatar');
  assert.equal(models.avatarUrlOf('', 72, '/uploads/animated.gif'), 'https://linux.do/uploads/animated.gif');
  const notification = wire.notificationFromWire({ id: 1,
    acting_user_avatar_template: '//cdn.example.test/avatars/{size}/9.gif' });
  assert.equal(notification.avatarUrl, 'https://cdn.example.test/avatars/144/9.gif');
});

test('animated avatar URL validation rejects unsafe metadata without guessing a different static avatar suffix', () => {
  const { models } = runtime();
  const template = '/user_avatar/linux.do/fixture/{size}/9.png';
  for (const metadata of [
    'http://cdn.example.test/a.gif', 'ftp://cdn.example.test/a.gif', 'javascript:fixture.gif',
    'data:image/gif;base64,fixture', 'https://user:secret@cdn.example.test/a.gif',
    '//user@cdn.example.test/a.webp', 'https://cdn.example.test:8443/a.gif',
    'https:///cdn.example.test/a.gif', '///cdn.example.test/a.gif',
    'https://cdn.example.test/a.gif\n', 'https://cdn.example.test/\u0000a.gif',
    'https://cdn.example.test\\a.gif', 'https://cdn.example.test/static.png?name=animated.gif'
  ]) {
    assert.equal(models.avatarUrlOf(template, 72, metadata), 'https://linux.do/user_avatar/linux.do/fixture/72/9.png');
  }
  assert.equal(models.avatarUrlOf(template, 72, 'HTTPS://cdn.example.test:443/a.gif?version=2'),
    'https://cdn.example.test:443/a.gif?version=2');
  assert.equal(models.avatarUrlOf('javascript:fixture.png', 72, 'http://cdn.example.test/a.gif'), '');
});

test('home filters use their own Discourse routes and keep the weekly top period across pagination', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => json({
    topic_list: { topics: [{ id: 42, title: request.path }], more_topics_url: '/next' }
  }));
  for (const option of rt.models.topicFeedFilters) {
    const page = await api.fetchTopicFeed(option.value, 2);
    const expected = `/${option.value}.json?page=2${option.value === 'top' ? '&period=weekly' : ''}`;
    assert.equal(requests.at(-1).path, expected);
    assert.equal(page.items[0].topic.title, expected); assert.equal(page.hasMore, true);
  }
  await api.fetchTopicFeed(rt.models.TopicFeedFilter.Top, 3);
  assert.equal(requests.at(-1).path, '/top.json?page=3&period=weekly');
  const before = requests.length;
  await assert.rejects(() => api.fetchTopicFeed('../admin'), error => error.kind === rt.api.ForumErrorKind.Rejected);
  await assert.rejects(() => api.fetchTopicFeed('latest', -1));
  assert.equal(requests.length, before);
});

test('unsupported and login-required feeds surface the server outcome instead of returning latest topics', async () => {
  const rt = runtime();
  const unavailable = browserApi(rt, async () => ({ status: 404, body: '{}', headers: {} }));
  await assert.rejects(() => unavailable.api.fetchTopicFeed('hot'),
    error => error.kind === rt.api.ForumErrorKind.Unsupported && error.message.includes('暂未开放'));
  assert.equal(unavailable.requests.length, 1); assert.equal(unavailable.requests[0].path, '/hot.json?page=0');
  const anonymous = browserApi(rt, async () => ({ status: 401, body: '{}', headers: {} }));
  await assert.rejects(() => anonymous.api.fetchTopicFeed('unread'),
    error => error.kind === rt.api.ForumErrorKind.AuthenticationRequired);
  assert.equal(anonymous.requests.length, 1); assert.equal(anonymous.requests[0].path, '/unread.json?page=0');
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

test('topic lists and search show all replies rather than explicit reply relationships', () => {
  const { wire } = runtime();
  assert.equal(wire.topicFromWire({ id: 3, title: 'Thread', posts_count: 1640, reply_count: 166 }).replyCount, 1639);
  assert.equal(wire.topicFromWire({ id: 3, title: 'Thread', posts_count: 1, reply_count: 0 }).replyCount, 0);
  assert.equal(wire.topicFromWire({ id: 3, title: 'Thread', posts_count: 0, reply_count: 4 }).replyCount, 0);
  assert.equal(wire.topicFromWire({ id: 3, title: 'Thread', reply_count: 166 }).replyCount, 166,
    'Older list payloads without posts_count keep their only available count.');
  assert.equal(wire.topicFromWire({ id: 3, title: 'Thread' }).replyCount, 0);
});

test('topic detail keeps real tags, reply count and highest floor with compatible missing metadata', () => {
  const { wire } = runtime();
  const detail = wire.detailFromWire({
    id: 3, title: 'Thread', category_id: 8, tags: ['软件开发', { name: '开源' }, '软件开发', null, {}, ''],
    posts_count: 40, reply_count: 4, highest_post_number: 43,
    post_stream: { stream: [10, 11], posts: [{ id: 10, post_number: 1 }, { id: 11, post_number: 42 }] }
  });
  assert.deepEqual(detail.tags, ['软件开发', '开源']);
  assert.equal(detail.categoryId, 8);
  assert.equal(detail.replyCount, 39, 'All replies use posts_count minus the original, not explicit reply relationships.');
  assert.equal(detail.highestPostNumber, 43, 'Deleted floors must not make the denominator smaller than a real floor.');
  const fallback = wire.detailFromWire({ id: 3, title: 'Thread', reply_count: 166, post_stream: {
    stream: [10, 11], posts: [{ id: 11, post_number: 42 }]
  } });
  assert.deepEqual(fallback.tags, []);
  assert.equal(fallback.replyCount, 1);
  assert.equal(fallback.highestPostNumber, 42);
  const empty = wire.detailFromWire({ id: 3, title: 'Thread', post_stream: {} });
  assert.equal(empty.replyCount, 0);
  assert.equal(empty.highestPostNumber, 0);
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
  assert.equal(requests[0].path.includes('filter_by_types'), false, 'history does not support server type filtering');
  assert.ok(requests[1].path.includes('offset=60'));
});

test('notification categories retain read and unread matches and return the first useful page', async () => {
  const rt = runtime();
  const notices = [1, 2, 3, 5, 6, 7, 15, 16, 19, 25, 33, 43, 12].map((type, index) => ({
    id: index + 1, notification_type: type, read: index % 2 === 0,
    topic_id: 42, post_number: index + 1, data: { topic_title: 'Fixture notification' }
  }));
  const { api, requests } = browserApi(rt, async () => json({
    notifications: notices, total_rows_notifications: 600
  }));
  for (const [filter, types] of [
    [rt.models.NotificationFilter.All, notices.map(notice => notice.notification_type)],
    [rt.models.NotificationFilter.Replies, [1, 2, 3, 15, 33, 43]],
    [rt.models.NotificationFilter.Likes, [5, 19, 25]],
    [rt.models.NotificationFilter.Messages, [6, 7, 16]]
  ]) {
    const before = requests.length;
    const page = await api.fetchNotifications(0, filter);
    assert.deepEqual(page.notifications.map(notice => notice.type), types);
    assert.equal(page.nextOffset, 60);
    assert.equal(page.hasMore, true);
    assert.equal(requests.length - before, 1, 'one useful page is enough; do not delay for 20 matches');
    assert.ok(page.notifications.some(notice => notice.read));
    assert.ok(page.notifications.some(notice => !notice.read));
  }
});

test('sparse notification categories resume past the initial five pages without declaring an empty history', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    const query = new URL('https://linux.do' + request.path).searchParams;
    const offset = Number(query.get('offset'));
    return json({ total_rows_notifications: 361, notifications: offset < 300 ?
      [{ id: offset + 1, notification_type: 5, read: true }] :
      offset === 300 ? [{ id: 301, notification_type: 6, read: false }] : [] });
  });
  const scan = await api.fetchNotifications(0, rt.models.NotificationFilter.Messages);
  assert.deepEqual(scan.notifications, []);
  assert.equal(scan.hasMore, true, 'not enough history has been searched to show an empty category');
  assert.equal(scan.nextOffset, 300);
  assert.equal(requests.length, 5, 'sparse history cannot trigger an unbounded request burst');
  const older = await api.fetchNotifications(scan.nextOffset, rt.models.NotificationFilter.Messages);
  assert.deepEqual(older.notifications.map(notice => notice.id), [301]);
  assert.equal(older.nextOffset, 360);
  assert.equal(older.hasMore, true);
  const last = await api.fetchNotifications(older.nextOffset, rt.models.NotificationFilter.Messages);
  assert.deepEqual(last.notifications, []);
  assert.equal(last.hasMore, false);
  assert.equal(requests.length, 7);
});

test('notification scan crosses inaccessible empty rows but rejects repeated nonmatching pages', async () => {
  const rt = runtime();
  const { api } = browserApi(rt, async request => {
    const offset = Number(new URL('https://linux.do' + request.path).searchParams.get('offset'));
    return json({ total_rows_notifications: 120, notifications: offset === 0 ? [] :
      [{ id: 61, notification_type: 7, read: false }] });
  });
  const page = await api.fetchNotifications(0, rt.models.NotificationFilter.Messages);
  assert.deepEqual(page.notifications.map(notice => notice.id), [61]);
  assert.equal(page.hasMore, false);
  const repeated = browserApi(rt, async () => json({ total_rows_notifications: 1000,
    notifications: [{ id: 1, notification_type: 5, read: true }] }));
  await assert.rejects(() => repeated.api.fetchNotifications(0, rt.models.NotificationFilter.Messages),
    error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
  assert.equal(repeated.requests.length, 2);
});

test('cancelled or previous-account notification scans cannot continue or return stale content', async () => {
  for (const resetAccount of [false, true]) {
    const rt = runtime();
    const cancellation = new rt.api.RequestCancellation();
    let release;
    let started;
    const pending = new Promise(resolve => { started = resolve; });
    const { api, requests } = browserApi(rt, async () => {
      started();
      return new Promise(resolve => { release = resolve; });
    });
    const outcome = api.fetchNotifications(0, rt.models.NotificationFilter.Messages, cancellation)
      .then(value => ({ value }), error => ({ error }));
    await pending;
    if (resetAccount) { api.resetSessionContext(); } else { cancellation.cancel(); }
    release(json({ total_rows_notifications: 600, notifications: [{ id: 1, notification_type: 5 }] }));
    assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
    assert.equal(requests.length, 1);
  }
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

test('GIF87a, GIF89a and WebP bytes keep decoder-recognizable cache suffixes with opaque names', async () => {
  const fixtures = [
    { name: 'GIF87a', extension: 'gif', bytes: [71, 73, 70, 56, 55, 97, 1, 0, 1, 0, 0, 0] },
    { name: 'GIF89a', extension: 'gif', bytes: [71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 0, 0] },
    { name: 'WebP', extension: 'webp', bytes: [82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80, 86, 80, 56, 88] }
  ];
  for (const fixture of fixtures) {
    const rt = runtime({ responseCode: 200, header: { 'content-type': 'application/octet-stream' },
      result: new Uint8Array(fixture.bytes).buffer });
    const media = rt.load('services/ForumMedia');
    // Neither the source extension nor MIME supplies the format decision.
    const uri = await media.loadForumMedia('https://linux.do/private-avatar/photo.png?token=fixture-sensitive-value',
      { cacheDir: '/app-cache' });
    const filename = uri.slice(uri.lastIndexOf('/') + 1);
    assert.match(filename, new RegExp(`^[a-f0-9]{64}-fixture-process-[0-9]+\\.${fixture.extension}$`), fixture.name);
    for (const secret of ['private-avatar', 'photo', 'token', 'fixture-sensitive-value']) {
      assert.equal(filename.includes(secret), false, `${fixture.name}: ${secret}`);
    }
    assert.deepEqual(new Uint8Array([...rt.files.values()][0]), new Uint8Array(fixture.bytes), fixture.name);
    assert.equal(rt.openFiles.size, 0, fixture.name);
  }
});

test('claimed GIF URLs and MIME cannot label PNG bytes or incomplete animation signatures as animated files', async () => {
  const fixtures = [
    { name: 'PNG under GIF metadata', bytes: [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13] },
    { name: 'incomplete GIF header', bytes: [71, 73, 70, 56, 57] },
    { name: 'incomplete RIFF WebP header', bytes: [82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66] },
    { name: 'other RIFF content', bytes: [82, 73, 70, 70, 4, 0, 0, 0, 87, 65, 86, 69] }
  ];
  for (const fixture of fixtures) {
    const rt = runtime({ responseCode: 200, header: { 'content-type': 'image/gif' },
      result: new Uint8Array(fixture.bytes).buffer });
    const media = rt.load('services/ForumMedia');
    const uri = await media.loadForumMedia('https://linux.do/private/avatar.gif?original=private-name.webp',
      { cacheDir: '/app-cache' });
    const filename = uri.slice(uri.lastIndexOf('/') + 1);
    assert.match(filename, /^[a-f0-9]{64}-fixture-process-[0-9]+\.image$/, fixture.name);
    assert.equal(filename.includes('avatar'), false, fixture.name);
    assert.equal(filename.includes('private-name'), false, fixture.name);
    assert.deepEqual(new Uint8Array([...rt.files.values()][0]), new Uint8Array(fixture.bytes), fixture.name);
  }
});

test('verified browser media replaces native forum/CDN image reads and preserves binary cache bytes', async () => {
  const rt = runtime(gifResponse());
  const media = rt.load('services/ForumMedia');
  const api = rt.api.forumApi;
  const browserReads = [];
  api.registerBrowserMediaTransport(async (url, cancellation) => {
    assert.equal(cancellation.isCancelled, false);
    browserReads.push(url);
    const native = gifResponse();
    return { status: native.responseCode, headers: native.header, bytes: native.result };
  });
  api.setBrowserTransportEnabled(true);
  const context = { cacheDir: '/app-cache' };
  const forumUri = await media.loadForumMedia('https://linux.do/uploads/a.gif', context);
  const cdnUri = await media.loadForumMedia('https://cdn3.ldstatic.com/original/a.gif', context);
  assert.ok(forumUri.endsWith('.gif'));
  assert.ok(cdnUri.endsWith('.gif'));
  assert.equal(browserReads.length, 2);
  assert.equal(rt.nativeCalls.length, 0);
  for (const bytes of rt.files.values()) {
    assert.deepEqual(new Uint8Array(bytes), new Uint8Array(gifResponse().result));
  }
  await media.loadForumMedia('https://public.example.invalid/other.gif', context);
  assert.equal(rt.nativeCalls.length, 1, 'other external images retain the existing no-cookie path');
  assert.equal(rt.nativeCalls[0].options.header.Cookie, undefined);
});

test('late browser image bytes cannot enter the cache after the account generation changes', async () => {
  const rt = runtime();
  const media = rt.load('services/ForumMedia');
  const api = rt.api.forumApi;
  let release, started;
  const ready = new Promise(resolve => { started = resolve; });
  api.registerBrowserMediaTransport(async () => {
    started();
    return new Promise(resolve => { release = resolve; });
  });
  api.setBrowserTransportEnabled(true);
  const outcome = media.loadForumMedia('https://linux.do/private.gif', { cacheDir: '/app-cache' })
    .then(value => ({ value }), error => ({ error }));
  await ready;
  api.resetSessionContext();
  const native = gifResponse();
  release({ status: 200, headers: native.header, bytes: native.result });
  assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(rt.files.size, 0);
  assert.equal(rt.nativeCalls.length, 0);
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

test('new topic categories require explicit create permission and refresh account-scoped permissions', async () => {
  const rt = runtime();
  let loadCount = 0;
  const { api, requests } = browserApi(rt, async request => {
    assert.equal(request.path, '/categories.json?include_subcategories=true');
    loadCount++;
    return json({ category_list: { categories: [
      { id: 1, name: 'Writable', permission: loadCount === 1 ? 1 : 3,
        minimum_required_tags: 2, topic_template: 'Describe the question', topic_title_placeholder: 'Question title',
        subcategory_list: [{ id: 7, name: 'Writable child', permission: 1, parent_category_id: 1 }] },
      { id: 2, name: 'Reply only', permission: 2 }, { id: 3, name: 'Read only', permission: 3 },
      { id: 4, name: 'Missing permission' }, { id: 5, name: 'Invalid permission', permission: true },
      { id: 6, name: 'String permission', permission: '1' }
    ] } });
  });
  const categories = await api.fetchCreateTopicCategories();
  assert.deepEqual(categories.map(category => category.id), [1, 7]);
  assert.equal(categories[0].minimumRequiredTags, 2);
  assert.equal(categories[0].topicTemplate, 'Describe the question');
  assert.equal(categories[0].topicTitlePlaceholder, 'Question title');
  assert.deepEqual((await api.fetchCreateTopicCategories()).map(category => category.id), [7]);
  assert.equal(requests.length, 2, 'composer must not reuse stale create permissions');
  assert.equal(rt.nativeCalls.length, 0);
});

test('new topic sends title body category and named tags with CSRF once, returning only a real first post', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.path === '/session/csrf.json') { return json({ csrf: 'new-topic-fixture-csrf' }); }
    return json({ success: true, action: 'create_post', post: { id: 300, topic_id: 90, post_number: 1 } });
  });
  assert.deepEqual(await api.createTopic(' A topic ', ' Body with **formatting** ', 7, [' tag ', '标签', 'tag', '']),
    { queued: false, topicId: 90, postNumber: 1, pendingCount: 0 });
  assert.equal(requests.length, 2);
  assert.equal(requests[1].path, '/posts.json');
  assert.equal(requests[1].method, 'POST');
  assert.equal(requests[1].csrf, 'new-topic-fixture-csrf');
  assert.deepEqual(JSON.parse(requests[1].body), { title: 'A topic', raw: 'Body with **formatting**', category: 7,
    tags: [{ name: 'tag' }, { name: '标签' }], nested_post: true });
  assert.equal(rt.nativeCalls.length, 0);
});

test('new topic distinguishes confirmed queue receipts from published and legacy flat receipts', async () => {
  const rt = runtime();
  for (const receipt of [
    { success: true, action: 'enqueued', pending_count: 3 },
    { id: 301, topic_id: 91, post_number: 1 }
  ]) {
    const { api, requests } = browserApi(rt, async request => request.path === '/session/csrf.json' ?
      json({ csrf: 'fixture-csrf' }) : json(receipt));
    const result = await api.createTopic('A topic', 'A full body', 7);
    assert.deepEqual(result, receipt.action === 'enqueued' ?
      { queued: true, topicId: 0, postNumber: 0, pendingCount: 3 } :
      { queued: false, topicId: 91, postNumber: 1, pendingCount: 0 });
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
});

test('new topic fails unknown or malformed receipts without inventing a topic or retrying the mutation', async () => {
  const rt = runtime();
  const receipts = [json({}), json({ success: true }), json({ action: 'enqueued' }),
    json({ action: 'create_post', success: true, post: { id: 300, topic_id: 90 } }),
    json({ action: 'create_post', success: true, post: { id: 300, topic_id: 90, post_number: 2 } }),
    json({ action: 'future_action', success: true, post: { id: 300, topic_id: 90, post_number: 1 } }),
    json({ post: { id: 300, topic_id: 90, post_number: 1 } }),
    json(null), json([]), { status: 200, body: 'not JSON', headers: {} }, json({}, 503)];
  for (const receipt of receipts) {
    const { api, requests } = browserApi(rt, async request => request.path === '/session/csrf.json' ?
      json({ csrf: 'fixture-csrf' }) : receipt);
    await assert.rejects(() => api.createTopic('A topic', 'A full body', 7), error =>
      error.kind === rt.api.ForumErrorKind.UnknownResult);
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
});

test('new topic preserves validation details and authentication or verification failures without reposting', async () => {
  const rt = runtime();
  const cases = [
    [json({ errors: ['<b>标题</b>太短', '至少需要 2 个标签'] }, 422), rt.api.ForumErrorKind.Rejected, '标题 太短；至少需要 2 个标签'],
    [json({ success: false, errors: ['标签不可用'] }), rt.api.ForumErrorKind.Rejected, '标签不可用'],
    [json({}, 401), rt.api.ForumErrorKind.AuthenticationRequired],
    [json({}, 403), rt.api.ForumErrorKind.Forbidden],
    [json({}, 503, { 'cf-mitigated': 'challenge' }), rt.api.ForumErrorKind.VerificationRequired]
  ];
  for (const [receipt, kind, message] of cases) {
    const { api, requests } = browserApi(rt, async request => request.path === '/session/csrf.json' ?
      json({ csrf: 'fixture-csrf' }) : receipt);
    await assert.rejects(() => api.createTopic('A topic', 'A full body', 7), error =>
      error.kind === kind && (!message || error.message === message));
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
});

test('new topic rejects missing input, invalid CSRF and pre-dispatch cancellation without writing', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ csrf: '' }));
  for (const [title, raw, category] of [[' ', 'Body', 7], ['Title', ' ', 7], ['Title', 'Body', 0]]) {
    await assert.rejects(() => api.createTopic(title, raw, category), error => error.kind === rt.api.ForumErrorKind.Rejected);
  }
  assert.equal(requests.length, 0);
  const cancellation = new rt.api.RequestCancellation(); cancellation.cancel();
  await assert.rejects(() => api.createTopic('Title', 'Body', 7, [], cancellation), error =>
    error.kind === rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.length, 0);
  await assert.rejects(() => api.createTopic('Title', 'Body', 7), error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
  assert.equal(requests.filter(request => request.method === 'POST').length, 0);
});

test('new topic account reset after CSRF prevents submitting another account draft', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({}));
  let releaseCsrf;
  api.fetchCsrf = () => new Promise(resolve => { releaseCsrf = resolve; });
  const outcome = api.createTopic('Private old title', 'Private old draft', 7).then(value => ({ value }), error => ({ error }));
  api.resetSessionContext();
  releaseCsrf('old-account-csrf');
  assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.equal(requests.length, 0);
});

test('new topic late receipts and category permissions cannot cross cancellation or account changes', async () => {
  const rt = runtime();
  for (const mode of ['cancel', 'account']) {
    let releaseResponse;
    let markDispatched;
    const dispatched = new Promise(resolve => { markDispatched = resolve; });
    const { api, requests } = browserApi(rt, async request => {
      if (request.path === '/session/csrf.json') { return json({ csrf: 'fixture-csrf' }); }
      markDispatched();
      return new Promise(resolve => { releaseResponse = resolve; });
    });
    const cancellation = new rt.api.RequestCancellation();
    const outcome = api.createTopic('Title', 'Body', 7, [], cancellation).then(value => ({ value }), error => ({ error }));
    await dispatched;
    if (mode === 'cancel') { cancellation.cancel(); } else { api.resetSessionContext(); }
    releaseResponse(json({ success: true, action: 'create_post', post: { id: 300, topic_id: 90, post_number: 1 } }));
    assert.equal((await outcome).error.kind, rt.api.ForumErrorKind.Cancelled);
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
  let releaseCategories;
  let markCategoriesDispatched;
  const categoriesDispatched = new Promise(resolve => { markCategoriesDispatched = resolve; });
  const { api } = browserApi(rt, async () => {
    markCategoriesDispatched();
    return new Promise(resolve => { releaseCategories = resolve; });
  });
  const categories = api.fetchCreateTopicCategories().then(value => ({ value }), error => ({ error }));
  await categoriesDispatched;
  api.resetSessionContext();
  releaseCategories(json({ category_list: { categories: [{ id: 7, name: 'Old private category', permission: 1 }] } }));
  assert.equal((await categories).error.kind, rt.api.ForumErrorKind.Cancelled);
  assert.deepEqual(api.cachedCategories(), []);
});

test('my topics and replies use distinct official action filters and stable pagination keys', async () => {
  for (const [section, filter] of [['Topics', '4'], ['Replies', '5']]) {
    const rt = runtime();
    const actions = Array.from({ length: 30 }, (_unused, index) => ({ post_id: index + 40,
      topic_id: index + 400, post_number: section === 'Topics' ? 1 : 7,
      title: 'Fixture &amp; title', excerpt: '<p>Content</p>', action_type: Number(filter), created_at: '2026-10-28T01:00:00Z' }));
    const { api, requests } = browserApi(rt, async () => json({ user_actions: actions }));
    const page = await api.fetchProfile('fixture user', rt.models.ProfileSection[section], 2);
    const query = new URL('https://linux.do' + requests[0].path).searchParams;
    assert.equal(query.get('filter'), filter);
    assert.equal(query.get('username'), 'fixture user');
    assert.equal(query.get('offset'), '60');
    assert.equal(query.get('limit'), '30');
    assert.equal(page.hasMore, true); assert.equal(page.nextCursor, 3);
    assert.equal(page.entries[0].topicId, 400);
    assert.equal(page.entries[0].postNumber, section === 'Topics' ? 1 : 7);
    const refreshed = await api.fetchProfile('fixture user', rt.models.ProfileSection[section]);
    assert.equal(refreshed.entries[0].id, page.entries[0].id);
    assert.match(page.entries[0].subtitle, section === 'Topics' ? /发表话题/ : /回复/);
  }
});

test('server read history keeps service ordering, continuation and real read-floor navigation', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ topic_list: {
    topics: [{ id: 42, title: 'Read second', posts_count: 20, last_read_post_number: 12 },
      { id: 7, title: 'Read first', posts_count: 3 }], more_topics_url: '/read.json?page=3'
  }, users: [] }));
  const result = await api.fetchProfile('fixture', rt.models.ProfileSection.Read, 2);
  assert.equal(requests[0].path, '/read.json?page=2');
  assert.deepEqual(result.entries.map(entry => entry.topicId), [42, 7]);
  assert.deepEqual(result.entries.map(entry => entry.postNumber), [12, 1]);
  assert.equal(result.hasMore, true); assert.equal(result.nextCursor, 3);
});

test('bookmarks support post and topic serializers with bounded resume floors and opaque continuation URLs', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ user_bookmark_list: {
    bookmarks: [{ id: 1, topic_id: 42, bookmarkable_type: 'Post', linked_post_number: 7,
      title: 'A &amp; B', excerpt: '<p>Saved post</p>', name: 'remember', highest_post_number: 20,
      user: { username: 'fixture', avatar_template: '/avatar/{size}.png' } },
    { id: 2, topic_id: 43, bookmarkable_type: 'Topic', linked_post_number: 1,
      last_read_post_number: 12, highest_post_number: 12, title: 'Saved topic' }],
    more_bookmarks_url: 'https://untrusted.example/never-follow'
  } }));
  const result = await api.fetchProfile('fixture user', rt.models.ProfileSection.Bookmarks, 1);
  assert.equal(requests[0].path, '/u/fixture%20user/bookmarks.json?page=1');
  assert.equal(result.entries[0].id, 'bookmark:1'); assert.equal(result.entries[0].postNumber, 7);
  assert.equal(result.entries[0].title, 'A & B'); assert.match(result.entries[0].subtitle, /remember.*Saved post/);
  assert.equal(result.entries[1].postNumber, 12, 'A completely read topic never links beyond its highest floor.');
  assert.equal(result.hasMore, true); assert.equal(result.nextCursor, 2);
  assert.equal(requests.length, 1, 'The server URL is a continuation flag, never a credential-bearing redirect.');
});

test('empty bookmark receipts differ from malformed data and unavailable bookmarks remain visible with a reason', async () => {
  const rt = runtime();
  let response = { bookmarks: [] };
  const { api } = browserApi(rt, async () => json(response));
  const empty = await api.fetchProfile('fixture', rt.models.ProfileSection.Bookmarks);
  assert.deepEqual(empty.entries, []); assert.equal(empty.hasMore, false);
  response = { success: true };
  await assert.rejects(() => api.fetchProfile('fixture', rt.models.ProfileSection.Bookmarks),
    error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
  response = { user_bookmark_list: { bookmarks: [{ id: 8, topic_id: 42, title: 'Removed', deleted: true },
    { id: 9, bookmarkable_type: 'Chat::Message', title: 'Chat saved' }] } };
  const unavailable = await api.fetchProfile('fixture', rt.models.ProfileSection.Bookmarks);
  assert.equal(unavailable.entries.length, 2); assert.ok(unavailable.entries.every(entry => entry.topicId === 0));
  assert.match(unavailable.entries[0].subtitle, /原内容暂不可用/);
  assert.match(unavailable.entries[1].subtitle, /社区网页查看/);
});

test('personal statistics preserve missing metrics and reject a missing summary receipt', async () => {
  const rt = runtime();
  let response = { user_summary: { topic_count: 0, post_count: 4, likes_received: 8 } };
  const { api } = browserApi(rt, async () => json(response));
  const summary = await api.fetchProfile('fixture', rt.models.ProfileSection.Summary);
  assert.equal(summary.fields.find(field => field.label === '发表话题').value, '0');
  assert.equal(summary.fields.find(field => field.label === '回复数量').value, '4');
  assert.equal(summary.fields.find(field => field.label === '收到赞').value, '8');
  assert.equal(summary.fields.find(field => field.label === '访问天数').value, '—');
  response = { success: true };
  await assert.rejects(() => api.fetchProfile('fixture', rt.models.ProfileSection.Summary),
    error => error.kind === rt.api.ForumErrorKind.InvalidResponse);
});

test('post bookmarks use the official bookmarkable payload, confirmed bookmark ID and one CSRF-protected write', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => {
    if (request.method === 'GET') { return json({ csrf: 'fixture-only-csrf' }); }
    return request.method === 'POST' ? json({ success: 'OK', id: 81 }) : json({ success: 'OK' });
  });
  assert.equal(await api.createPostBookmark(71), 81);
  await api.deleteBookmark(81);
  const writes = requests.filter(request => request.method !== 'GET');
  assert.deepEqual(writes.map(request => [request.path, request.method]),
    [['/bookmarks.json', 'POST'], ['/bookmarks/81.json', 'DELETE']]);
  assert.deepEqual(JSON.parse(writes[0].body), { bookmarkable_id: 71, bookmarkable_type: 'Post' });
  assert.equal(writes[1].body, '');
  assert.ok(writes.every(request => request.csrf === 'fixture-only-csrf'));
  assert.equal(rt.nativeCalls.length, 0);
});

test('bookmark receipt errors cannot invent success or repeat a state-changing request', async () => {
  for (const [response, expected] of [
    [json({ success: false, errors: ['fixture bookmark refused'] }), 'rejected'],
    [json({ success: 'OK' }), 'unknown_result'],
    [json({ success: 'OK', id: -1 }), 'unknown_result'],
    [json({ success: 'OK', id: 1.2 }), 'unknown_result'],
    [json({ id: 81 }), 'unknown_result'],
    [{ status: 200, body: 'not JSON', headers: {} }, 'unknown_result'],
    [json({ errors: ['fixture forbidden'] }, 403), 'forbidden'],
    [json({ errors: ['fixture throttled'] }, 429), 'rate_limited'],
    [json({ errors: ['fixture upstream failure'] }, 502), 'unknown_result']
  ]) {
    const rt = runtime();
    const { api, requests } = browserApi(rt, async request => request.method === 'GET' ?
      json({ csrf: 'fixture-only-csrf' }) : response);
    await assert.rejects(() => api.createPostBookmark(71), error => error.kind === expected);
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
  for (const response of [json({}), { status: 200, body: 'unknown', headers: {} }]) {
    const rt = runtime();
    const { api, requests } = browserApi(rt, async request => request.method === 'GET' ?
      json({ csrf: 'fixture-only-csrf' }) : response);
    await assert.rejects(() => api.deleteBookmark(81), error => error.kind === 'unknown_result');
    assert.equal(requests.filter(request => request.method === 'DELETE').length, 1);
  }
});

test('invalid bookmark IDs and account changes during CSRF fetch cannot issue a write', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async () => json({ csrf: 'fixture-only-csrf' }));
  for (const id of [0, -1, 1.2, NaN, Infinity]) {
    await assert.rejects(() => api.createPostBookmark(id), error => error.kind === 'rejected');
    await assert.rejects(() => api.deleteBookmark(id), error => error.kind === 'rejected');
  }
  assert.equal(requests.length, 0);
  let release;
  const pending = browserApi(rt, () => new Promise(resolve => { release = resolve; }));
  const operation = pending.api.createPostBookmark(71).then(value => ({ value }), error => ({ error }));
  await Promise.resolve();
  pending.api.resetSessionContext();
  release(json({ csrf: 'old-account-fixture' }));
  assert.equal((await operation).error.kind, 'cancelled');
  assert.equal(pending.requests.filter(request => request.method === 'POST').length, 0);
});

test('post bookmark mapping keeps known state, rejects unsafe IDs and preserves unknown metadata for partial receipts', () => {
  const rt = runtime();
  const base = { id: 71, topic_id: 42, post_number: 3 };
  assert.equal(rt.wire.postFromWire({ ...base, bookmarked: true, bookmark_id: 81 }).bookmarkId, 81);
  assert.equal(rt.wire.postFromWire({ ...base, bookmarked: false, bookmark_id: 81 }).bookmarkId, undefined);
  assert.equal(rt.wire.postFromWire(base).bookmarked, undefined);
  for (const bookmark_id of [0, -1, 1.2, NaN, Infinity, '81']) {
    assert.equal(rt.wire.postFromWire({ ...base, bookmarked: true, bookmark_id }).bookmarkId, undefined);
  }
});

test('revision reads use the latest endpoint and opaque server navigation numbers without writes or raw-content fallback', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => json({
    post_id: 71, current_revision: request.path.endsWith('/2.json') ? 2 : 9,
    first_revision: 2, previous_revision: request.path.endsWith('/2.json') ? null : 2,
    next_revision: request.path.endsWith('/2.json') ? 9 : null, last_revision: 9,
    current_version: request.path.endsWith('/2.json') ? 2 : 3, version_count: 3,
    username: 'fixture-editor', created_at: '2026-10-28T12:00:00Z',
    body_changes: { inline: '<p>Original<ins>New</ins></p>' }
  }));
  const latest = await api.fetchPostRevision(71);
  assert.equal(latest.currentRevision, 9); assert.equal(latest.previousRevision, 2);
  const older = await api.fetchPostRevision(71, latest.previousRevision);
  assert.equal(older.currentRevision, 2); assert.equal(older.nextRevision, 9);
  await api.fetchPostRevision(71, older.nextRevision);
  assert.deepEqual(requests.map(request => request.path), [
    '/posts/71/revisions/latest.json', '/posts/71/revisions/2.json', '/posts/71/revisions/9.json'
  ]);
  assert.ok(requests.every(request => request.method === 'GET'));
  assert.equal(rt.nativeCalls.length, 0);
});

test('invalid or unauthorized revision reads never enumerate versions, expose another post or fabricate an empty history', async () => {
  const rt = runtime();
  let response = json({ post_id: 72, current_revision: 3, first_revision: 2, last_revision: 3, current_version: 3, version_count: 3 });
  const { api, requests } = browserApi(rt, async () => response);
  for (const number of [-1, 1, 1.5, NaN, Infinity]) {
    await assert.rejects(() => api.fetchPostRevision(71, number), error => error.kind === 'rejected');
  }
  assert.equal(requests.length, 0);
  await assert.rejects(() => api.fetchPostRevision(71), error => error.kind === 'invalid_response');
  assert.equal(requests.length, 1);
  for (const [status, kind] of [[403, 'forbidden'], [404, 'not_found'], [429, 'rate_limited']]) {
    response = json({ errors: ['Fixture unavailable revision'] }, status);
    const before = requests.length;
    await assert.rejects(() => api.fetchPostRevision(71, 3), error => error.kind === kind);
    assert.equal(requests.length, before + 1, 'A rejected revision cannot trigger enumeration or a raw-content fallback.');
  }
});

test('post edit-history permission is explicit and public version remains distinct from server revision pointers', () => {
  const rt = runtime();
  const base = { id: 71, topic_id: 42, post_number: 3 };
  const policy = rt.load('models/PostRevisionModels');
  assert.equal(policy.canReadPostHistory(rt.wire.postFromWire({ ...base, can_view_edit_history: true, version: 3 })), true);
  for (const value of [{}, { can_view_edit_history: true }, { version: 3 }, { can_view_edit_history: false, version: 3 },
    { can_view_edit_history: 'true', version: 3 }, { can_view_edit_history: true, version: 1 },
    { can_view_edit_history: true, version: 2.5 }]) {
    assert.equal(policy.canReadPostHistory(rt.wire.postFromWire({ ...base, ...value })), false);
  }
});

test('post author display names preserve the server nickname independently of the stable username', () => {
  const rt = runtime();
  const base = { id: 71, topic_id: 42, post_number: 2, username: 'luokakale' };
  const named = rt.wire.postFromWire({ ...base, name: '洛卡卡了', display_username: 'Other fallback' });
  assert.equal(named.username, 'luokakale'); assert.equal(named.displayName, '洛卡卡了');
  assert.equal(rt.wire.postFromWire({ ...base, display_username: '洛卡卡了' }).displayName, '洛卡卡了');
  assert.equal(rt.wire.postFromWire({ ...base, name: ' ', display_username: '洛卡卡了' }).displayName, '洛卡卡了');
  assert.equal(rt.wire.postFromWire(base).displayName, undefined, 'Missing nickname metadata stays unknown.');
  assert.equal(rt.wire.postFromWire({ ...base, name: '' }).displayName, '', 'An explicit blank nickname is not the previous cached name.');
});

test('reading timing writes use official millisecond fields, CSRF and empty successful receipts exactly once', async () => {
  const rt = runtime();
  const { api, requests } = browserApi(rt, async request => request.path === '/session/csrf.json' ?
    json({ csrf: 'fixture-csrf' }) : { status: 204, body: '', headers: {} });
  const cancellation = new rt.api.RequestCancellation();
  await api.recordTopicReadTimings({ ownerId: 8, sessionGeneration: api.getSessionGeneration(), topicId: 42,
    topicTimeMs: 15000, postTimings: [{ postNumber: 1, milliseconds: 15000 }, { postNumber: 9, milliseconds: 2000 }] }, cancellation);
  assert.equal(requests.length, 2); assert.equal(requests[1].path, '/topics/timings'); assert.equal(requests[1].method, 'POST');
  assert.equal(requests[1].csrf, 'fixture-csrf');
  assert.deepEqual(JSON.parse(requests[1].body), { topic_id: 42, topic_time: 15000, timings: { '1': 15000, '9': 2000 } });
  assert.equal(api.readTimingRequests.size, 0);
});

test('reading timing rejects invented floors, excessive durations and duplicate floors before any request', async () => {
  const rt = runtime(); const { api, requests } = browserApi(rt, async () => assert.fail('No request is permitted.'));
  const valid = { ownerId: 8, sessionGeneration: api.getSessionGeneration(), topicId: 42,
    topicTimeMs: 15000, postTimings: [{ postNumber: 1, milliseconds: 1000 }] };
  for (const invalid of [{ ownerId: 0 }, { topicId: 0 }, { topicTimeMs: 60001 }, { topicTimeMs: -1 },
    { postTimings: [] }, { postTimings: [{ postNumber: 0, milliseconds: 1000 }] },
    { postTimings: [{ postNumber: 1, milliseconds: 16000 }] },
    { postTimings: [{ postNumber: 1, milliseconds: 1000.5 }] },
    { postTimings: [{ postNumber: 1, milliseconds: 1000 }, { postNumber: 1, milliseconds: 1000 }] }]) {
    await assert.rejects(() => api.recordTopicReadTimings({ ...valid, ...invalid }, new rt.api.RequestCancellation()),
      error => error.kind === rt.api.ForumErrorKind.Rejected);
  }
  assert.equal(requests.length, 0);
});

test('reading timing never dispatches after cancellation, backgrounding or account generation changes during CSRF', async () => {
  for (const action of ['cancel', 'background', 'account']) {
    const rt = runtime(); const cancellation = new rt.api.RequestCancellation();
    const { api, requests } = browserApi(rt, async request => {
      assert.equal(request.path, '/session/csrf.json');
      if (action === 'cancel') { cancellation.cancel(); }
      if (action === 'background') { api.setForeground(false); }
      if (action === 'account') { api.resetSessionContext(); }
      return json({ csrf: 'fixture-csrf' });
    });
    await assert.rejects(() => api.recordTopicReadTimings({ ownerId: 8, sessionGeneration: api.getSessionGeneration(), topicId: 42,
      topicTimeMs: 1000, postTimings: [{ postNumber: 1, milliseconds: 1000 }] }, cancellation),
    error => error.kind === rt.api.ForumErrorKind.Cancelled);
    assert.equal(requests.length, 1); assert.equal(api.readTimingRequests.size, 0);
  }
});

test('reading timing queued behind pacing is cancelled before dispatch when foreground ends', async () => {
  const rt = runtime(); const { api, requests } = browserApi(rt, async request => {
    assert.equal(request.path, '/session/csrf.json'); return json({ csrf: 'fixture-csrf' });
  });
  let slots = 0;
  api.waitForSlot = async () => { if (++slots === 2) { api.setForeground(false); } };
  const cancellation = new rt.api.RequestCancellation();
  await assert.rejects(() => api.recordTopicReadTimings({ ownerId: 8, sessionGeneration: api.getSessionGeneration(), topicId: 42,
    topicTimeMs: 1000, postTimings: [{ postNumber: 1, milliseconds: 1000 }] }, cancellation),
  error => error.kind === rt.api.ForumErrorKind.Cancelled);
  assert.equal(cancellation.isCancelled, true); assert.equal(requests.length, 1);
});

test('reading timing failed or unknown writes are not recovered or replayed', async () => {
  for (const status of [403, 429, 503]) {
    const rt = runtime(); const { api, requests } = browserApi(rt, async request => request.path === '/session/csrf.json' ?
      json({ csrf: 'fixture-csrf' }) : json({ errors: ['fixture unavailable'] }, status));
    let recoveries = 0; api.registerBrowserRecovery(async () => { recoveries++; return true; });
    await assert.rejects(() => api.recordTopicReadTimings({ ownerId: 8, sessionGeneration: api.getSessionGeneration(), topicId: 42,
      topicTimeMs: 1000, postTimings: [{ postNumber: 1, milliseconds: 1000 }] }, new rt.api.RequestCancellation()));
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
    assert.equal(recoveries, 0); assert.equal(api.readTimingRequests.size, 0);
  }
});
