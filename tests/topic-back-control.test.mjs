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
  assert.ok(start >= 0 && end > start, `Production source extraction failed: ${startMarker} / ${endMarker}`);
  return value.slice(start, end);
}

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value.replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace /g, ''), {
    fileName: 'topic-back-control-production-extract.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const topicSource = source('pages/TopicPage');
const declarations = extract(topicSource, 'export interface TopicTreeRow', '@ComponentV2');
const page = (extract(topicSource, 'export struct TopicPage', '  @Builder\n') + '\n}\n')
  .replace('export struct TopicPage', 'export class TopicPage')
  .replace(/^\s*@Computed\s*\n/gm, '\n')
  .replace(/^\s*@Monitor\([\s\S]*?\)\s*\n/gm, '\n')
  .replace(/@(Param|Event|Local) /g, '');
const { TopicScrollPolicy } = load(source('services/TopicScrollPolicy'));

function runtime() {
  const constructed = [];
  const materials = [];
  const forbidden = () => { throw new Error('Native, device and network I/O is prohibited in this fixture.'); };
  const appearance = { effectLevel: 2, reduceMotion: false, highContrast: false, themeMode: 0 };
  class ActionBarButton {
    constructor(options) { Object.assign(this, options); constructed.push(this); }
  }
  class ButtonModifier {
    backgroundColor(value) { this.background = value; return this; }
    stateEffect(value) { this.pressState = value; return this; }
    systemMaterial(value) { this.material = value; return this; }
  }
  class Scroller {
    edgeCalls = [];
    scrollEdge(...args) { this.edgeCalls.push(args); }
  }
  const { TopicPage } = load(declarations + '\n' + page, {
    forumSession: { user: { id: 7 }, revision: 1 }, loadAppearanceSettings: () => appearance,
    TopicScrollPolicy, ActionBarButton, ButtonModifier, Scroller, Color: { Transparent: 'transparent' },
    uiMaterial: { Material: { empty: 'empty-material' } },
    LengthMetrics: { vp: value => value }, ColorMetrics: { resourceColor: value => value },
    $r: id => ({ id }), Edge: { Top: 'top' },
    materialFor(settings) {
      // Record the current input to the native policy boundary; do not reproduce its material rules.
      const material = { call: materials.length + 1 };
      materials.push({ material, effectLevel: settings.effectLevel, highContrast: settings.highContrast,
        reduceMotion: settings.reduceMotion, themeMode: settings.themeMode });
      return material;
    },
    forumApi: { fetchTopic: forbidden, fetchPosts: forbidden }, http: { createHttp: forbidden },
    fileIo: { open: forbidden }, picker: { DocumentViewPicker: forbidden },
    photoAccessHelper: { getPhotoAccessHelper: forbidden }, setTimeout: forbidden, clearTimeout: forbidden
  });
  const reader = new TopicPage();
  reader.getUIContext = forbidden;
  return { reader, appearance, constructed, materials };
}

test('collapsed primary button stays centered in its glass circle while expanded and reduced-motion layouts do not shift', () => {
  const { reader, appearance } = runtime();
  assert.equal(reader.readerActionContentOffset, 0);
  reader.toolbarExpanded = false;
  const primaryCenter = 8 + 52 / 2;
  assert.equal(reader.readerActionsWidth, 118);
  assert.equal(primaryCenter + reader.readerActionContentOffset, reader.readerActionsWidth / 2,
    'The HDS primary center must coincide with the enclosing glass center.');
  assert.equal(reader.readerActionContentOffset, 25);
  reader.toolbarExpanded = true;
  assert.equal(reader.readerActionContentOffset, 0, 'Expanded controls keep their existing positions.');
  reader.toolbarExpanded = false;
  appearance.reduceMotion = true;
  assert.equal(reader.readerToolsVisible, true);
  assert.equal(reader.readerActionContentOffset, 0, 'Reduced motion exposes the static expanded bar.');
});

test('the retained back-to-top button becomes enabled after loading without recreating its model', () => {
  const { reader, constructed } = runtime();
  reader.loading = true;
  reader.aboutToAppear();
  const button = reader.backTopButton;
  assert.equal(button.enabled, false);
  assert.equal(button.id, 'topic_back_to_top');
  assert.equal(button.width, 44);

  reader.posts = [{ id: 1, postNumber: 1 }];
  reader.loading = false;
  // ArkUI dispatches this production Monitor when the observed input fields change.
  reader.updateBackTopButton();
  assert.strictEqual(reader.backTopButton, button);
  assert.equal(button.enabled, true, 'A stable HDS node must observe loading completion on the same model.');
  reader.aboutToAppear();
  assert.strictEqual(reader.backTopButton, button);
  assert.deepEqual(constructed, [button], 'Reappearing must not replace the stable-ID model.');
});

test('busy writes and empty content disable and restore the same button across state changes', () => {
  const { reader, constructed } = runtime();
  reader.posts = [{ id: 1, postNumber: 1 }];
  reader.aboutToAppear();
  const button = reader.backTopButton;
  assert.equal(button.enabled, true);
  for (const block of ['writeBusy', 'posts', 'loading']) {
    if (block === 'posts') { reader.posts = []; }
    else { reader[block] = true; }
    reader.updateBackTopButton();
    assert.strictEqual(reader.backTopButton, button);
    assert.equal(button.enabled, false, block);

    if (block === 'posts') { reader.posts = [{ id: 2, postNumber: 2 }]; }
    else { reader[block] = false; }
    reader.updateBackTopButton();
    assert.strictEqual(reader.backTopButton, button);
    assert.equal(button.enabled, true, `${block} completion must restore the control.`);
  }
  assert.deepEqual(constructed, [button]);
});

test('collapse and appearance preserve one material surface and accessibility, while the retained callback honors current guards', () => {
  const { reader, appearance, materials } = runtime();
  reader.posts = [{ id: 1, postNumber: 1 }];
  reader.aboutToAppear();
  const button = reader.backTopButton;
  const previousModifier = button.buttonModifier;
  reader.toolbarExpanded = false;
  appearance.effectLevel = 3;
  appearance.themeMode = 2;
  reader.updateBackTopButton();
  assert.equal(button.accessibilityLevel, 'no-hide-descendants');
  assert.equal(button.enabled, false, 'The invisible back-to-top button cannot remain interactive.');
  button.onClick();
  assert.deepEqual(reader.scroller.edgeCalls, [], 'A stale callback also respects the collapsed state.');
  assert.notStrictEqual(button.buttonModifier, previousModifier);
  assert.equal(button.buttonModifier.material, 'empty-material', 'The parent container owns the only optical surface.');
  assert.equal(materials.length, 0, 'Child controls must not construct an overlapping material or shadow.');

  appearance.reduceMotion = true;
  appearance.highContrast = true;
  reader.updateBackTopButton();
  assert.equal(button.accessibilityLevel, 'yes', 'Reduced motion exposes the static expanded controls.');
  assert.equal(button.enabled, true);
  assert.equal(button.buttonModifier.material, 'empty-material');
  assert.strictEqual(reader.backTopButton, button);

  reader.loading = true;
  button.onClick();
  reader.loading = false;
  reader.writeBusy = true;
  button.onClick();
  assert.deepEqual(reader.scroller.edgeCalls, [], 'The callback must consult the live production loading/write guard.');
  reader.writeBusy = false;
  reader.currentNumber = 8;
  button.onClick();
  assert.deepEqual(reader.scroller.edgeCalls, [['top']]);
  assert.equal(reader.currentNumber, 1);
});
