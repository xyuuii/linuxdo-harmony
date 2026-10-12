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
const readSource = name => readFileSync(fileURLToPath(new URL(`../app/entry/src/main/ets/${name}.ets`, import.meta.url)), 'utf8');

function load(value, bindings = {}) {
  const compiled = ts.transpileModule(value, {
    fileName: 'main-navigation-production-extract.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('module', 'exports', ...Object.keys(bindings), compiled.outputText)
    (module, module.exports, ...Object.values(bindings));
  return module.exports;
}

const indexSource = readSource('pages/Index');
const start = indexSource.indexOf('  private navigationScroller(');
const end = indexSource.indexOf("  @Monitor('appearance.themeMode')", start);
assert.ok(start >= 0 && end > start, 'The production navigation-control method block must remain extractable.');
const methods = indexSource.slice(start, end).replace(/^\s*@Monitor\([^\n]*\)\s*\n/gm, '\n');
const notificationsStart = indexSource.indexOf('  private openNotifications(');
const notificationsEnd = indexSource.indexOf('  private openCategory(', notificationsStart);
assert.ok(notificationsStart >= 0 && notificationsEnd > notificationsStart);
const notificationNavigation = indexSource.slice(notificationsStart, notificationsEnd);
const { TopicScrollPolicy } = load(readSource('services/TopicScrollPolicy'));
const ScrollSource = { DRAG: 1, FLING: 2, OTHER_USER_INPUT: 3, SCROLLER: 4, SCROLLER_ANIMATION: 5, NONE: 0 };
const ScrollState = { Scroll: 1, Fling: 2, Idle: 0 };
const { IndexNavigation } = load(`export class IndexNavigation {\n${methods}\n${notificationNavigation}\n}`, {
  ScrollSource
});

// Only production navigation methods and the real pure scroll policy run here.
// The single AdaptiveNavigationBar owns visual interpolation; native geometry
// and animation continuity still require device acceptance. No UI, Web,
// cookies or device I/O are loaded.
function navigationRuntime() {
  const scrollers = Array.from({ length: 5 }, (_, index) => ({
    index, offset: 300, reads: 0,
    currentOffset() { this.reads++; return { xOffset: 0, yOffset: this.offset }; }
  }));
  let pathDepth = 0;
  const tabChanges = [];
  const routeEvents = [];
  const navigation = new IndexNavigation();
  Object.assign(navigation, {
    latestScroller: scrollers[0], categoriesScroller: scrollers[1],
    searchScroller: scrollers[2], notificationsScroller: scrollers[3], profileScroller: scrollers[4],
    navigationScrollPolicy: new TopicScrollPolicy(),
    navigationCollapsed: false, currentIndex: 0, showBrowser: false, mainPageVisible: true, topInset: 64,
    appearance: { reduceMotion: false, highContrast: false },
    paths: { size: () => pathDepth, clear: () => { pathDepth = 0; routeEvents.push('clear'); } },
    controller: { changeIndex: index => { tabChanges.push(index); routeEvents.push(`tab:${index}`); } }
  });
  return { navigation, scrollers, tabChanges, routeEvents, setPathDepth: depth => { pathDepth = depth; } };
}

test('all five pages resolve distinct retained Scrollers and keep their original offsets across page changes', () => {
  const { navigation, scrollers } = navigationRuntime();
  assert.equal(new Set([0, 1, 2, 3, 4].map(index => navigation.navigationScroller(index))).size, 5);
  scrollers.forEach((scroller, index) => {
    scroller.offset = (index + 1) * 100;
    assert.strictEqual(navigation.navigationScroller(index), scroller);
  });
  for (const index of [4, 3, 2, 1, 0, 2, 3, 4]) {
    navigation.currentIndex = index;
    navigation.resetNavigation();
    navigation.readNavigationScroll(index, 40, ScrollState.Scroll, ScrollSource.SCROLLER);
    assert.strictEqual(navigation.navigationScroller(index), scrollers[index]);
    assert.equal(navigation.navigationScroller(index).currentOffset().yOffset, (index + 1) * 100);
  }
});

test('each active page collapses while reading forward and expands for reverse reading, reset or returning to the beginning', () => {
  for (let index = 0; index < 5; index++) {
    const { navigation, scrollers } = navigationRuntime();
    navigation.currentIndex = index;
    navigation.readNavigationScroll(index, 20, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
    navigation.readNavigationScroll(index, 12, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true);
    navigation.readNavigationScroll(index, 64, ScrollState.Fling, ScrollSource.FLING);
    assert.equal(navigation.navigationCollapsed, true);
    navigation.readNavigationScroll(index, -8, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true);
    navigation.readNavigationScroll(index, -8, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);

    navigation.readNavigationScroll(index, 32, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true);
    // The persistent bar's expand affordance calls this production reset.
    navigation.resetNavigation();
    assert.equal(navigation.navigationCollapsed, false);
    navigation.readNavigationScroll(index, 31, ScrollState.Scroll, ScrollSource.DRAG);
    navigation.resetNavigation();
    navigation.readNavigationScroll(index, 1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false, 'Reset must clear partial forward travel.');
    navigation.readNavigationScroll(index, 31, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true);
    scrollers[index].offset = index === 1 ? -navigation.topInset : 0;
    navigation.readNavigationScroll(index, -1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false, 'The beginning always exposes the complete navigation.');
    assert.equal(scrollers.filter(scroller => scroller.reads > 0).length, 1);
    assert.ok(scrollers[index].reads > 0);
  }
});

test('inactive pages, authentication, child routes, accessibility overrides and programmatic scrolling cannot accidentally collapse navigation', () => {
  const inactive = navigationRuntime();
  inactive.navigation.currentIndex = 2;
  inactive.navigation.readNavigationScroll(0, 100, ScrollState.Scroll, ScrollSource.DRAG);
  assert.equal(inactive.navigation.navigationCollapsed, false);
  assert.equal(inactive.scrollers[0].reads, 0, 'A background page must not even read its navigation scroll state.');

  for (const blocker of ['hidden-root', 'browser', 'child', 'motion', 'contrast', 'programmatic', 'animated-programmatic', 'none']) {
    const { navigation, setPathDepth } = navigationRuntime();
    navigation.readNavigationScroll(0, 31, ScrollState.Scroll, ScrollSource.DRAG);
    let source = ScrollSource.DRAG;
    if (blocker === 'hidden-root') { navigation.mainPageVisible = false; }
    else if (blocker === 'browser') { navigation.showBrowser = true; }
    else if (blocker === 'child') { setPathDepth(1); }
    else if (blocker === 'motion') { navigation.appearance.reduceMotion = true; }
    else if (blocker === 'contrast') { navigation.appearance.highContrast = true; }
    else if (blocker === 'programmatic') { source = ScrollSource.SCROLLER; }
    else if (blocker === 'animated-programmatic') { source = ScrollSource.SCROLLER_ANIMATION; }
    else { source = ScrollSource.NONE; }
    navigation.readNavigationScroll(0, 100, ScrollState.Scroll, source);
    assert.equal(navigation.navigationCollapsed, false, blocker);
    navigation.mainPageVisible = true;
    navigation.showBrowser = false;
    setPathDepth(0);
    navigation.appearance.reduceMotion = false;
    navigation.appearance.highContrast = false;
    navigation.readNavigationScroll(0, 1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false, `${blocker} must clear prior partial scroll accumulation.`);
  }
  for (const option of ['reduceMotion', 'highContrast']) {
    const { navigation } = navigationRuntime();
    navigation.readNavigationScroll(0, 32, ScrollState.Scroll, ScrollSource.DRAG);
    navigation.appearance[option] = true;
    navigation.navigationAccessibilityChanged();
    navigation.readNavigationScroll(0, 100, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
    navigation.setNavigationCollapsed(true);
    assert.equal(navigation.navigationCollapsed, false, 'An accessibility override prevents explicit collapse too.');
  }
});

test('actual root visibility blocks hidden-page scrolling and restores expanded navigation with cleared partial travel', () => {
  for (const hiddenScroll of [false, true]) {
    const { navigation } = navigationRuntime();
    navigation.readNavigationScroll(0, 31, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
    navigation.rootVisibilityChanged(false);
    assert.equal(navigation.mainPageVisible, false);
    if (hiddenScroll) {
      navigation.readNavigationScroll(0, 100, ScrollState.Scroll, ScrollSource.DRAG);
      assert.equal(navigation.navigationCollapsed, false, 'A hidden root cannot react to a retained page scroll.');
    }
    navigation.rootVisibilityChanged(true);
    assert.equal(navigation.mainPageVisible, true);
    navigation.readNavigationScroll(0, 1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false, 'Returning to the root clears its previous partial threshold.');
    navigation.readNavigationScroll(0, 31, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true, 'New visible-page travel still collapses normally.');
    navigation.rootVisibilityChanged(false);
    navigation.rootVisibilityChanged(true);
    assert.equal(navigation.navigationCollapsed, false, 'Returning from a child page reveals the entire main navigation.');
    navigation.readNavigationScroll(0, 1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
  }
});

test('fixed-header pages start at zero while the inset-backed category page starts at minus topInset', () => {
  for (let index = 0; index < 5; index++) {
    const { navigation, scrollers } = navigationRuntime();
    navigation.currentIndex = index;
    // Only categories use contentStartOffset=topInset. The fixed home header,
    // search/messages/profile sit outside their lists, whose native start is zero.
    const initialOffset = index === 1 ? -navigation.topInset : 0;
    scrollers[index].offset = initialOffset;
    navigation.readNavigationScroll(index, 0, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
    scrollers[index].offset = initialOffset + 16;
    navigation.readNavigationScroll(index, 16, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false);
    scrollers[index].offset = initialOffset + 32;
    if (index === 1) { assert.ok(scrollers[index].offset < 0); }
    else { assert.equal(scrollers[index].offset, 32); }
    navigation.readNavigationScroll(index, 16, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, true,
      'Reading 32 vp collapses each page, including categories whose native offset remains negative.');
    scrollers[index].offset = initialOffset;
    navigation.readNavigationScroll(index, -1, ScrollState.Scroll, ScrollSource.DRAG);
    assert.equal(navigation.navigationCollapsed, false,
      'The final one-vp step to the real start expands immediately, without waiting for reverse-travel hysteresis.');
  }
});

test('notification shortcuts expose the retained messages tab and leave no duplicate child route', () => {
  for (const initialDepth of [0, 1, 3]) {
    const { navigation, scrollers, tabChanges, routeEvents, setPathDepth } = navigationRuntime();
    navigation.currentIndex = 4;
    navigation.mainPageVisible = initialDepth === 0;
    navigation.navigationCollapsed = true;
    setPathDepth(initialDepth);
    scrollers[3].offset = 420;
    navigation.openNotifications();
    assert.equal(navigation.paths.size(), 0);
    assert.equal(navigation.mainPageVisible, true);
    assert.equal(navigation.navigationCollapsed, false);
    assert.equal(navigation.currentIndex, 3);
    assert.deepEqual(tabChanges, [3]);
    assert.deepEqual(routeEvents, initialDepth > 0 ? ['clear', 'tab:3'] : ['tab:3']);
    assert.strictEqual(navigation.navigationScroller(navigation.currentIndex), scrollers[3]);
    assert.equal(scrollers[3].offset, 420, 'The shortcut must preserve the retained notification list position.');
  }
});
