import { uiMaterial } from '@kit.ArkUI';
import { Category, TopicFeedFilterOption, topicFeedFilters } from '../models/ForumModels';
import { AppearanceSettings } from '../models/AppearanceSettings';
import { TopicFeed } from './TopicFeed';
import { readerBackdropFor } from '../services/MaterialPolicy';
import { defaultTopicFeedIndex } from '../services/ReadingPreferences';
import { TopicTaxonomySheet } from './TopicTaxonomySheet';

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
  @Param ownerId: number = 0;
  @Param barsCollapsed: boolean = false;
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
  @Local headerHeight: number = 146;
  @Local selectedCategoryId: number = 0;
  @Local selectedCategoryName: string = '';
  @Local selectedTag: string = '';
  @Local sortIndex: number = 0;
  @Local periodIndex: number = 1;
  @Local showTaxonomy: boolean = false;
  @Local taxonomyTagMode: boolean = false;
  @Local pages: HomeFeedPage[] = topicFeedFilters.map((_filter: TopicFeedFilterOption, index: number): HomeFeedPage =>
    new HomeFeedPage(index));
  private swiperController: SwiperController = new SwiperController();
  private consumedRefreshTopSignal: number = 0;
  private defaultApplied: boolean = false;
  private readonly sortValues: string[] = ['', 'activity', 'created', 'posts', 'likes', 'views'];
  private readonly sortLabels: string[] = ['默认排序', '最新回复', '最新创建', '最多回复', '最多点赞', '最多浏览'];
  private readonly periodValues: string[] = ['daily', 'weekly', 'monthly', 'quarterly', 'yearly', 'all'];
  private readonly periodLabels: string[] = ['今日', '本周', '本月', '本季度', '本年', '全部时间'];

  @Computed
  get sortOptions(): SelectOption[] { return this.sortLabels.map((label: string): SelectOption => { return { value: label }; }); }

  @Computed
  get periodOptions(): SelectOption[] { return this.periodLabels.map((label: string): SelectOption => { return { value: label }; }); }

  private appear(): void {
    if (!this.defaultApplied) {
      this.defaultApplied = true;
      this.filterIndex = defaultTopicFeedIndex(this.appearance.defaultFeed);
      this.targetIndex = this.filterIndex;
    }
    this.mounted = true;
    this.refreshCurrentFromTop();
  }

  private openTaxonomy(tagMode: boolean): void { this.taxonomyTagMode = tagMode; this.showTaxonomy = true; }

  @Monitor('ownerId')
  accountChanged(): void {
    // Taxonomy can contain account-only categories and tags; do not retain
    // their names or request scope after logout or an account switch.
    this.showTaxonomy = false;
    this.selectedCategoryId = 0; this.selectedCategoryName = ''; this.selectedTag = '';
  }

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
          Column() {
            Text(filter.label).fontSize(15).maxLines(1)
              .fontWeight(this.filterIndex === index ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.filterIndex === index ? $r('app.color.accent') : $r('app.color.text_primary'))
          }.width('100%').justifyContent(FlexAlign.Center)
        }.height(36).layoutWeight(1).padding({ left: 4, right: 4 }).borderRadius(18)
          .backgroundColor(this.filterIndex === index ? $r('app.color.surface') : Color.Transparent)
          .systemMaterial(uiMaterial.Material.empty).stateEffect(false)
          .accessibilitySelected(this.filterIndex === index).accessibilityText(filter.label)
          .id(`topic_filter_${filter.value}`).onClick(() => { this.selectFilter(index); })
      }, (filter: TopicFeedFilterOption): string => filter.value)
    }.width('100%').height(40).padding(2).borderRadius(20)
      .backgroundColor($r('app.color.page_background')).id('topic_filter_bar')
  }

  @LocalBuilder
  taxonomySheet() {
    TopicTaxonomySheet({ tagMode: this.taxonomyTagMode, selectedCategoryId: this.selectedCategoryId,
      selectedTag: this.selectedTag,
      onCategory: (category: Category | undefined): void => {
        this.selectedCategoryId = category?.id ?? 0;
        this.selectedCategoryName = category?.name ?? '';
        this.showTaxonomy = false;
      }, onTag: (name: string): void => { this.selectedTag = name; this.showTaxonomy = false; },
      onVerify: (): void => { this.showTaxonomy = false; this.onVerify(); } })
  }

  @LocalBuilder
  taxonomyFilters() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 4 }) {
          Text(this.selectedCategoryName || '全部分类').fontSize(12).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.accent'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(9).fontColor([$r('app.color.accent')])
        }
      }.height(44).constraintSize({ maxWidth: 120 }).padding({ left: 2, right: 6 })
        .backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty).id('home_category_filter')
        .accessibilityText(`筛选分类，${this.selectedCategoryName || '全部分类'}`)
        .onClick((): void => { this.openTaxonomy(false); })
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 4 }) {
          Text(this.selectedTag || '全部标签').fontSize(12).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.accent'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(9).fontColor([$r('app.color.accent')])
        }
      }.height(44).constraintSize({ maxWidth: 110 }).padding({ left: 2, right: 6 })
        .backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty).id('home_tag_filter')
        .accessibilityText(`筛选标签，${this.selectedTag || '全部标签'}`)
        .onClick((): void => { this.openTaxonomy(true); })
      Blank()
      Select(this.sortOptions).selected(this.sortIndex).value(this.sortLabels[this.sortIndex])
        .font({ size: 12 }).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent).height(44)
        .id('home_sort').onSelect((index: number): void => { this.sortIndex = index; })
    }.width('100%').height(44)
    if (this.filterIndex === 4) {
      Row() {
        Text('排行时间范围').fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Select(this.periodOptions).selected(this.periodIndex).value(this.periodLabels[this.periodIndex])
          .font({ size: 12 }).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
          .height(36).id('home_top_period').onSelect((index: number): void => { this.periodIndex = index; })
      }.width('100%').height(36)
    }
  }

  @LocalBuilder
  homeHeader() {
    Column() {
      Row({ space: 8 }) {
        Blank().width(44)
        Row({ space: 5 }) {
          Image($r('app.media.app_icon')).width(24).height(24).borderRadius(12).accessibilityLevel('no')
          Text('LINUX DO').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(22).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
          .id('home_new_topic').accessibilityText('发帖')
          .onClick(() => { this.onNewTopic(); })
      }.height(52).padding({ top: 4, bottom: 4 }).width('100%')
      this.filterButtons()
      this.taxonomyFilters()
    }.width('100%').padding({ left: 14, right: 14 }).backgroundColor(Color.Transparent)
      .onAreaChange((_old: Area, next: Area): void => { this.measureHeader(Number(next.height)); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Swiper(this.swiperController) {
        ForEach(this.pages, (page: HomeFeedPage) => {
          TopicFeed({ filterIndex: page.index, active: this.mounted && this.active && this.filterIndex === page.index,
            prefetch: this.shouldPrefetch(page.index), appearance: this.appearance,
            browseCategoryId: this.selectedCategoryId, tagName: this.selectedTag,
            sortOrder: this.sortValues[this.sortIndex], topPeriod: this.periodValues[this.periodIndex],
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
        .translate({ y: this.barsCollapsed && this.appearance.immersiveTopics ? -this.contentTopInset : 0 })
        .animation({ duration: this.appearance.reduceMotion ? 0 : 180, curve: Curve.EaseOut })
        .backgroundColor(this.appearance.effectLevel === 0 || this.appearance.highContrast ?
          $r('app.color.surface') : $r('app.color.reading_glass_tint'))
        .backgroundEffect(readerBackdropFor(this.appearance))
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .bindSheet($$this.showTaxonomy, this.taxonomySheet, { height: SheetSize.LARGE, dragBar: true, showClose: true })
      .onAppear(() => { this.appear(); })
      .onDisAppear(() => { this.mounted = false; })
  }
}
