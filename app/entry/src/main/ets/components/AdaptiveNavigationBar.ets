import { curves, uiMaterial } from '@kit.ArkUI';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { ReaderGlassSurface } from './ReaderGlassSurface';
import { navigationMorphFrame, NavigationMorphFrame } from '../services/NavigationMorphGeometry';

interface NavigationEntry { index: number; title: string; symbol: Resource; }

/** One persistent surface and four persistent icon nodes, continuously merging to the selected icon. */
@ComponentV2
export struct AdaptiveNavigationBar {
  @Param currentIndex: number = 0;
  @Param collapsed: boolean = false;
  @Param bottomInset: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Event onSelect: (index: number) => void = (_index: number): void => {};
  @Event onExpand: () => void = (): void => {};
  @Local progress: number = 0;
  @Local availableWidth: number = 328;
  private live: boolean = false;
  private readonly entries: NavigationEntry[] = [
    { index: 0, title: '最新', symbol: $r('sys.symbol.house') },
    { index: 1, title: '分类', symbol: $r('sys.symbol.square_grid_2x2') },
    { index: 2, title: '搜索', symbol: $r('sys.symbol.magnifyingglass') },
    { index: 3, title: '我的', symbol: $r('sys.symbol.person') }
  ];

  @Computed
  get shouldCollapse(): boolean {
    return this.collapsed && !this.appearance.reduceMotion && !this.appearance.highContrast;
  }

  @Computed
  get selectedIndex(): number {
    return Number.isFinite(this.currentIndex) ? Math.max(0, Math.min(3, Math.floor(this.currentIndex))) : 0;
  }

  @Computed
  get safeBottomInset(): number {
    return Number.isFinite(this.bottomInset) && this.bottomInset >= 0 ? this.bottomInset : 0;
  }

  aboutToAppear(): void {
    this.live = true;
    this.progress = this.shouldCollapse ? 1 : 0;
  }

  aboutToDisappear(): void { this.live = false; }

  @Monitor('collapsed', 'appearance.reduceMotion', 'appearance.highContrast')
  collapseChanged(): void {
    const target: number = this.shouldCollapse ? 1 : 0;
    if (!this.live || this.appearance.reduceMotion || this.appearance.highContrast) {
      this.progress = target;
      return;
    }
    // springMotion inherits current presentation values and velocity on a rapid reversal.
    this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.95) }, (): void => {
      this.progress = target;
    });
  }

  private frame(index: number = 0): NavigationMorphFrame {
    return navigationMorphFrame(this.availableWidth, index, this.progress);
  }

  private activate(index: number): void {
    if (this.shouldCollapse) {
      if (index === this.selectedIndex) { this.onExpand(); }
      return;
    }
    this.onSelect(index);
  }

  @Builder
  private tab(entry: NavigationEntry) {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Stack({ alignContent: Alignment.TopStart }) {
        SymbolGlyph(entry.symbol).fontSize(23)
          .fontColor([entry.index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_secondary')])
          .position({ x: (this.frame(entry.index).buttonWidth - 23) / 2, y: this.frame(entry.index).iconTop })
        Text(entry.title).fontSize(12).fontWeight(entry.index === this.selectedIndex ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(entry.index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_secondary'))
          .width(this.frame(entry.index).buttonWidth).height(18).textAlign(TextAlign.Center)
          .position({ x: 0, y: 32 }).opacity(this.frame(entry.index).labelOpacity)
      }.width(this.frame(entry.index).buttonWidth).height(this.frame(entry.index).surfaceHeight)
        .hitTestBehavior(HitTestMode.None)
    }.width(this.frame(entry.index).buttonWidth).height(this.frame(entry.index).surfaceHeight)
      .position({ x: this.frame(entry.index).buttonLeft, y: 0 })
      .padding(0).borderRadius(this.frame(entry.index).surfaceHeight / 2)
      .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
      .opacity(entry.index === this.selectedIndex ? 1 : this.frame(entry.index).labelOpacity)
      .enabled(!this.shouldCollapse || entry.index === this.selectedIndex)
      .accessibilityLevel(this.shouldCollapse && entry.index !== this.selectedIndex ? 'no-hide-descendants' : 'yes')
      .accessibilitySelected(entry.index === this.selectedIndex)
      .accessibilityText(this.shouldCollapse ? `当前${entry.title}，展开底部导航` : entry.title)
      .id(this.shouldCollapse && entry.index === this.selectedIndex ? 'main_navigation_restore' : `main_navigation_tab_${entry.index}`)
      .onClick((): void => { this.activate(entry.index); })
  }

  @LocalBuilder
  navigationButtons() {
    ForEach(this.entries, (entry: NavigationEntry) => { this.tab(entry) },
      (entry: NavigationEntry): string => entry.index.toString())
  }

  build() {
    Column() {
      Row() {
        Blank().hitTestBehavior(HitTestMode.None)
        ReaderGlassSurface({ appearance: this.appearance, content: this.navigationButtons,
          radiusVp: this.frame().surfaceHeight / 2, lightId: 'main_navigation_touch_light' })
          .width(this.frame().surfaceWidth).height(this.frame().surfaceHeight).id('main_navigation_surface')
      }.width('100%').padding({ left: 16, right: 16, bottom: 12 + this.safeBottomInset })
        .onAreaChange((_previous: Area, current: Area): void => {
          const width: number = Number(current.width) - 32;
          if (Number.isFinite(width) && width >= 52 && Math.abs(this.availableWidth - width) > 0.5) {
            this.availableWidth = width;
          }
        })
    }.width('100%').height('100%').justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
