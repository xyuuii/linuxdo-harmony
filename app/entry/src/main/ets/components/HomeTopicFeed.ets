import { uiMaterial } from '@kit.ArkUI';
import { TopicFeedFilterOption, topicFeedFilters } from '../models/ForumModels';
import { AppearanceSettings } from '../models/AppearanceSettings';
import { TopicFeed } from './TopicFeed';
import { readerBackdropFor } from '../services/MaterialPolicy';

@ObservedV2
class HomeFeedPage {
  index: number;
  scroller: Scroller = new Scroller();
  @Trace refreshSignal: number = 0;

  constructor(index: number) { this.index = index; }
}

/** Five persistent lists let native Swiper render both sides of a drag. */
@ComponentV2
export struct HomeTopicFeed {
  @Param reloadSignal: number = 0;
  @Param refreshTopSignal: number = 0;
  @Param active: boolean = true;
  @Param appearance: AppearanceSettings = new AppearanceSettings();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource, atTop: boolean) => void = (): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Event onNewTopic: () => void = (): void => {};
  @Event onSearch: () => void = (): void => {};
  @Event onCategories: () => void = (): void => {};
  @Local filterIndex: number = 0;
  @Local targetIndex: number = 0;
  @Local mounted: boolean = false;
  @Local headerHeight: number = 98;
  @Local pages: HomeFeedPage[] = topicFeedFilters.map((_filter: TopicFeedFilterOption, index: number): HomeFeedPage =>
    new HomeFeedPage(index));
  private swiperController: SwiperController = new SwiperController();
  private consumedRefreshTopSignal: number = 0;

  @Computed
  get contentTopInset(): number { return this.topInset + this.headerHeight; }

  private measureHeader(height: number): void {
    if (Number.isFinite(height) && height > 0 && Math.abs(height - this.headerHeight) > 0.5) {
      this.headerHeight = height;
    }
  }

  private validIndex(index: number): boolean {
    return Number.isInteger(index) && index >= 0 && index < this.pages.length;
  }

  private shouldPrefetch(index: number): boolean {
    return this.mounted && this.active && (Math.abs(index - this.filterIndex) <= 1 || index === this.targetIndex);
  }

  private selectFilter(index: number): void {
    if (!this.active || !this.mounted || !this.validIndex(index)) { return; }
    if (index === this.filterIndex && index === this.targetIndex) { return; }
    // Start the target request without changing the bound index first: assigning
    // index before changeIndex would jump instead of animating to its content.
    this.targetIndex = index;
    this.swiperController.changeIndex(index, !this.appearance.reduceMotion);
  }

  private pageChanged(index: number): void {
    if (!this.validIndex(index)) { return; }
    this.filterIndex = index;
    this.targetIndex = index;
  }

  private animationStarted(targetIndex: number): void {
    if (this.validIndex(targetIndex)) { this.targetIndex = targetIndex; }
  }

  private animationEnded(index: number): void {
    // End also fires on interrupted animations; use the actual settled index.
    this.pageChanged(index);
  }

  @Monitor('refreshTopSignal', 'active', 'mounted')
  refreshCurrentFromTop(): void {
    if (!this.mounted || !this.active || this.refreshTopSignal <= this.consumedRefreshTopSignal) { return; }
    this.consumedRefreshTopSignal = this.refreshTopSignal;
    this.pages[this.filterIndex].refreshSignal++;
  }

  private readPageScroll(page: HomeFeedPage, offset: number, state: ScrollState, source: ScrollSource): void {
    if (!this.active || !this.mounted || page.index !== this.filterIndex) { return; }
    this.onReadScroll(offset, state, source, page.scroller.currentOffset().yOffset + this.contentTopInset <= 1);
  }

  @LocalBuilder
  filterButtons() {
    Row() {
      ForEach(topicFeedFilters, (filter: TopicFeedFilterOption, index: number) => {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Column({ space: 5 }) {
            Text(filter.label).fontSize(16).maxLines(1)
              .fontWeight(this.filterIndex === index ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.filterIndex === index ? $r('app.color.accent') : $r('app.color.text_primary'))
            Row().width(20).height(3).borderRadius(2)
              .backgroundColor(this.filterIndex === index ? $r('app.color.accent') : Color.Transparent)
          }.width('100%').justifyContent(FlexAlign.Center)
        }.height(48).layoutWeight(1).padding({ left: 4, right: 4, top: 5, bottom: 3 })
          .backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty).stateEffect(false)
          .accessibilitySelected(this.filterIndex === index).accessibilityText(filter.label)
          .id(`topic_filter_${filter.value}`).onClick(() => { this.selectFilter(index); })
      }, (filter: TopicFeedFilterOption): string => filter.value)
    }.width('100%').height(48).id('topic_filter_bar')
  }

  @LocalBuilder
  homeHeader() {
    Column() {
      Row({ space: 10 }) {
        Row({ space: 5 }) {
          Image($r('app.media.app_icon')).width(27).height(27).borderRadius(14).accessibilityLevel('no')
          Text('LINUX DO').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        }
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17).fontColor([$r('app.color.text_secondary')])
            Text('搜索').fontSize(14).fontColor($r('app.color.text_secondary'))
          }.width('100%').justifyContent(FlexAlign.Start)
        }.height(44).layoutWeight(1).padding({ left: 13, right: 13 })
          .backgroundColor($r('app.color.page_background')).systemMaterial(uiMaterial.Material.empty)
          .id('home_search').accessibilityText('搜索话题').onClick(() => { this.onSearch(); })
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(22).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
          .id('home_new_topic').accessibilityText('发帖')
          .onClick(() => { this.onNewTopic(); })
      }.padding({ top: 4, bottom: 2 }).width('100%')
      this.filterButtons()
    }.width('100%').padding({ left: 14, right: 14 }).backgroundColor(Color.Transparent)
      .onAreaChange((_old: Area, next: Area): void => { this.measureHeader(Number(next.height)); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Swiper(this.swiperController) {
        ForEach(this.pages, (page: HomeFeedPage) => {
          TopicFeed({ filterIndex: page.index, active: this.mounted && this.active && this.filterIndex === page.index,
            prefetch: this.shouldPrefetch(page.index), appearance: this.appearance,
            reloadSignal: this.reloadSignal, refreshTopSignal: page.refreshSignal,
            listScroller: page.scroller, topInset: this.contentTopInset, bottomInset: this.bottomInset, immersiveTop: true,
            onReadScroll: (offset: number, state: ScrollState, source: ScrollSource): void => {
              this.readPageScroll(page, offset, state, source);
            },
            onOpenTopic: this.onOpenTopic, onVerify: this.onVerify, onCategories: this.onCategories })
            .width('100%').height('100%').id(`home_feed_page_${page.index}`)
        }, (page: HomeFeedPage): string => topicFeedFilters[page.index].value)
      }.index(this.filterIndex).loop(false).indicator(false).autoPlay(false).vertical(false)
        .disableSwipe(!this.active).curve(Curve.EaseOut).duration(this.appearance.reduceMotion ? 0 : 260)
        .onChange((index: number): void => { this.pageChanged(index); })
        .onAnimationStart((_index: number, targetIndex: number): void => { this.animationStarted(targetIndex); })
        .onAnimationEnd((index: number): void => { this.animationEnded(index); })
        .width('100%').height('100%').id('home_feed_pager')
      Column() { this.homeHeader() }
        .width('100%').padding({ top: this.topInset }).zIndex(1)
        .backgroundColor(this.appearance.effectLevel === 0 || this.appearance.highContrast ?
          $r('app.color.surface') : $r('app.color.reading_glass_tint'))
        .backgroundEffect(readerBackdropFor(this.appearance))
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .onAppear(() => { this.mounted = true; this.refreshCurrentFromTop(); })
      .onDisAppear(() => { this.mounted = false; })
  }
}
