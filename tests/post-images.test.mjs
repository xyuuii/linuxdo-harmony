import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

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
const source = relative => readFileSync(path.join(sourceRoot, relative + '.ets'), 'utf8');
function extract(value, startMarker, endMarker) {
  const start = value.indexOf(startMarker);
  const end = value.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `Production source extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}
function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    fileName: 'post-image-production-extract.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}
const rich = load(extract(source('components/RichPostContent'), 'export interface PostInline', '@ComponentV2'));

test('normal pictures preserve HTML dimensions and accessible alt without invented visible captions', () => {
  const blocks = rich.parsePostContent('<figure><img src="/uploads/screen.png" width="690" height="1227" ' +
    'alt="应用登录页"><figcaption>作者补充说明</figcaption></figure><img src="/uploads/unnamed.png">');
  const pictures = blocks.filter(block => block.kind === 'image');
  assert.equal(pictures[0].imageWidth, 690);
  assert.equal(pictures[0].imageHeight, 1227);
  assert.equal(pictures[0].description, '应用登录页');
  assert.equal(pictures[1].description, '', 'An unnamed picture must not produce a default caption below it.');
  assert.ok(blocks.some(block => block.runs.some(run => run.text === '作者补充说明')));
  assert.ok(!blocks.flatMap(block => block.runs).some(run => run.text === '帖子图片'));
});

test('lightbox original dimensions and address survive its scaled-down HTML thumbnail', () => {
  const [picture] = rich.parsePostContent('<a class="lightbox" href="/uploads/original.png">' +
    '<img src="/uploads/thumb.png" width="345" height="194" data-orig-width="1920" data-orig-height="1080"></a>');
  assert.equal(picture.url, 'https://linux.do/uploads/original.png');
  assert.equal(picture.imageWidth, 1920);
  assert.equal(picture.imageHeight, 1080);
  const malformed = rich.parsePostContent('<img src="/uploads/a.png" width="690" height="500" ' +
    'data-orig-width="NaN" data-orig-height="900">')[0];
  assert.equal(malformed.imageWidth, 690);
  assert.equal(malformed.imageHeight, 500);
});

test('landscape, square and regular portrait pictures fill the body width at their own aspect ratio', () => {
  assert.deepEqual(rich.postImageLayout(1920, 1080, 360, false),
    { previewHeight: 202.5, imageHeight: 202.5, cropped: false });
  assert.deepEqual(rich.postImageLayout(1080, 1080, 360, false),
    { previewHeight: 360, imageHeight: 360, cropped: false });
  assert.deepEqual(rich.postImageLayout(720, 1280, 360, false),
    { previewHeight: 640, imageHeight: 640, cropped: false });
  assert.equal(rich.postImageLayout(720, 1280, 320, false).previewHeight, 320 * 1280 / 720,
    'Resizing the body must retain the picture ratio instead of a fixed image height.');
});

test('very long pictures retain a large top preview instead of shrinking the entire strip into a square', () => {
  assert.deepEqual(rich.postImageLayout(720, 6000, 360, false),
    { previewHeight: 720, imageHeight: 3000, cropped: true });
  assert.deepEqual(rich.postImageLayout(720, 1280, 360, true),
    { previewHeight: 360, imageHeight: 640, cropped: true });
  assert.deepEqual(rich.postImageLayout(0, 0, 0, false),
    { previewHeight: 240, imageHeight: 240, cropped: false }, 'A nonzero loading frame must exist before decode.');
});

function imageRuntime() {
  const session = { user: { id: 1 }, revision: 2 };
  const sizes = [];
  const invalidated = [];
  const api = { generation: 4, getSessionGeneration() { return this.generation; } };
  const nativeSource = source('components/NativeForumImage');
  const declarations = extract(nativeSource, 'interface LoadedImageIdentity', '@ComponentV2');
  const nativeClass = (extract(nativeSource, 'export struct NativeForumImage', '  @Builder\n') + '\n}\n')
    .replace('export struct NativeForumImage', 'export class NativeForumImage')
    .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
  const exports = load(declarations + '\n' + nativeClass, {
    forumSession: session, forumApi: api, ImageFit: { Cover: 'cover' },
    invalidateForumMedia: async url => invalidated.push(url), clearTimeout,
    loadForumMedia: () => { throw new Error('No native or network I/O is allowed in this fixture.'); }
  });
  const image = new exports.NativeForumImage();
  image.live = true;
  image.url = 'https://linux.do/uploads/private.png';
  image.cachedUri = 'file://fixture-owner-1-generation-4.png';
  image.imageGeneration = 4;
  image.imageRevision = 2;
  image.context = {};
  image.onNaturalSize = (width, height) => sizes.push([width, height]);
  const identity = { uri: image.cachedUri, source: image.url, ownerId: 1, generation: 4, revision: 2 };
  return { image, session, api, identity, sizes, invalidated };
}

test('natural dimensions use original decoded pixels and ignore invalid sizes', () => {
  const { image, identity, sizes } = imageRuntime();
  image.naturalSize(720, 1280, identity);
  image.naturalSize(0, 1280, identity);
  image.naturalSize(NaN, 1280, identity);
  assert.deepEqual(sizes, [[720, 1280]]);
});

test('late decode events cannot resize or invalidate a newer source or another account image', async () => {
  for (const change of [
    ({ image }) => { image.url = 'https://linux.do/uploads/new.png'; },
    ({ image }) => { image.cachedUri = 'file://new-fixture.png'; },
    ({ session }) => { session.user = { id: 2 }; },
    ({ session }) => { session.revision++; },
    ({ api }) => { api.generation++; },
    ({ image }) => { image.live = false; }
  ]) {
    const state = imageRuntime();
    change(state);
    state.image.naturalSize(720, 1280, state.identity);
    state.image.decodeFailed(state.identity);
    await Promise.resolve();
    assert.deepEqual(state.sizes, []);
    assert.deepEqual(state.invalidated, []);
    assert.equal(state.image.failed, false);
  }
});
