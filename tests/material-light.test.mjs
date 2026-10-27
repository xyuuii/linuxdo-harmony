import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = readFileSync(fileURLToPath(new URL('../app/entry/src/main/ets/services/MaterialPolicy.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'material-light-production-extract.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function runtime({ supported = true, capabilityThrows = false, constructorThrows = false } = {}) {
  const constructed = [];
  const empty = Object.freeze({ empty: true });
  const uiMaterial = {
    Material: { empty },
    ImmersiveStyle: { REGULAR: 2, THIN: 1, ULTRA_THIN: 0 },
    isImmersiveMaterialSupported() {
      if (capabilityThrows) { throw new Error('Fixture capability unavailable.'); }
      return supported;
    },
    ImmersiveMaterial: class {
      constructor(options) {
        constructed.push(options);
        if (constructorThrows) { throw new Error('Fixture material unavailable.'); }
        this.options = options;
      }
    }
  };
  const native = { '@kit.ArkUI': { uiMaterial }, '@kit.UIDesignKit': { hdsMaterial: {} } };
  const nativeRequire = name => {
    assert.ok(Object.hasOwn(native, name), `Native, device and network I/O is prohibited: ${name}`);
    return native[name];
  };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', '$r', compiled.outputText)
    (nativeRequire, module, module.exports, id => ({ id }));
  return { ...module.exports, constructed, empty, uiMaterial };
}

function appearance(overrides = {}) {
  return { effectLevel: 2, highContrast: false, reduceMotion: false, themeMode: 0, ...overrides };
}

test('off, invalid levels and high contrast return the empty material without constructing one', () => {
  const fixture = runtime();
  for (const options of [{ effectLevel: 0 }, { effectLevel: -1 }, { effectLevel: 4 },
    { effectLevel: 2, highContrast: true }, { effectLevel: 3, highContrast: true }]) {
    assert.strictEqual(fixture.materialFor(appearance(options)), fixture.empty);
  }
  assert.deepEqual(fixture.constructed, []);
});

test('unsupported or unavailable native capabilities never construct an immersive material', () => {
  for (const options of [{ supported: false }, { capabilityThrows: true }]) {
    const fixture = runtime(options);
    for (const effectLevel of [1, 2, 3]) {
      assert.strictEqual(fixture.materialFor(appearance({ effectLevel })), fixture.empty);
    }
    assert.deepEqual(fixture.constructed, []);
  }
});

test('every immersive preset keeps touch feedback independent of the material drop shadow', () => {
  const fixture = runtime();
  for (const effectLevel of [1, 2, 3]) {
    for (const reduceMotion of [false, true]) {
      const material = fixture.materialFor(appearance({ effectLevel, reduceMotion }));
      assert.equal(material.options.applyShadow, false,
        'The material shadow overrides ordinary transparent button shadows and must remain off.');
      assert.equal(material.options.lightEffect === null, effectLevel === 1,
        'Removing the drop shadow must preserve standard/rich touch-following light.');
      assert.equal(material.options.interactive, effectLevel === 3 && !reduceMotion);
    }
  }
});

test('standard and rich keep native touch light enabled while reduced motion disables deformation', () => {
  const fixture = runtime();
  for (const effectLevel of [2, 3]) {
    const material = fixture.materialFor(appearance({ effectLevel, reduceMotion: true }));
    assert.ok(material instanceof fixture.uiMaterial.ImmersiveMaterial);
    assert.ok(material.options.lightEffect !== null && typeof material.options.lightEffect === 'object',
      'A valid LightEffectOptions object enables native touch-following light, including reduced motion.');
    assert.equal(material.options.interactive, false, 'Reduced motion must disable elastic deformation.');
  }
  assert.equal(fixture.constructed.length, 2);
});

test('gentle explicitly disables light, while ordinary rich mode retains elastic feedback', () => {
  const fixture = runtime();
  for (const reduceMotion of [false, true]) {
    const gentle = fixture.materialFor(appearance({ effectLevel: 1, reduceMotion }));
    assert.equal(gentle.options.lightEffect, null);
    assert.equal(gentle.options.interactive, false);
  }
  const standard = fixture.materialFor(appearance({ effectLevel: 2 }));
  assert.ok(standard.options.lightEffect !== null && typeof standard.options.lightEffect === 'object');
  assert.equal(standard.options.interactive, false);
  const rich = fixture.materialFor(appearance({ effectLevel: 3 }));
  assert.ok(rich.options.lightEffect !== null && typeof rich.options.lightEffect === 'object');
  assert.equal(rich.options.interactive, true);
});

test('native material construction failure returns the empty material', () => {
  const fixture = runtime({ constructorThrows: true });
  assert.strictEqual(fixture.materialFor(appearance({ effectLevel: 3, reduceMotion: true })), fixture.empty);
  assert.equal(fixture.constructed.length, 1);
});

test('reader effects reject disabled, high-contrast and malformed levels before native construction', () => {
  const fixture = runtime();
  for (const options of [{ effectLevel: 0 }, { effectLevel: -1 }, { effectLevel: 4 },
    { effectLevel: 1.5 }, { effectLevel: NaN }, { effectLevel: Infinity }, { highContrast: true }]) {
    assert.equal(fixture.readerMaterialFor(appearance(options)), undefined);
    assert.equal(fixture.readerBackdropFor(appearance(options)), undefined);
  }
  assert.deepEqual(fixture.constructed, []);
});

test('reader native failures allow a usable backdrop without pretending an empty material is native', () => {
  for (const options of [{ supported: false }, { capabilityThrows: true }, { constructorThrows: true }]) {
    const fixture = runtime(options);
    assert.equal(fixture.readerMaterialFor(appearance()), undefined);
    const backdrop = fixture.readerBackdropFor(appearance());
    assert.ok(backdrop && Number.isFinite(backdrop.radius) && backdrop.radius > 0);
    assert.equal(fixture.constructed.length, options.constructorThrows ? 1 : 0);
  }
});

test('reader light and deformation remain independent of shadows and reduced motion', () => {
  const fixture = runtime();
  for (const effectLevel of [1, 2, 3]) {
    for (const reduceMotion of [false, true]) {
      const material = fixture.readerMaterialFor(appearance({ effectLevel, reduceMotion }));
      assert.ok(material instanceof fixture.uiMaterial.ImmersiveMaterial);
      assert.equal(material.options.applyShadow, false);
      assert.equal(material.options.lightEffect === null, effectLevel === 1);
      assert.equal(material.options.interactive, effectLevel === 3 && !reduceMotion);
      assert.equal(Object.hasOwn(material.options, 'materialColor'), false,
        'The native floating surface must not introduce a second color mask.');
    }
  }
});

test('richer reader presets get more translucent while reduced motion preserves the static backdrop', () => {
  const fixture = runtime();
  const materials = [1, 2, 3].map(effectLevel =>
    fixture.readerMaterialFor(appearance({ effectLevel })).options);
  assert.ok(materials.every(options => options.style <= fixture.uiMaterial.ImmersiveStyle.THIN),
    'Floating controls use thin native surfaces rather than a regular opaque-looking mask.');
  assert.ok(materials[2].style < materials[1].style);
  const backdrops = [1, 2, 3].map(effectLevel => fixture.readerBackdropFor(appearance({ effectLevel })));
  assert.ok(backdrops[0].radius > backdrops[1].radius && backdrops[1].radius > backdrops[2].radius);
  for (const [index, backdrop] of backdrops.entries()) {
    assert.ok(backdrop.radius > 0 && backdrop.radius <= 12);
    assert.match(backdrop.color, /^#00[0-9a-f]{6}$/i,
      'The fallback must leave background text and image shapes visible instead of adding an opaque mask.');
    assert.deepEqual(fixture.readerBackdropFor(appearance({ effectLevel: index + 1, reduceMotion: true })), backdrop);
  }
});
