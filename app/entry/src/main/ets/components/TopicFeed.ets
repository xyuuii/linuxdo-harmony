import { TopicListItem, TopicPage } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';
import { AppearanceSettings } from '../models/AppearanceSettings';
import { TopicRow, ForumErrorView } from './ForumComponents';

@ComponentV2
export struct TopicFeed {
  @Param title: string = '最新';
  @Param categoryId: number = 0;
  @Param categorySlug: string = '';
  @Param reloadSignal: number = 0;
  @Param active: boolean = true;
  @Param appearance: AppearanceSettings = new AppearanceSettings();
  @Param listScroller: Scroller = new Scroller();
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Event onNotifications: () => void = (): void => {};
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

  @Monitor('reloadSignal')
  onReload(): void {
    this.request?.cancel(); this.generation++;
    this.items = []; this.page = 0; this.hasMore = false; this.loaded = false;
    void this.load(true);
  }

  @Monitor('active', 'appearance.autoRefresh')
  onRefreshPolicy(): void { this.configureTimer(); }

  private configureTimer(): void {
    if (this.autoTimer >= 0) { clearInterval(this.autoTimer); this.autoTimer = -1; }
    if (this.active && this.appearance.autoRefresh) {
      this.autoTimer = setInterval(() => { if (!this.busy) { void this.load(true); } }, 600000);
    }
  }

  private async load(reset: boolean): Promise<void> {
    if (this.busy && !reset) { return; }
    this.request?.cancel();
    const token: RequestCancellation = new RequestCancellation();
    this.request = token;
    const generation: number = ++this.generation;
    this.busy = true;
    this.error = '';
    this.needsVerification = false;
    const page: number = reset ? 0 : this.page + 1;
    try {
      const result: TopicPage = this.categoryId > 0 ?
        await forumApi.fetchCategoryTopics(this.categorySlug, this.categoryId, page, token) :
        await forumApi.fetchLatest(page, token);
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
    } catch (error) {
      if (this.generation !== generation) { return; }
      this.error = error instanceof ForumApiError ? error.message : '话题暂时无法加载，请检查网络后重试。';
      this.needsVerification = error instanceof ForumApiError &&
        (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
    } finally {
      if (this.generation === generation) { this.busy = false; this.refreshing = false; }
    }
  }

  build() {
    Refresh({ refreshing: this.refreshing }) {
      List({ scroller: this.listScroller, space: 6 }) {
        if (this.categoryId === 0) {
          ListItem() {
            Row({ space: 12 }) {
              Text(this.title).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Button({ type: ButtonType.Circle }) {
                Stack({ alignContent: Alignment.TopEnd }) {
                  SymbolGlyph($r('sys.symbol.bell')).fontSize(22).fontColor([$r('app.color.text_primary')])
                  if (forumSession.unread > 0) {
                    Text(forumSession.unread > 99 ? '99+' : String(forumSession.unread)).fontSize(10).fontColor(Color.White)
                      .backgroundColor('#C5473C').borderRadius(10).padding({ left: 4, right: 4 }).translate({ x: 9, y: -6 })
                  }
                }
              }.width(44).height(44).backgroundColor($r('app.color.surface')).id('open_notifications')
                .accessibilityText(`通知，${forumSession.unread} 条未读`).onClick(() => { this.onNotifications(); })
            }.padding({ top: 8, bottom: 4 }).width('100%')
          }
        }
        ForEach(this.items, (item: TopicListItem) => {
          ListItem() { TopicRow({ item: item, onOpen: (id: number): void => { this.onOpenTopic(id, 1); } }) }
        }, (item: TopicListItem): string => String(item.topic.id))
        ListItem() {
          if (this.error.length > 0) {
            ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
              onRetry: (): void => { void this.load(this.items.length === 0); }, onVerify: this.onVerify })
          } else if (this.busy) {
            Row({ space: 12 }) {
              LoadingProgress().width(24).height(24)
              Text('正在加载话题').fontSize(14).fontColor($r('app.color.text_secondary'))
            }.justifyContent(FlexAlign.Center).width('100%').padding(24)
          } else if (this.items.length === 0 && this.loaded) {
            Text('这里还没有话题').fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Center).padding(24)
          } else if (this.hasMore) {
            Button('加载更多', { type: ButtonType.Capsule }).width('100%').height(48)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent')).onClick(() => { void this.load(false); })
          } else {
            Text('已浏览全部话题').fontSize(13).fontColor($r('app.color.text_secondary'))
              .width('100%').textAlign(TextAlign.Center).padding(24)
          }
        }
      }.width('100%').height('100%').padding({ left: 14, right: 14 }).id('topic_feed_list')
        .contentEndOffset(this.categoryId > 0 ? 12 : 92)
        .scrollBar(BarState.Off).onWillScroll(this.onReadScroll)
        .onReachEnd(() => { if (this.loaded && this.hasMore && !this.busy && !this.error) { void this.load(false); } })
    }.width('100%').height('100%').onRefreshing(() => { this.refreshing = true; void this.load(true); })
      .onAppear(() => { if (!this.loaded) { void this.load(true); } this.configureTimer(); })
      .onDisAppear(() => { this.request?.cancel(); if (this.autoTimer >= 0) { clearInterval(this.autoTimer); this.autoTimer = -1; } })
  }
}
