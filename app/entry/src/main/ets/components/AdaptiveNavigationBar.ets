import { curves, uiMaterial } from '@kit.ArkUI';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { ReaderGlassSurface } from './ReaderGlassSurface';
import { navigationMorphFrame, NavigationMorphFrame, navigationIconSize } from '../services/NavigationMorphGeometry';

interface NavigationEntry { index: number; title: string; symbol: Resource; }

/** One persistent surface and five persistent icon nodes, continuously merging to the selected icon. */
@ComponentV2
export struct AdaptiveNavigationBar {
  @Param currentIndex: number = 0;
  @Param collapsed: boolean = false;
  @Param bottomInset: number = 0;
  @Param unreadCount: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param sideLeft: boolean = false;
  @Event onSelect: (index: number) => void = (_index: number): void => {};
  @Event onLatestDoubleTap: () => void = (): void => {};
  @Event onExpand: () => void = (): void => {};
  @Local progress: number = 0;
  @Local availableWidth: number = 328;
  @Local leftSide: boolean = false;
  @Local handOffset: number = 0;
  private live: boolean = false;
  private handGeneration: number = 0;
  private suppressDoubleTapUntil: number = 0;
  private readonly entries: NavigationEntry[] = [
    { index: 0, title: '话题', symbol: $r('sys.symbol.message') },
    { index: 1, title: '目录', symbol: $r('sys.symbol.square_grid_2x2') },
    { index: 2, title: '搜索', symbol: $r('sys.symbol.magnifyingglass') },
    { index: 3, title: '消息', symbol: $r('sys.symbol.bell') },
    { index: 4, title: '我的', symbol: $r('sys.symbol.person') }
  ];

  @Computed
  get shouldCollapse(): boolean {
    return this.collapsed && !this.appearance.reduceMotion && !this.appearance.highContrast;
  }

  @Computed
  get selectedIndex(): number {
    return Number.isFinite(this.currentIndex) ? Math.max(0, Math.min(4, Math.floor(this.currentIndex))) : 0;
  }

  @Computed
  get safeUnreadCount(): number {
    return Number.isFinite(this.unreadCount) ? Math.max(0, Math.floor(this.unreadCount)) : 0;
  }

  @Computed
  get unreadBadgeWidth(): number { return this.safeUnreadCount > 99 ? 24 : this.safeUnreadCount > 9 ? 20 : 16; }

  @Computed
  get safeBottomInset(): number {
    return Number.isFinite(this.bottomInset) && this.bottomInset >= 0 ? this.bottomInset : 0;
  }

  aboutToAppear(): void {
    this.live = true;
    this.progress = this.shouldCollapse ? 1 : 0;
    this.leftSide = this.sideLeft;
  }

  aboutToDisappear(): void { this.live = false; this.handGeneration++; }

  @Monitor('sideLeft')
  handChanged(): void {
    const generation: number = ++this.handGeneration;
    if (!this.live || !this.shouldCollapse || this.progress < 0.99) {
      this.leftSide = this.sideLeft; this.handOffset = 0; return;
    }
    // Official Smart Reach pattern: exit the current edge, enter from the other edge.
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseIn,
      onFinish: (): void => {
        if (!this.live || generation !== this.handGeneration) { return; }
        this.leftSide = this.sideLeft;
        this.handOffset = this.leftSide ? -72 : 72;
        this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.95) }, (): void => {
          this.handOffset = 0;
        });
      } }, (): void => { this.handOffset = this.leftSide ? -72 : 72; });
  }

  @Monitor('collapsed', 'appearance.reduceMotion', 'appearance.highContrast')
  collapseChanged(): void {
    this.handGeneration++;
    this.handOffset = 0;
    this.leftSide = this.sideLeft;
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
    return navigationMorphFrame(this.availableWidth, index, this.progress, this.leftSide);
  }

  private activate(index: number): void {
    if (this.shouldCollapse) {
      if (index === this.selectedIndex) {
        this.suppressDoubleTapUntil = Date.now() + 400;
        this.onExpand();
      }
      return;
    }
    this.onSelect(index);
  }

  @Builder
  private tab(entry: NavigationEntry) {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Stack({ alignContent: Alignment.TopStart }) {
        SymbolGlyph(entry.symbol).fontSize(navigationIconSize)
          .fontColor([entry.index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_secondary')])
          .position({ x: (this.frame(entry.index).buttonWidth - navigationIconSize) / 2, y: this.frame(entry.index).iconTop })
        Text(entry.title).fontSize(11).fontWeight(entry.index === this.selectedIndex ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(entry.index === this.selectedIndex ? $r('app.color.accent') : $r('app.color.text_secondary'))
          .width(this.frame(entry.index).buttonWidth).height(16).textAlign(TextAlign.Center)
          .position({ x: 0, y: 29 }).opacity(this.frame(entry.index).labelOpacity)
        if (entry.index === 3 && this.safeUnreadCount > 0) {
          Text(this.safeUnreadCount > 99 ? '99+' : String(this.safeUnreadCount))
            .fontSize(10).fontWeight(FontWeight.Medium).fontColor(Color.White)
            .backgroundColor('#C5473C').borderRadius(9).textAlign(TextAlign.Center)
            .width(this.unreadBadgeWidth).height(16)
            .position({ x: Math.min(this.frame(entry.index).buttonWidth - this.unreadBadgeWidth - 2,
              this.frame(entry.index).buttonWidth / 2 + 5), y: this.frame(entry.index).iconTop - 3 })
            .id('main_navigation_unread_badge')
        }
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
      .accessibilityText(`${this.shouldCollapse ? `当前${entry.title}，展开底部导航` : entry.title}${entry.index === 3 ? `，${this.safeUnreadCount} 条未读` : ''}`)
      .accessibilityDescription(!this.shouldCollapse && entry.index === 0 ? '双击回到话题列表顶部并刷新' : '')
      .id(this.shouldCollapse && entry.index === this.selectedIndex ? 'main_navigation_restore' : `main_navigation_tab_${entry.index}`)
      .onClick((): void => { this.activate(entry.index); })
      .parallelGesture(TapGesture({ count: 2 }).onAction((): void => {
        if (entry.index === 0 && !this.shouldCollapse && Date.now() > this.suppressDoubleTapUntil) {
          this.onLatestDoubleTap();
        }
      }))
  }

  @LocalBuilder
  navigationButtons() {
    ForEach(this.entries, (entry: NavigationEntry) => { this.tab(entry) },
      (entry: NavigationEntry): string => entry.index.toString())
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ReaderGlassSurface({ appearance: this.appearance, content: this.navigationButtons, nativeBar: true,
          radiusVp: this.frame().surfaceHeight / 2, lightId: 'main_navigation_touch_light' })
          .width(this.frame().surfaceWidth).height(this.frame().surfaceHeight).id('main_navigation_surface')
          .position({ x: this.frame().surfaceLeft + this.handOffset, y: 0 })
      }.width('100%').height(this.frame().surfaceHeight + this.safeBottomInset)
        .padding({ left: 16, right: 16, bottom: this.safeBottomInset })
        .onAreaChange((_previous: Area, current: Area): void => {
          const width: number = Number(current.width) - 32;
          if (Number.isFinite(width) && width >= 48 && Math.abs(this.availableWidth - width) > 0.5) {
            this.availableWidth = width;
          }
        })
    }.width('100%').height('100%').justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
