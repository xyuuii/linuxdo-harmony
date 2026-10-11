import { TopicListItem, SearchOrder, SearchPage as SearchResultPage, searchOrders } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { ForumErrorView, TopicRow } from '../components/ForumComponents';
import { plainText } from '../services/ForumPresentation';

@ComponentV2
export struct SearchPage {
  @Param reloadSignal: number = 0;
  @Param listScroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Local query: string = '';
  @Local submittedQuery: string = '';
  @Local orderIndex: number = 0;
  @Local items: TopicListItem[] = [];
  @Local excerpts: Map<number, string> = new Map<number, string>();
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local needsVerification: boolean = false;
  @Local hasMore: boolean = false;
  @Local page: number = 1;
  @Local searched: boolean = false;
  private request: RequestCancellation | undefined = undefined;

  @Monitor('reloadSignal')
  reload(): void {
    this.request?.cancel(); this.request = undefined;
    this.items = []; this.excerpts = new Map<number, string>(); this.hasMore = false;
    this.searched = false; this.busy = false; this.error = ''; this.query = ''; this.submittedQuery = '';
  }

  private async search(reset: boolean): Promise<void> {
    const query: string = reset ? this.query.trim() : this.submittedQuery;
    if (!query) { return; }
    if (this.busy && !reset) { return; }
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsVerification = false;
    const page: number = reset ? 1 : this.page + 1;
    try {
      const order: SearchOrder = searchOrders[this.orderIndex].value;
      const result: SearchResultPage = await forumApi.search(query, page, order, request);
      if (this.request !== request) { return; }
      const merged: TopicListItem[] = reset ? result.items : this.items.concat(result.items);
      const seen: Set<number> = new Set<number>();
      this.items = merged.filter((item: TopicListItem): boolean => {
        if (seen.has(item.topic.id)) { return false; } seen.add(item.topic.id); return true;
      });
      const excerpts: Map<number, string> = reset ? new Map<number, string>() : new Map<number, string>(this.excerpts);
      result.excerpts.forEach((value: string, id: number) => { excerpts.set(id, plainText(value)); });
      this.excerpts = excerpts;
      this.submittedQuery = query; this.page = page; this.hasMore = result.hasMore; this.searched = true;
    } catch (error) {
      if (this.request === request) {
        this.error = error instanceof ForumApiError ? error.message : '搜索暂时无法完成';
        this.needsVerification = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; } }
  }

  build() {
    Column({ space: 10 }) {
      Column({ space: 10 }) {
        Text('搜索').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .width('100%').padding({ top: 12 })
        Search({ value: this.query, placeholder: '搜索话题、关键词、用户名' })
          .searchButton('搜索').height(44).backgroundColor($r('app.color.surface'))
          .onChange((value: string) => { this.query = value; })
          .onSubmit(() => { void this.search(true); }).id('forum_search')
        Row() {
          Text('排序').fontSize(14).fontColor($r('app.color.text_secondary'))
          Blank()
          Select(searchOrders.map((order): SelectOption => { return { value: order.label }; }))
            .selected(this.orderIndex).value(searchOrders[this.orderIndex].label)
            .onSelect((index: number) => { this.orderIndex = index; if (this.query.trim()) { void this.search(true); } })
        }.width('100%')
      }.width('100%').padding({ top: this.topInset })
      List({ scroller: this.listScroller, space: 6 }) {
        ForEach(this.items, (item: TopicListItem) => {
          ListItem() {
            TopicRow({ item: item, excerpt: this.excerpts.get(item.topic.id) || '',
              onOpen: (id: number): void => { this.onOpenTopic(id, 1); } })
          }
        }, (item: TopicListItem): string => String(item.topic.id))
        ListItem() {
          if (this.error) {
            ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
              onRetry: (): void => { void this.search(!this.items.length); }, onVerify: this.onVerify })
          } else if (this.busy) { LoadingProgress().width(32).height(32).margin(24) }
          else if (this.searched && !this.items.length) {
            Text('没有找到相关话题，试试其他关键词。').fontColor($r('app.color.text_secondary')).padding(24)
          } else if (this.hasMore) {
            Button('更多搜索结果').width('100%').height(48).backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.accent')).onClick(() => { void this.search(false); })
          } else if (!this.searched) {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(40).fontColor([$r('app.color.text_secondary')])
              Text('每一个问题，都值得寻找答案。').fontSize(15).fontColor($r('app.color.text_secondary'))
            }.width('100%').padding({ top: 64, bottom: 24 })
          }
        }
      }.width('100%').height('100%').layoutWeight(1)
        .scrollBar(BarState.Off).contentEndOffset(92 + this.bottomInset).onWillScroll((offset: number, state: ScrollState, source: ScrollSource): ScrollResult => {
          this.onReadScroll(offset, state, source);
          return { offsetRemain: offset };
        })
    }.width('100%').height('100%').padding({ left: 14, right: 14 })
      .onDisAppear(() => { this.request?.cancel(); })
  }
}
