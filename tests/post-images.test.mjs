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
  assert.equal(picture.imageDisplayWidth, 345, 'The authored display size must survive selection of the original image.');
  const malformed = rich.parsePostContent('<img src="/uploads/a.png" width="690" height="500" ' +
    'data-orig-width="NaN" data-orig-height="900">')[0];
  assert.equal(malformed.imageWidth, 690);
  assert.equal(malformed.imageHeight, 500);
});

test('landscape, square and regular portrait pictures fill the body width at their own aspect ratio', () => {
  assert.deepEqual(rich.postImageLayout(1920, 1080, 360, false),
    { previewWidth: 360, previewHeight: 202.5, imageHeight: 202.5, cropped: false });
  assert.deepEqual(rich.postImageLayout(1080, 1080, 360, false),
    { previewWidth: 360, previewHeight: 360, imageHeight: 360, cropped: false });
  assert.deepEqual(rich.postImageLayout(720, 1280, 360, false),
    { previewWidth: 360, previewHeight: 640, imageHeight: 640, cropped: false });
  assert.equal(rich.postImageLayout(720, 1280, 320, false).previewHeight, 320 * 1280 / 720,
    'Resizing the body must retain the picture ratio instead of a fixed image height.');
});

test('very long pictures retain a large top preview instead of shrinking the entire strip into a square', () => {
  assert.deepEqual(rich.postImageLayout(720, 6000, 360, false),
    { previewWidth: 360, previewHeight: 720, imageHeight: 3000, cropped: true });
  assert.deepEqual(rich.postImageLayout(720, 1280, 360, true),
    { previewWidth: 360, previewHeight: 360, imageHeight: 640, cropped: true });
  assert.deepEqual(rich.postImageLayout(0, 0, 0, false),
    { previewWidth: 320, previewHeight: 240, imageHeight: 240, cropped: false }, 'A nonzero loading frame must exist before decode.');
});

test('uploaded stickers and authored small previews keep their size instead of filling the entire reader', () => {
  const [sticker] = rich.parsePostContent('<img src="/uploads/sticker.png" width="100" height="80" ' +
    'data-orig-width="1000" data-orig-height="800">');
  assert.equal(sticker.kind, 'image', 'An ordinary upload keeps its picture role and explicit large-view action.');
  assert.deepEqual(rich.postImageLayout(sticker.imageWidth, sticker.imageHeight, 360, false, sticker.imageDisplayWidth),
    { previewWidth: 100, previewHeight: 80, imageHeight: 80, cropped: false });
  assert.deepEqual(rich.postImageLayout(80, 60, 360, false),
    { previewWidth: 80, previewHeight: 60, imageHeight: 60, cropped: false },
    'A decoded small image without HTML dimensions must not be enlarged either.');
  assert.deepEqual(rich.postImageLayout(1000, 800, 60, false, 100),
    { previewWidth: 60, previewHeight: 48, imageHeight: 48, cropped: false },
    'Narrow layouts must still shrink an authored small preview to fit.');
});

function imageRuntime(options = {}) {
  const session = { user: { id: 1 }, revision: 2 };
  const sizes = [];
  const invalidated = [];
  const sourcePaths = [];
  const descriptors = [];
  const sourceReleases = [];
  const descriptorLoads = [];
  const mediaLoads = [];
  const controllerRequests = [];
  const controllerCalls = [];
  const AnimationStatus = { Initial: 0, Running: 1, Paused: 2, Stopped: 3 };
  const api = { generation: 4, getSessionGeneration() { return this.generation; } };
  class RequestCancellation {
    isCancelled = false;
    cancel() { this.isCancelled = true; }
  }
  class ForumApiError extends Error {
    constructor(kind) { super(kind); this.kind = kind; }
  }
  class AnimatedDrawableDescriptor {
    constructor(uri, playback) {
      this.uri = uri;
      this.playback = playback;
      this.controller = {
        status: AnimationStatus.Initial,
        getStatus() { return this.status; },
        start() { controllerCalls.push('start'); this.status = AnimationStatus.Running; },
        pause() { controllerCalls.push('pause'); this.status = AnimationStatus.Paused; },
        resume() { controllerCalls.push('resume'); this.status = AnimationStatus.Running; }
      };
      descriptors.push(this);
    }
    async load() {
      descriptorLoads.push(this);
      return options.loadDescriptor ? options.loadDescriptor() : { imageWidth: 288, imageHeight: 288 };
    }
    getAnimationController() {
      controllerRequests.push(this);
      return options.noController ? undefined : this.controller;
    }
  }
  const imageSdk = {
    createImageSource(localPath) {
      sourcePaths.push(localPath);
      if (options.createSourceError) { throw options.createSourceError; }
      const imageSource = {
        async getFrameCount() { return options.getFrameCount ? options.getFrameCount() : (options.frames ?? 1); },
        async release() {
          sourceReleases.push(imageSource);
          if (options.releaseError) { throw options.releaseError; }
        }
      };
      return imageSource;
    }
  };
  const nativeSource = source('components/NativeForumImage');
  const declarations = extract(nativeSource, 'interface LoadedImageIdentity', '@ComponentV2');
  const nativeClass = (extract(nativeSource, 'export struct NativeForumImage', '  @Builder\n') + '\n}\n')
    .replace('export struct NativeForumImage', 'export class NativeForumImage')
    .replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n').replace(/@(Param|Event|Local) /g, '');
  const exports = load(declarations + '\n' + nativeClass, {
    forumSession: session, forumApi: api, ImageFit: { Cover: 'cover' },
    invalidateForumMedia: async url => invalidated.push(url), clearTimeout,
    RequestCancellation, ForumApiError, ForumErrorKind: { Cancelled: 'cancelled' },
    AnimatedDrawableDescriptor, AnimationStatus, image: imageSdk,
    fileUri: { FileUri: class { constructor(uri) { this.path = new URL(uri).pathname; } } },
    loadForumMedia: (...args) => {
      mediaLoads.push(args);
      assert.ok(options.loadMedia, 'No native or network I/O is allowed in this fixture.');
      return options.loadMedia(...args);
    }
  });
  const image = new exports.NativeForumImage();
  image.live = true;
  image.url = 'https://linux.do/uploads/private.png';
  image.cachedUri = 'file://fixture-owner-1-generation-4.png';
  image.imageGeneration = 4;
  image.imageRevision = 2;
  image.context = {};
  image.getUIContext = () => ({ getHostContext: () => image.context });
  image.onNaturalSize = (width, height) => sizes.push([width, height]);
  const identity = { uri: image.cachedUri, source: image.url, ownerId: 1, generation: 4, revision: 2 };
  return { image, session, api, identity, sizes, invalidated, sourcePaths, descriptors,
    sourceReleases, descriptorLoads, mediaLoads, controllerRequests, controllerCalls, AnimationStatus,
    createDescriptor: () => new AnimatedDrawableDescriptor(image.cachedUri, { autoPlay: true, iterations: -1 }),
    cancellation: () => new RequestCancellation() };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((accept, fail) => { resolve = accept; reject = fail; });
  return { promise, resolve, reject };
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

test('multi-frame GIF and WebP files use their cached sandbox URI with autoplay and infinite playback', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/animated.bin';
  for (const extension of ['gif', 'webp']) {
    const state = imageRuntime({ frames: 45 });
    const animation = await state.image.animationSource(uri,
      `https://linux.do/uploads/animated.${extension}?version=2#image`, state.cancellation());
    assert.equal(animation, state.descriptors[0]);
    assert.equal(animation.uri, uri);
    assert.deepEqual(animation.playback, { autoPlay: true, iterations: -1 });
    assert.deepEqual(state.sourcePaths, ['/data/storage/el2/base/cache/animated.bin']);
    assert.equal(state.sourceReleases.length, 1, 'The metadata ImageSource must not retain native resources.');
  }
});

test('static WebP and ordinary PNG keep the static image path without constructing an animation', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/static.bin';
  const webp = imageRuntime({ frames: 1 });
  assert.equal(await webp.image.animationSource(uri, 'https://linux.do/uploads/static.webp', webp.cancellation()), undefined);
  assert.equal(webp.descriptors.length, 0);
  assert.equal(webp.sourcePaths.length, 1);
  assert.equal(webp.sourceReleases.length, 1);
  const png = imageRuntime({ frames: 45 });
  assert.equal(await png.image.animationSource(uri, 'https://linux.do/uploads/static.png', png.cancellation()), undefined);
  assert.equal(png.sourcePaths.length, 0, 'Ordinary PNGs should not incur animation metadata work.');
  assert.equal(png.descriptors.length, 0);
});

test('animation metadata failures release the ImageSource and preserve the ordinary image fallback', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/image.bin';
  const failed = imageRuntime({ getFrameCount: () => Promise.reject(new Error('Fixture metadata failure')) });
  assert.equal(await failed.image.animationSource(uri, 'https://linux.do/uploads/avatar.gif', failed.cancellation()), undefined);
  assert.equal(failed.sourceReleases.length, 1);
  assert.equal(failed.descriptors.length, 0);
  const releaseFailed = imageRuntime({ frames: 45, releaseError: new Error('Fixture release failure') });
  assert.equal(await releaseFailed.image.animationSource(uri, 'https://linux.do/uploads/avatar.gif', releaseFailed.cancellation()),
    releaseFailed.descriptors[0], 'A release exception must not discard a valid animation.');
  assert.equal(releaseFailed.sourceReleases.length, 1);
});

test('cancellation before or during asynchronous frame metadata cannot construct a descriptor', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/image.bin';
  const early = imageRuntime({ frames: 45 });
  const earlyCancellation = early.cancellation();
  earlyCancellation.cancel();
  assert.equal(await early.image.animationSource(uri, 'https://linux.do/uploads/avatar.gif', earlyCancellation), undefined);
  assert.deepEqual(early.sourcePaths, []);
  const frames = deferred();
  const late = imageRuntime({ getFrameCount: () => frames.promise });
  const lateCancellation = late.cancellation();
  const pending = late.image.animationSource(uri, 'https://linux.do/uploads/avatar.webp', lateCancellation);
  lateCancellation.cancel();
  frames.resolve(45);
  assert.equal(await pending, undefined);
  assert.equal(late.sourceReleases.length, 1);
  assert.equal(late.descriptors.length, 0);
});

test('clear and matching decode failures remove the descriptor while stale failures preserve the current animation', async () => {
  const cleared = imageRuntime();
  const cancellation = cleared.cancellation();
  cleared.image.request = cancellation;
  cleared.image.animatedSource = { fixture: 'old-animation' };
  cleared.image.clearImage();
  assert.equal(cancellation.isCancelled, true);
  assert.equal(cleared.image.animatedSource, undefined);
  assert.equal(cleared.image.cachedUri, '');
  const failed = imageRuntime();
  const animation = { fixture: 'current-animation' };
  failed.image.animatedSource = animation;
  failed.image.decodeFailed({ ...failed.identity, uri: 'file://stale-image.gif' });
  assert.equal(failed.image.animatedSource, animation);
  assert.equal(failed.image.failed, false);
  failed.image.decodeFailed(failed.identity);
  await Promise.resolve();
  assert.equal(failed.image.animatedSource, undefined);
  assert.equal(failed.image.cachedUri, '');
  assert.equal(failed.image.failed, true);
  assert.deepEqual(failed.invalidated, [failed.identity.source]);
});

test('loaded multi-frame media publishes the descriptor only for its current owner and generation', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/avatar.bin';
  const state = imageRuntime({ frames: 45, loadMedia: async () => uri });
  state.image.url = 'https://linux.do/uploads/avatar.gif';
  state.image.clearImage();
  await state.image.loadImage();
  assert.equal(state.image.cachedUri, uri);
  assert.equal(state.image.animatedSource, state.descriptors[0]);
  assert.equal(state.image.imageGeneration, state.api.generation);
  assert.deepEqual(state.descriptorLoads, [state.descriptors[0]]);
  assert.deepEqual(state.sizes, [[288, 288]], 'Animated images need explicit dimensions because Image.onComplete does not fire.');
  assert.equal(state.image.loading, false);
  assert.equal(state.image.failed, false);
});

test('late downloads and metadata cannot publish an animation after cancellation, source replacement or account changes', async () => {
  const uri = 'file://com.fixture/data/storage/el2/base/cache/avatar.bin';
  for (const phase of ['download', 'metadata', 'descriptor']) {
    for (const change of [
      ({ image }) => image.clearImage(),
      ({ image }) => { image.url = 'https://linux.do/uploads/replacement.gif'; },
      ({ image }) => { image.live = false; },
      ({ image }) => { image.ownerId = 2; },
      ({ session }) => { session.user = { id: 2 }; },
      ({ api }) => { api.generation++; }
    ]) {
      const pendingValue = deferred();
      const enteredPhase = deferred();
      const state = imageRuntime({
        frames: 45,
        loadMedia: async () => {
          if (phase === 'download') { enteredPhase.resolve(); return pendingValue.promise; }
          return uri;
        },
        getFrameCount: () => {
          if (phase === 'metadata') { enteredPhase.resolve(); return pendingValue.promise; }
          return 45;
        },
        loadDescriptor: () => {
          if (phase === 'descriptor') { enteredPhase.resolve(); return pendingValue.promise; }
          return { imageWidth: 288, imageHeight: 288 };
        }
      });
      state.image.url = 'https://linux.do/uploads/avatar.gif';
      state.image.clearImage();
      const pending = state.image.loadImage();
      await enteredPhase.promise;
      change(state);
      pendingValue.resolve(phase === 'download' ? uri : phase === 'metadata' ? 45 : { imageWidth: 288, imageHeight: 288 });
      await pending;
      assert.equal(state.image.animatedSource, undefined, `${phase} must not publish after losing its identity.`);
      assert.equal(state.image.cachedUri, '');
      assert.equal(state.image.failed, false);
      assert.deepEqual(state.sizes, [], 'A stale animation load cannot resize the current account image.');
      if (state.sourcePaths.length) { assert.equal(state.sourceReleases.length, 1); }
    }
  }
});

test('descriptor loading failures leave a retryable image error without publishing a broken animation', async () => {
  const state = imageRuntime({ frames: 45,
    loadMedia: async () => 'file://com.fixture/data/storage/el2/base/cache/avatar.bin',
    loadDescriptor: () => Promise.reject(new Error('Fixture descriptor loading failure')) });
  state.image.url = 'https://linux.do/uploads/avatar.gif';
  state.image.clearImage();
  await state.image.loadImage();
  assert.equal(state.image.cachedUri, '');
  assert.equal(state.image.animatedSource, undefined);
  assert.equal(state.image.failed, true);
  assert.equal(state.image.loading, false);
  assert.equal(state.sourceReleases.length, 1);
  assert.deepEqual(state.sizes, []);
});

test('visibility starts initial or stopped animations, pauses hidden ones and resumes without restarting running frames', () => {
  for (const initial of ['Initial', 'Stopped']) {
    const state = imageRuntime();
    const animation = state.createDescriptor();
    state.image.animatedSource = animation;
    animation.controller.status = state.AnimationStatus[initial];
    state.image.animationVisibility(true, 1, state.identity);
    state.image.animationVisibility(true, 0.5, state.identity);
    assert.deepEqual(state.controllerCalls, ['start'], 'Visible running animations must not repeatedly jump to frame one.');
    state.image.animationVisibility(false, 0, state.identity);
    state.image.animationVisibility(false, 0, state.identity);
    assert.deepEqual(state.controllerCalls, ['start', 'pause'], 'A hidden paused animation must remain paused.');
    state.image.animationVisibility(true, 0.5, state.identity);
    state.image.animationVisibility(true, 1, state.identity);
    assert.deepEqual(state.controllerCalls, ['start', 'pause', 'resume']);
    state.image.animationVisibility(true, 0, state.identity);
    assert.deepEqual(state.controllerCalls, ['start', 'pause', 'resume', 'pause'], 'A zero visible ratio cannot keep playing.');
  }
});

test('late visibility callbacks cannot control a newer source, another account or a disposed image', () => {
  for (const change of [
    ({ image }) => { image.url = 'https://linux.do/uploads/new.gif'; },
    ({ image }) => { image.cachedUri = 'file://new-fixture.gif'; },
    ({ image }) => { image.ownerId = 2; },
    ({ session }) => { session.user = { id: 2 }; },
    ({ session }) => { session.revision++; },
    ({ api }) => { api.generation++; },
    ({ image }) => { image.live = false; }
  ]) {
    const state = imageRuntime();
    state.image.animatedSource = state.createDescriptor();
    change(state);
    state.image.animationVisibility(true, 1, state.identity);
    state.image.animationVisibility(false, 0, state.identity);
    assert.deepEqual(state.controllerRequests, [], 'Stale identities must not even obtain the current animation controller.');
    assert.deepEqual(state.controllerCalls, []);
  }
});

test('static images and descriptors not yet attached to an Image need no visibility controller', () => {
  const still = imageRuntime();
  still.image.animationVisibility(true, 1, still.identity);
  still.image.animationVisibility(false, 0, still.identity);
  assert.deepEqual(still.controllerRequests, []);
  const unattached = imageRuntime({ noController: true });
  unattached.image.animatedSource = unattached.createDescriptor();
  assert.doesNotThrow(() => unattached.image.animationVisibility(true, 1, unattached.identity));
  assert.deepEqual(unattached.controllerCalls, []);
});
