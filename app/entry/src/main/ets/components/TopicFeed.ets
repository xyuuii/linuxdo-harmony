import { Category, TopicListItem, TopicPage, TopicFeedFilter, topicFeedFilters, flattenCategories } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { AppearanceSettings } from '../models/AppearanceSettings';
import { TopicRow, PinnedTopicsBlock, ForumErrorView } from './ForumComponents';
import { splitTopicFeed, TopicFeedSections } from '../services/TopicFeedPresentation';
import { firstUnreadPostNumber } from '../services/ReadingPreferences';

@ComponentV2
export struct TopicFeed {
  @Param title: string = '最新';
  @Param categoryId: number = 0;
  @Param categorySlug: string = '';
  @Param browseCategoryId: number = 0;
  @Param tagName: string = '';
  @Param sortOrder: string = '';
  @Param topPeriod: string = 'weekly';
  @Param reloadSignal: number = 0;
  @Param refreshTopSignal: number = 0;
  @Param active: boolean = true;
  @Param prefetch: boolean = false;
  @Param filterIndex: number = 0;
  @Param appearance: AppearanceSettings = new AppearanceSettings();
  @Param listScroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param immersiveTop: boolean = false;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Event onCategories: () => void = (): void => {};
  @Local items: TopicListItem[] = [];
  @Local page: number = 0;
  @Local hasMore: boolean = true;
  @Local busy: boolean = false;
  @Local refreshing: boolean = false;
  @Local loaded: boolean = false;
  @Local error: string = '';
  @Local needsVerification: boolean = false;
  private generation: number = 0;
  private request: RequestCancellation | undefined = undefined;
  private autoTimer: number = -1;
  private visible: boolean = false;
  private consumedRefreshTopSignal: number = 0;
  private pendingTopRefresh: boolean = false;
  private requestIsInitial: boolean = false;

  @Computed
  get sections(): TopicFeedSections { return splitTopicFeed(this.items); }

  private openItem(item: TopicListItem): void {
    this.onOpenTopic(item.topic.id, firstUnreadPostNumber(item.topic.lastReadPostNumber ?? 0,
      item.topic.highestPostNumber ?? item.topic.postsCount, this.appearance.openAtUnread));
  }

  @Monitor('browseCategoryId', 'tagName', 'sortOrder', 'topPeriod')
  browseChanged(): void {
    this.onReload();
    try { this.listScroller.scrollEdge(Edge.Top); } catch (_) {}
  }

  @Monitor('refreshTopSignal', 'active')
  refreshLatestFromTop(): void {
    if (!this.visible || !this.active || this.categoryId > 0) {
      // A home refresh belongs only to the page selected when it was requested.
      this.consumedRefreshTopSignal = this.refreshTopSignal;
      this.pendingTopRefresh = false;
      return;
    }
    if (this.refreshTopSignal > this.consumedRefreshTopSignal) {
      this.consumedRefreshTopSignal = this.refreshTopSignal;
      // Use the native List edge so refresh always starts at the actual content origin.
      try { this.listScroller.scrollEdge(Edge.Top); } catch (_) {}
      this.pendingTopRefresh = true;
    }
    if (!this.pendingTopRefresh || this.busy) { return; }
    this.pendingTopRefresh = false;
    this.refreshing = true;
    void this.load(true);
  }

  private refreshFromPull(): void {
    // Setting refreshing from the tab signal may also emit native onRefreshing.
    if (!this.visible || !this.active || this.busy) { return; }
    this.refreshing = true;
    void this.load(true);
  }

  private ensureInitialContent(): void {
    if (!this.visible || (!this.active && !this.prefetch)) { return; }
    if (!this.loaded && !this.busy && !this.error) { void this.load(true); }
    if (this.items.some((item: TopicListItem): boolean => item.topic.categoryId > 0 && item.category === undefined)) {
      void this.fillCategories(this.generation);
    }
  }

  private appear(): void {
    this.visible = true;
    this.refreshLatestFromTop();
    this.ensureInitialContent();
    this.configureTimer();
  }

  private cancelRequest(): void {
    this.request?.cancel();
    this.request = undefined;
    this.generation++;
    this.busy = false;
    this.refreshing = false;
    this.requestIsInitial = false;
  }

  private disappear(): void {
    this.visible = false;
    this.cancelRequest();
    this.pendingTopRefresh = false;
    this.consumedRefreshTopSignal = this.refreshTopSignal;
    // Swiper may detach distant pages. Their data and native Scroller survive.
    this.configureTimer();
  }

  @Monitor('reloadSignal')
  onReload(): void {
    this.cancelRequest();
    this.pendingTopRefresh = false;
    this.consumedRefreshTopSignal = this.refreshTopSignal;
    this.items = []; this.page = 0; this.hasMore = true; this.loaded = false;
    this.error = ''; this.needsVerification = false;
    // Login/logout invalidates every cached page. Only the current page and its
    // prefetched neighbors start new-session requests immediately.
    this.ensureInitialContent();
  }

  @Monitor('active', 'prefetch', 'appearance.autoRefresh')
  onRefreshPolicy(): void {
    if (!this.active) {
      this.pendingTopRefresh = false;
      this.consumedRefreshTopSignal = this.refreshTopSignal;
      // A neighboring page may finish its first prefetch. Background refreshes
      // and pagination never compete with the page the reader is using.
      if (!this.prefetch || !this.requestIsInitial) { this.cancelRequest(); }
    }
    this.refreshLatestFromTop();
    this.ensureInitialContent();
    this.configureTimer();
  }

  private configureTimer(): void {
    if (this.autoTimer >= 0) { clearInterval(this.autoTimer); this.autoTimer = -1; }
    if (this.visible && this.active && this.appearance.autoRefresh) {
      this.autoTimer = setInterval(() => {
        if (this.visible && this.active && !this.busy) { void this.load(true); }
      }, 600000);
    }
  }

  private loadNextPage(): void {
    if (this.visible && this.active && this.loaded && this.hasMore && !this.busy && !this.error) {
      void this.load(false);
    }
  }

  private readScroll(offset: number, state: ScrollState, source: ScrollSource): ScrollResult {
    if (this.visible && this.active) { this.onReadScroll(offset, state, source); }
    return { offsetRemain: offset };
  }

  private async fillCategories(generation: number): Promise<void> {
    try {
      // This shares ForumApi's cache/in-flight request with category and reader pages.
      // Topic text is already visible; missing taxonomy must never block the feed.
      const categories: Category[] = flattenCategories(await forumApi.fetchCategories());
      if (this.generation !== generation) { return; }
      this.items = this.items.map((item: TopicListItem): TopicListItem => {
        return { topic: item.topic, authorUsername: item.authorUsername, avatarUrl: item.avatarUrl,
          category: categories.find((category: Category): boolean => category.id === item.topic.categoryId) };
      });
    } catch (_) {}
  }

  private async load(reset: boolean): Promise<void> {
    if (!this.visible || (!this.active && (!this.prefetch || this.loaded || !reset))) { return; }
    if (this.busy && !reset) { return; }
    this.request?.cancel();
    const token: RequestCancellation = new RequestCancellation();
    this.request = token;
    const generation: number = ++this.generation;
    this.busy = true;
    this.requestIsInitial = reset && !this.loaded;
    this.error = '';
    this.needsVerification = false;
    const page: number = reset ? 0 : this.page + 1;
    const filter: TopicFeedFilter = topicFeedFilters[this.filterIndex].value;
    try {
      const result: TopicPage = this.categoryId > 0 ?
        await forumApi.fetchCategoryTopics(this.categorySlug, this.categoryId, page, token) :
        await forumApi.fetchTopicFeed(filter, page, token, { categoryId: this.browseCategoryId,
          tagName: this.tagName, sortOrder: this.sortOrder, topPeriod: this.topPeriod });
      if (this.generation !== generation) { return; }
      const combined: TopicListItem[] = reset ? result.items : this.items.concat(result.items);
      const seen: Set<number> = new Set<number>();
      this.items = combined.filter((item: TopicListItem): boolean => {
        if (seen.has(item.topic.id)) { return false; }
        seen.add(item.topic.id); return true;
      });
      this.page = page;
      this.hasMore = result.hasMore;
      this.loaded = true;
      if (this.items.some((item: TopicListItem): boolean => item.topic.categoryId > 0 && item.category === undefined)) {
        void this.fillCategories(generation);
      }
    } catch (error) {
      if (this.generation !== generation) { return; }
      this.error = error instanceof ForumApiError ? error.message : '话题暂时无法加载，请检查网络后重试。';
      this.needsVerification = error instanceof ForumApiError &&
        (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
    } finally {
      if (this.generation === generation) {
        this.busy = false; this.refreshing = false; this.requestIsInitial = false;
        this.request = undefined;
        this.refreshLatestFromTop();
      }
    }
  }

  @LocalBuilder
  loadingRow() {
    Column({ space: 11 }) {
      Row().height(17).width('88%').borderRadius(4).backgroundColor($r('app.color.divider')).opacity(0.6)
      Row().height(15).width('64%').borderRadius(4).backgroundColor($r('app.color.divider')).opacity(0.45)
      Row({ space: 9 }) {
        Row().width(20).height(20).borderRadius(10).backgroundColor($r('app.color.divider')).opacity(0.45)
        Row().width('36%').height(11).borderRadius(3).backgroundColor($r('app.color.divider')).opacity(0.4)
        Blank()
        Row().width(42).height(11).borderRadius(3).backgroundColor($r('app.color.divider')).opacity(0.4)
      }.width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 20, bottom: 20, left: 3, right: 3 })
      .accessibilityGroup(true).accessibilityText('话题正在加载')
  }

  build() {
    Column() {
      Refresh({ refreshing: this.refreshing }) {
        List({ scroller: this.listScroller, space: 0 }) {
          if (this.categoryId === 0 && !this.immersiveTop && !this.tagName) {
            ListItem() {
              Row() {
                Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                  Row({ space: 4 }) {
                    Text('浏览分类').fontSize(12).fontColor($r('app.color.accent'))
                    SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(10).fontColor([$r('app.color.accent')])
                  }
                }.height(42).padding({ left: 3, right: 12 }).backgroundColor(Color.Transparent)
                  .id('topic_browse_categories').onClick(() => { this.onCategories(); })
                Blank()
                Text(this.filterIndex === 4 ? '本周排行' : this.filterIndex === 1 ? '新话题' :
                  this.filterIndex === 2 ? '有未读回复的话题' : this.filterIndex === 3 ? '社区热门' : '最新动态')
                  .fontSize(11).fontColor($r('app.color.text_secondary')).padding({ right: 3 })
              }.width('100%').padding({ top: 3, bottom: 1 })
            }
          }
          if (!this.loaded && this.items.length === 0 && !this.error) {
            ForEach([0, 1, 2, 3], (row: number) => {
              ListItem() { this.loadingRow() }
            }, (row: number): string => `feed_loading_${row}`)
          }
          if (this.sections.pinned.length > 0) {
            ForEach(this.sections.pinned, (item: TopicListItem) => {
              ListItem() { TopicRow({ item: item, onOpen: (): void => { this.openItem(item); } }) }
            }, (item: TopicListItem): string => JSON.stringify(item))
          }
          ForEach(this.sections.topics, (item: TopicListItem) => {
            ListItem() { TopicRow({ item: item, onOpen: (): void => { this.openItem(item); } }) }
          }, (item: TopicListItem): string => JSON.stringify(item))
          ListItem() {
            if (this.error.length > 0) {
              ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
                onRetry: (): void => { void this.load(this.items.length === 0); }, onVerify: this.onVerify })
            } else if (this.busy && this.items.length > 0) {
              Row({ space: 12 }) {
                LoadingProgress().width(24).height(24)
                Text('正在加载话题').fontSize(14).fontColor($r('app.color.text_secondary'))
              }.justifyContent(FlexAlign.Center).width('100%').padding(24)
            } else if (this.items.length === 0 && this.loaded) {
              Text(this.filterIndex === 1 ? '暂时没有新话题' : this.filterIndex === 2 ? '你已读完所有关注的话题' : '这里还没有话题')
                .fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Center).padding(24)
            } else if (this.loaded && this.hasMore) {
              Button('加载更多', { type: ButtonType.Capsule }).width('100%').height(48)
                .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent')).onClick(() => { this.loadNextPage(); })
            } else if (this.loaded) {
              Text('已浏览全部话题').fontSize(13).fontColor($r('app.color.text_secondary'))
                .width('100%').textAlign(TextAlign.Center).padding(24)
            }
          }
        }.width('100%').height('100%').padding({ left: 14, right: 14 }).backgroundColor($r('app.color.surface')).id('topic_feed_list')
        .contentStartOffset(this.categoryId > 0 || this.immersiveTop ? this.topInset : 0)
        .contentEndOffset((this.categoryId > 0 ? 12 : 92) + this.bottomInset)
        .scrollBar(BarState.Off).onWillScroll((offset: number, state: ScrollState, source: ScrollSource): ScrollResult => {
          return this.readScroll(offset, state, source);
        })
        .onReachEnd(() => { this.loadNextPage(); })
      }.width('100%').layoutWeight(1).onRefreshing(() => { this.refreshFromPull(); })
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .onAppear(() => { this.appear(); })
      .onDisAppear(() => { this.disappear(); })
  }
}
