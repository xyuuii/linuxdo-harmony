import { common } from '@kit.AbilityKit';
import { Category, flattenCategories, TopicListItem, ForumSearchPostMatch, SearchOrder, SearchOrderOption, SearchPage as SearchResultPage, searchOrders } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { ForumAvatar, ForumErrorView, TopicRow } from '../components/ForumComponents';
import { plainText } from '../services/ForumPresentation';
import { materialFor } from '../services/MaterialPolicy';
import {
  ForumSearchCriteria, ForumSearchQuery, ForumSearchHistoryEntry, buildForumSearchQuery,
  forumSearchCriteriaSummary, forumSearchHistoryId
} from '../services/SearchPolicy';
import { ForumSearchHistoryStore } from '../services/SearchHistoryStore';
import { ForumSearchHistoryPreferences } from '../services/SearchHistoryPreferences';

@ComponentV2
export struct SearchPage {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param active: boolean = true;
  @Param topicScopeId: number = 0;
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
  @Local submittedOrderIndex: number = 0;
  @Local titleOnly: boolean = false;
  @Local categoryId: number = 0;
  @Local categoryName: string = '';
  @Local tagsText: string = '';
  @Local author: string = '';
  @Local filtersOpen: boolean = false;
  @Local draftTitleOnly: boolean = false;
  @Local draftCategoryId: number = 0;
  @Local draftCategoryName: string = '';
  @Local draftTags: string = '';
  @Local draftAuthor: string = '';
  @Local filterError: string = '';
  @Local categories: Category[] = [];
  @Local categoriesLoading: boolean = false;
  @Local categoriesError: string = '';
  @Local history: ForumSearchHistoryEntry[] = [];
  @Local historyLoading: boolean = false;
  @Local historyError: string = '';
  @Local items: TopicListItem[] = [];
  @Local postMatches: ForumSearchPostMatch[] = [];
  @Local excerpts: Map<number, string> = new Map<number, string>();
  @Local postNumbers: Map<number, number> = new Map<number, number>();
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local needsVerification: boolean = false;
  @Local hasMore: boolean = false;
  @Local page: number = 1;
  @Local searched: boolean = false;
  private request: RequestCancellation | undefined = undefined;
  private categoryRequest: RequestCancellation | undefined = undefined;
  private historyStore: ForumSearchHistoryStore | undefined = undefined;
  private historyOwnerId: number = -1;
  private historyScopeId: number = -1;
  private historyRevision: number = 0;
  private visible: boolean = false;
  private resumeSearch: boolean = false;

  @Computed
  get filterCount(): number {
    return Number(this.titleOnly) + Number(this.categoryId > 0) + Number(this.tagsText.trim().length > 0) + Number(this.author.trim().length > 0);
  }
  @Computed
  get filterSummary(): string { return forumSearchCriteriaSummary(this.criteria()); }
  @Computed
  get draftCategoryIndex(): number {
    const index: number = this.categories.findIndex((category: Category): boolean => category.id === this.draftCategoryId);
    return index < 0 ? 0 : index + 1;
  }
  @Computed
  get categoryOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部分类' }];
    return options.concat(this.categories.map((category: Category): SelectOption => {
      const parent: Category | undefined = this.categories.find((candidate: Category): boolean => candidate.id === category.parentCategoryId);
      return { value: parent === undefined ? category.name : `${parent.name} › ${category.name}` };
    }));
  }

  @Monitor('reloadSignal', 'topicScopeId')
  reload(): void {
    const ownerId: number = forumSession.user?.id ?? 0;
    this.request?.cancel(); this.request = undefined; this.categoryRequest?.cancel(); this.categoriesLoading = false;
    if (ownerId !== this.historyOwnerId || this.topicScopeId !== this.historyScopeId) {
      this.clearResults(); this.query = ''; this.submittedQuery = ''; this.orderIndex = 0;
      this.titleOnly = false; this.categoryId = 0; this.categoryName = ''; this.tagsText = ''; this.author = '';
      this.filtersOpen = false; this.categories = []; this.resumeSearch = false;
      this.history = []; this.historyOwnerId = -1; this.historyRevision++;
      if (this.topicScopeId !== this.historyScopeId) { this.historyStore = undefined; }
      void this.loadHistory();
    } else {
      const retry: boolean = this.busy;
      this.busy = false;
      if (retry && this.active && this.visible) { void this.search(true); }
    }
  }
  @Monitor('active')
  activeChanged(): void {
    if (!this.active) {
      this.resumeSearch = this.resumeSearch || this.busy; this.request?.cancel(); this.request = undefined; this.busy = false;
      this.categoryRequest?.cancel(); this.categoriesLoading = false; this.filtersOpen = false;
    } else if (this.visible) {
      void this.loadHistory();
      if (this.resumeSearch) { this.resumeSearch = false; void this.search(true); }
    }
  }
  private clearResults(): void {
    this.request?.cancel(); this.request = undefined; this.items = []; this.excerpts = new Map<number, string>();
    this.postNumbers = new Map<number, number>(); this.postMatches = []; this.hasMore = false; this.searched = false; this.busy = false;
    this.error = ''; this.needsVerification = false;
  }
  private criteria(): ForumSearchCriteria {
    return { query: this.query, titleOnly: this.titleOnly, categoryId: this.categoryId,
      categoryName: this.categoryName, tags: this.tagsText, author: this.author };
  }
  private historyEntry(): ForumSearchHistoryEntry {
    return { query: this.query.trim(), titleOnly: this.titleOnly, categoryId: this.categoryId,
      categoryName: this.categoryName, tags: this.tagsText.trim(), author: this.author.trim(), orderIndex: this.orderIndex };
  }
  private async loadHistory(): Promise<void> {
    const ownerId: number = forumSession.user?.id ?? 0;
    if (!this.visible || !this.active || (ownerId === this.historyOwnerId && this.topicScopeId === this.historyScopeId && !this.historyError)) { return; }
    const revision: number = ++this.historyRevision;
    this.historyOwnerId = ownerId; this.history = []; this.historyLoading = true; this.historyError = '';
    if (this.historyScopeId !== this.topicScopeId) { this.historyStore = undefined; }
    this.historyScopeId = this.topicScopeId;
    try {
      if (this.historyStore === undefined) {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.historyStore = new ForumSearchHistoryStore(new ForumSearchHistoryPreferences(context, this.topicScopeId));
      }
      const entries: ForumSearchHistoryEntry[] = await this.historyStore.read(ownerId);
      if (revision === this.historyRevision && ownerId === (forumSession.user?.id ?? 0)) { this.history = entries; }
    } catch {
      if (revision === this.historyRevision && ownerId === (forumSession.user?.id ?? 0)) {
        this.historyError = '最近搜索暂时无法读取，本次搜索仍可使用';
      }
    } finally { if (revision === this.historyRevision) { this.historyLoading = false; } }
  }
  private async remember(entry: ForumSearchHistoryEntry, ownerId: number): Promise<void> {
    const store: ForumSearchHistoryStore | undefined = this.historyStore;
    if (store === undefined) { return; }
    try {
      const entries: ForumSearchHistoryEntry[] = await store.remember(ownerId, entry);
      if (ownerId === (forumSession.user?.id ?? 0) && this.historyOwnerId === ownerId) { this.history = entries; this.historyError = ''; }
    } catch {
      if (ownerId === (forumSession.user?.id ?? 0)) { this.historyError = '最近搜索暂时无法保存，本次搜索仍可使用'; }
    }
  }
  private async removeHistory(entry?: ForumSearchHistoryEntry): Promise<void> {
    const ownerId: number = forumSession.user?.id ?? 0;
    const store: ForumSearchHistoryStore | undefined = this.historyStore;
    if (store === undefined || ownerId !== this.historyOwnerId) { return; }
    try {
      if (entry === undefined) {
        this.history = []; await store.clear(ownerId);
      } else {
        const id: string = forumSearchHistoryId(entry);
        this.history = this.history.filter((candidate: ForumSearchHistoryEntry): boolean => forumSearchHistoryId(candidate) !== id);
        const entries: ForumSearchHistoryEntry[] = await store.remove(ownerId, entry);
        if (ownerId === (forumSession.user?.id ?? 0)) { this.history = entries; }
      }
      if (ownerId === (forumSession.user?.id ?? 0)) { this.historyError = ''; }
    } catch {
      if (ownerId === (forumSession.user?.id ?? 0)) { this.historyError = '最近搜索暂时无法更新，请重试'; }
    }
  }
  private reuseHistory(entry: ForumSearchHistoryEntry): void {
    this.query = entry.query; this.titleOnly = entry.titleOnly; this.categoryId = entry.categoryId;
    this.categoryName = entry.categoryName; this.tagsText = entry.tags; this.author = entry.author; this.orderIndex = entry.orderIndex;
    void this.search(true);
  }

  private openFilters(): void {
    this.draftTitleOnly = this.titleOnly; this.draftCategoryId = this.categoryId; this.draftCategoryName = this.categoryName;
    this.draftTags = this.tagsText; this.draftAuthor = this.author; this.filterError = ''; this.filtersOpen = true;
    if (!this.categories.length) { void this.loadCategories(); }
  }
  private async loadCategories(): Promise<void> {
    this.categoryRequest?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    const ownerId: number = forumSession.user?.id ?? 0;
    this.categoryRequest = request; this.categoriesLoading = true; this.categoriesError = '';
    try {
      const categories: Category[] = await forumApi.fetchCategories(false, request);
      if (this.categoryRequest === request && !request.isCancelled && ownerId === (forumSession.user?.id ?? 0)) {
        this.categories = flattenCategories(categories);
      }
    } catch {
      if (this.categoryRequest === request && !request.isCancelled) { this.categoriesError = '分类暂时无法加载，点按重试'; }
    } finally { if (this.categoryRequest === request) { this.categoriesLoading = false; } }
  }
  private applyFilters(): void {
    const criteria: ForumSearchCriteria = { query: this.query, titleOnly: this.draftTitleOnly,
      categoryId: this.draftCategoryId, categoryName: this.draftCategoryName, tags: this.draftTags, author: this.draftAuthor };
    const result: ForumSearchQuery = buildForumSearchQuery(criteria, this.topicScopeId);
    if (result.error && (this.query.trim() || this.draftCategoryId > 0 || this.draftTags.trim() || this.draftAuthor.trim())) {
      this.filterError = result.error; return;
    }
    this.titleOnly = this.draftTitleOnly; this.categoryId = this.draftCategoryId; this.categoryName = this.draftCategoryName;
    this.tagsText = this.draftTags; this.author = this.draftAuthor; this.filtersOpen = false;
    if (!result.error) { void this.search(true); }
  }
  private resetFilters(): void {
    this.titleOnly = false; this.categoryId = 0; this.categoryName = ''; this.tagsText = ''; this.author = '';
    if (this.query.trim()) { void this.search(true); } else { this.clearResults(); }
  }

  private async search(reset: boolean): Promise<void> {
    if (!this.active || !this.visible || (this.busy && !reset)) { return; }
    const compiled: ForumSearchQuery = reset ? buildForumSearchQuery(this.criteria(), this.topicScopeId) : { query: this.submittedQuery, error: '' };
    if (compiled.error || !compiled.query) { this.error = compiled.error; return; }
    const entry: ForumSearchHistoryEntry = this.historyEntry();
    const ownerId: number = forumSession.user?.id ?? 0;
    const topicScopeId: number = this.topicScopeId;
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsVerification = false;
    const page: number = reset ? 1 : this.page + 1;
    const orderIndex: number = reset ? this.orderIndex : this.submittedOrderIndex;
    const order: SearchOrder = searchOrders[orderIndex].value;
    if (reset) {
      this.items = []; this.postMatches = []; this.excerpts = new Map<number, string>(); this.postNumbers = new Map<number, number>(); this.hasMore = false;
      this.searched = true; this.submittedQuery = compiled.query; this.submittedOrderIndex = orderIndex;
      this.listScroller.scrollEdge(Edge.Top);
    }
    try {
      const result: SearchResultPage = await forumApi.search(compiled.query, page, order, request);
      if (this.request !== request || request.isCancelled || !this.active || !this.visible || ownerId !== (forumSession.user?.id ?? 0) || this.topicScopeId !== topicScopeId) { return; }
      if (topicScopeId > 0) {
        const matches: ForumSearchPostMatch[] = result.postMatches ?? [];
        if (result.items.some((item: TopicListItem): boolean => item.topic.id !== topicScopeId) ||
          matches.some((match: ForumSearchPostMatch): boolean => match.topicId !== topicScopeId)) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '话题内搜索未保持指定范围，请重试');
        }
        const allMatches: ForumSearchPostMatch[] = reset ? matches : this.postMatches.concat(matches);
        const seenPosts: Set<string> = new Set<string>();
        this.postMatches = allMatches.filter((match: ForumSearchPostMatch): boolean => {
          if (seenPosts.has(match.id)) { return false; } seenPosts.add(match.id); return true;
        });
      }
      const merged: TopicListItem[] = reset ? result.items : this.items.concat(result.items);
      const seen: Set<number> = new Set<number>();
      this.items = merged.filter((item: TopicListItem): boolean => {
        if (seen.has(item.topic.id)) { return false; } seen.add(item.topic.id); return true;
      });
      const excerpts: Map<number, string> = reset ? new Map<number, string>() : new Map<number, string>(this.excerpts);
      const positions: Map<number, number> = reset ? new Map<number, number>() : new Map<number, number>(this.postNumbers);
      result.excerpts.forEach((value: string, id: number): void => { if (!excerpts.has(id)) { excerpts.set(id, plainText(value)); } });
      result.postNumbers?.forEach((postNumber: number, id: number): void => { if (!positions.has(id)) { positions.set(id, postNumber); } });
      this.excerpts = excerpts; this.postNumbers = positions;
      this.page = page; this.hasMore = result.hasMore; this.searched = true;
      if (reset) { void this.remember(entry, ownerId); }
    } catch (error) {
      if (this.request === request && !request.isCancelled && ownerId === (forumSession.user?.id ?? 0)) {
        this.error = error instanceof ForumApiError ? error.message : '搜索暂时无法完成';
        this.needsVerification = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; } }
  }

  @Builder
  filtersSheet() {
    Column({ space: 16 }) {
      Row() {
        Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.text_secondary'))
          .onClick((): void => { this.filtersOpen = false; })
        Text('搜索筛选').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .layoutWeight(1).textAlign(TextAlign.Center)
        Button('重置', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.accent'))
          .onClick((): void => { this.draftTitleOnly = false; this.draftCategoryId = 0; this.draftCategoryName = ''; this.draftTags = ''; this.draftAuthor = ''; this.filterError = ''; })
      }.width('100%').height(48)
      Scroll() {
        Column({ space: 18 }) {
          Row() {
            Text('仅搜索标题').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.draftTitleOnly }).selectedColor($r('app.color.accent'))
              .onChange((enabled: boolean): void => { this.draftTitleOnly = enabled; }).id('search_title_only')
          }.width('100%').height(44)
          Column({ space: 8 }) {
            Text('分类').fontSize(13).fontColor($r('app.color.text_secondary'))
            Select(this.categoryOptions).selected(this.draftCategoryIndex).value(this.draftCategoryName || '全部分类')
              .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.page_background')).width('100%')
              .enabled(!this.categoriesLoading).id('search_category_filter')
              .onSelect((index: number): void => {
                const category: Category | undefined = index > 0 ? this.categories[index - 1] : undefined;
                this.draftCategoryId = category?.id ?? 0; this.draftCategoryName = category?.name ?? '';
              })
            if (this.categoriesLoading) { Text('正在读取分类…').fontSize(12).fontColor($r('app.color.text_secondary')) }
            if (this.categoriesError) {
              Text(this.categoriesError).fontSize(12).fontColor($r('app.color.accent')).onClick((): void => { void this.loadCategories(); })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
          Column({ space: 8 }) {
            Text('标签').fontSize(13).fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.draftTags, placeholder: '例如：鸿蒙,人工智能' }).fontSize(15).maxLength(500)
              .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.page_background'))
              .onChange((value: string): void => { this.draftTags = value; }).id('search_tags_filter')
            Text('多个标签用逗号分隔，匹配其中任一项').fontSize(11).fontColor($r('app.color.text_secondary'))
          }.width('100%').alignItems(HorizontalAlign.Start)
          Column({ space: 8 }) {
            Text('发帖人').fontSize(13).fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.draftAuthor, placeholder: '输入用户名，可省略 @' }).fontSize(15).maxLength(61)
              .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.page_background'))
              .onChange((value: string): void => { this.draftAuthor = value; }).id('search_author_filter')
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.filterError) { Text(this.filterError).fontSize(13).fontColor($r('app.color.error')).width('100%') }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).scrollBar(BarState.Off)
      Button('应用筛选', { type: ButtonType.Capsule }).width('100%').height(48)
        .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
        .onClick((): void => { this.applyFilters(); }).id('search_apply_filters')
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 20 })
      .backgroundColor($r('app.color.surface'))
  }

  @Builder
  historyRow(entry: ForumSearchHistoryEntry) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.clock')).fontSize(18).fontColor([$r('app.color.text_secondary')]).width(24)
      Column({ space: 5 }) {
        Text(entry.query || '按筛选条件搜索').fontSize(15).fontColor($r('app.color.text_primary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (forumSearchCriteriaSummary(entry)) {
          Text(forumSearchCriteriaSummary(entry)).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding({ top: 14, bottom: 14 })
        .onClick((): void => { this.reuseHistory(entry); })
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(13).fontColor([$r('app.color.text_secondary')])
      }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText(`删除最近搜索 ${entry.query || '筛选条件'}`)
        .onClick((): void => { void this.removeHistory(entry); })
    }.width('100%').constraintSize({ minHeight: 56 })
  }

  build() {
    Column({ space: 0 }) {
      Column({ space: 12 }) {
        Text(this.topicScopeId > 0 ? '搜索本话题' : '搜索').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center).width('100%').height(48)
        Row({ space: 10 }) {
          Search({ value: this.query, placeholder: this.topicScopeId > 0 ? '在本话题中搜索帖子' : '搜索话题和帖子内容' })
            .searchButton('搜索').height(46).backgroundColor($r('app.color.page_background'))
            .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
            .textFont({ size: 16 }).borderRadius(16).layoutWeight(1)
            .onChange((value: string): void => { this.query = value; if (!value.trim()) { this.clearResults(); } })
            .onSubmit((): void => { void this.search(true); }).id('forum_search')
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(22).fontColor([this.filterCount > 0 ? $r('app.color.accent') : $r('app.color.text_primary')])
          }.width(44).height(44).backgroundColor(Color.Transparent).systemMaterial(materialFor(this.appearance))
            .accessibilityText(this.filterCount > 0 ? `搜索筛选，已选 ${this.filterCount} 项` : '搜索筛选')
            .onClick((): void => { this.openFilters(); }).id('search_filters_button')
        }.width('100%')
        Row() {
          if (this.filterCount > 0) {
            Text(this.filterSummary).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).onClick((): void => { this.openFilters(); })
            Button('重置', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(12)
              .fontColor($r('app.color.accent')).onClick((): void => { this.resetFilters(); })
          } else {
            Text('话题与帖子').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          }
          Select(searchOrders.map((order: SearchOrderOption): SelectOption => { return { value: order.label }; }))
            .selected(this.orderIndex).value(searchOrders[this.orderIndex].label)
            .font({ size: 13 }).fontColor($r('app.color.text_primary')).backgroundColor(Color.Transparent)
            .onSelect((index: number): void => {
              if (index < 0 || index >= searchOrders.length) { return; }
              this.orderIndex = index;
              if (buildForumSearchQuery(this.criteria(), this.topicScopeId).query) { void this.search(true); }
            }).id('search_order')
        }.width('100%').constraintSize({ minHeight: 40 })
      }.width('100%').padding({ top: this.topInset, left: 18, right: 18, bottom: 8 })
      Divider().color($r('app.color.divider'))
      if (this.searched || this.busy) {
        Row() {
          Text(this.busy ? '正在搜索…' : this.topicScopeId > 0 ? `已加载 ${this.postMatches.length} 个匹配帖子` : `已加载 ${this.items.length} 个相关话题`)
            .fontSize(12).fontColor($r('app.color.text_secondary'))
          Blank()
          if (this.searched) { Text(searchOrders[this.submittedOrderIndex].label).fontSize(12).fontColor($r('app.color.text_secondary')) }
        }.width('100%').padding({ left: 18, right: 18, top: 12, bottom: 8 }).id('search_result_summary')
      }
      List({ scroller: this.listScroller, space: 0 }) {
        if (!this.searched && !this.busy && this.history.length > 0) {
          ListItem() {
            Row() {
              Text('最近搜索').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Button('清空', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(12)
                .fontColor($r('app.color.text_secondary')).onClick((): void => { void this.removeHistory(); }).id('search_clear_history')
            }.width('100%').padding({ top: 10, bottom: 4 })
          }
          ForEach(this.history, (entry: ForumSearchHistoryEntry) => { ListItem() { this.historyRow(entry); } },
            (entry: ForumSearchHistoryEntry): string => forumSearchHistoryId(entry))
        }
        if (this.topicScopeId > 0) {
          ForEach(this.postMatches, (match: ForumSearchPostMatch) => {
            ListItem() {
              Row({ space: 12 }) {
                ForumAvatar({ name: match.username, url: match.avatarUrl, avatarSize: 32 })
                Column({ space: 8 }) {
                  Row() {
                    Text(match.username).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
                    Text(`#${match.postNumber}`).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }.width('100%')
                  Text(match.excerpt || '查看匹配的帖子').fontSize(14).lineHeight(21).fontColor($r('app.color.text_primary'))
                    .maxLines(5).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 16, bottom: 16 })
                .onClick((): void => { this.onOpenTopic(match.topicId, match.postNumber); }).id(`search_post_${match.id}`)
            }
          }, (match: ForumSearchPostMatch): string => match.id)
        } else {
        ForEach(this.items, (item: TopicListItem) => {
          ListItem() {
            TopicRow({ item: item, excerpt: this.excerpts.get(item.topic.id) || '',
              onOpen: (id: number): void => { this.onOpenTopic(id, this.postNumbers.get(id) ?? 1); } })
          }
        }, (item: TopicListItem): string => String(item.topic.id))
        }
        ListItem() {
          if (this.error) {
            ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
              onRetry: (): void => { void this.search(!this.items.length); }, onVerify: this.onVerify })
          } else if (this.busy || this.historyLoading && !this.searched) { LoadingProgress().width(32).height(32).margin(24) }
          else if (this.searched && (this.topicScopeId > 0 ? this.postMatches.length === 0 : this.items.length === 0)) {
            Text(this.topicScopeId > 0 ? '本话题内没有找到匹配的帖子' : '没有找到相关话题，试试其他关键词或筛选条件。')
              .fontColor($r('app.color.text_secondary')).padding(24)
          } else if (this.hasMore) {
            Button('更多搜索结果').width('100%').height(48).backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.accent')).onClick((): void => { void this.search(false); })
          } else if (!this.searched && this.history.length === 0) {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(40).fontColor([$r('app.color.text_secondary')])
              Text(this.topicScopeId > 0 ? '输入关键词，查找本话题内的帖子' : '输入关键词，查找社区话题与帖子')
                .fontSize(14).fontColor($r('app.color.text_secondary'))
            }.width('100%').padding({ top: 64, bottom: 24 })
          }
        }
        if (this.historyError) {
          ListItem() { Text(this.historyError).fontSize(12).fontColor($r('app.color.text_secondary')).padding(18) }
        }
      }.width('100%').height('100%').layoutWeight(1).padding({ left: 14, right: 14 })
        .scrollBar(BarState.Off).contentEndOffset(92 + this.bottomInset)
        .onWillScroll((offset: number, state: ScrollState, source: ScrollSource): ScrollResult => {
          this.onReadScroll(offset, state, source); return { offsetRemain: offset };
        })
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .bindSheet($$this.filtersOpen, this.filtersSheet, { height: SheetSize.LARGE, dragBar: true, showClose: false,
        backgroundColor: $r('app.color.surface'), keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
      .onAppear((): void => {
        this.visible = true;
        if (this.active) {
          void this.loadHistory();
          if (this.resumeSearch) { this.resumeSearch = false; void this.search(true); }
        }
      })
      .onDisAppear((): void => { this.visible = false; this.resumeSearch = this.resumeSearch || this.busy; this.request?.cancel(); this.request = undefined; this.busy = false; this.categoryRequest?.cancel(); })
  }
}
