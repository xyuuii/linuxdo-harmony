import { Category } from '../models/ForumModels';
import {
  DirectorySection, DirectorySectionOption, directorySections, DirectoryCategoryRow, directoryCategoryRows,
  DirectoryTag, DirectoryTagPage, DirectoryBadge, DirectoryGroup, DirectoryGroupPage
} from '../models/DirectoryModels';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { ForumErrorView } from '../components/ForumComponents';
import { plainText } from '../services/ForumPresentation';
import { materialFor } from '../services/MaterialPolicy';

@ComponentV2
export struct CategoriesPage {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param active: boolean = true;
  @Param reloadSignal: number = 0;
  @Param listScroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onOpenCategory: (category: Category) => void = (): void => {};
  @Event onOpenTag: (tagName: string) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Local section: DirectorySection = DirectorySection.Categories;
  @Local categories: Category[] = [];
  @Local tags: DirectoryTag[] = [];
  @Local badges: DirectoryBadge[] = [];
  @Local groups: DirectoryGroup[] = [];
  @Local query: string = '';
  @Local searchVisible: boolean = false;
  @Local alphabetical: boolean = false;
  @Local expandedIds: number[] = [];
  @Local expandedBadgeIds: number[] = [];
  @Local expandedGroupIds: number[] = [];
  @Local pageIndex: number = 0;
  @Local hasMore: boolean = false;
  @Local total: number = 0;
  @Local loading: boolean = false;
  @Local refreshing: boolean = false;
  @Local error: string = '';
  @Local needsVerification: boolean = false;
  private request: RequestCancellation | undefined = undefined;
  private searchTimer: number = -1;
  private visible: boolean = false;
  private reloadOnShow: boolean = true;

  @Computed
  get categoryRows(): DirectoryCategoryRow[] { return directoryCategoryRows(this.categories, this.query, this.expandedIds); }
  @Computed
  get visibleBadges(): DirectoryBadge[] {
    const term: string = this.query.trim().toLocaleLowerCase();
    return this.badges.filter((badge: DirectoryBadge): boolean => {
      return !term || `${badge.name} ${badge.description} ${badge.groupName}`.toLocaleLowerCase().indexOf(term) >= 0;
    });
  }
  @Computed
  get empty(): boolean {
    if (this.section === DirectorySection.Categories) { return this.categoryRows.length === 0; }
    if (this.section === DirectorySection.Tags) { return this.tags.length === 0; }
    if (this.section === DirectorySection.Badges) { return this.visibleBadges.length === 0; }
    return this.groups.length === 0;
  }
  @Computed
  get searchPlaceholder(): string {
    if (this.section === DirectorySection.Categories) { return '查找分类或子分类'; }
    if (this.section === DirectorySection.Tags) { return '查找标签'; }
    if (this.section === DirectorySection.Badges) { return '查找徽章'; }
    return '查找群组';
  }

  @Monitor('reloadSignal')
  reload(): void {
    this.stopRequests(); this.categories = []; this.tags = []; this.badges = []; this.groups = [];
    this.expandedIds = []; this.expandedBadgeIds = []; this.expandedGroupIds = [];
    this.hasMore = false; this.pageIndex = 0; this.reloadOnShow = true;
    if (this.visible && this.active) { void this.load(true); }
  }
  @Monitor('active')
  activeChanged(): void {
    if (!this.active) { this.stopRequests(); }
    else if (this.visible && this.reloadOnShow) { void this.load(true); }
  }

  private stopRequests(): void {
    this.request?.cancel(); this.request = undefined; this.loading = false; this.refreshing = false;
    if (this.searchTimer >= 0) { clearTimeout(this.searchTimer); this.searchTimer = -1; }
  }
  private chooseSection(next: DirectorySection): void {
    if (this.section === next) { return; }
    this.stopRequests(); this.section = next; this.query = ''; this.pageIndex = 0;
    this.hasMore = false; this.error = ''; this.reloadOnShow = true;
    this.listScroller.scrollEdge(Edge.Top);
    void this.load(true);
  }
  private searchChanged(value: string): void {
    this.query = value;
    if (this.searchTimer >= 0) { clearTimeout(this.searchTimer); this.searchTimer = -1; }
    if (this.section === DirectorySection.Tags || this.section === DirectorySection.Groups) {
      this.request?.cancel(); this.loading = false; this.hasMore = false; this.pageIndex = 0; this.reloadOnShow = true;
      if (this.section === DirectorySection.Tags) { this.tags = []; } else { this.groups = []; }
      this.searchTimer = setTimeout((): void => { this.searchTimer = -1; void this.load(true); }, 250);
    }
  }
  private submitSearch(): void {
    if (this.searchTimer >= 0) { clearTimeout(this.searchTimer); this.searchTimer = -1; }
    if (this.section === DirectorySection.Tags || this.section === DirectorySection.Groups) { void this.load(true); }
  }
  private toggleCategory(id: number): void {
    this.expandedIds = this.expandedIds.indexOf(id) >= 0 ? this.expandedIds.filter((entry: number): boolean => entry !== id) : this.expandedIds.concat([id]);
  }
  private toggleBadge(id: number): void {
    this.expandedBadgeIds = this.expandedBadgeIds.indexOf(id) >= 0 ? this.expandedBadgeIds.filter((entry: number): boolean => entry !== id) : this.expandedBadgeIds.concat([id]);
  }
  private toggleGroup(id: number): void {
    this.expandedGroupIds = this.expandedGroupIds.indexOf(id) >= 0 ? this.expandedGroupIds.filter((entry: number): boolean => entry !== id) : this.expandedGroupIds.concat([id]);
  }

  private async load(reset: boolean): Promise<void> {
    if (!this.active || !this.visible || (!reset && (this.loading || !this.hasMore))) { return; }
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    const section: DirectorySection = this.section;
    const term: string = this.query;
    const page: number = reset ? 0 : this.pageIndex + 1;
    this.request = request; this.loading = true; this.error = ''; this.needsVerification = false;
    this.reloadOnShow = true;
    try {
      if (section === DirectorySection.Categories) {
        const result: Category[] = await forumApi.fetchCategories(reset, request);
        if (this.isCurrent(request, section, term)) { this.categories = result; this.hasMore = false; }
      } else if (section === DirectorySection.Tags) {
        const result: DirectoryTagPage = await forumApi.fetchDirectoryTags(term, page, request, this.alphabetical, reset && this.refreshing);
        if (this.isCurrent(request, section, term)) {
          this.tags = reset ? result.items : this.tags.concat(result.items); this.hasMore = result.hasMore; this.total = result.total;
        }
      } else if (section === DirectorySection.Badges) {
        const result: DirectoryBadge[] = await forumApi.fetchDirectoryBadges(request);
        if (this.isCurrent(request, section, term)) { this.badges = result; this.hasMore = false; }
      } else {
        const result: DirectoryGroupPage = await forumApi.fetchDirectoryGroups(term, page, request);
        if (this.isCurrent(request, section, term)) {
          const combined: DirectoryGroup[] = reset ? result.items : this.groups.concat(result.items);
          const seen: Set<number> = new Set<number>();
          this.groups = combined.filter((group: DirectoryGroup): boolean => {
            if (seen.has(group.id)) { return false; } seen.add(group.id); return true;
          });
          this.total = result.total; this.hasMore = result.hasMore && (result.total < 0 || this.groups.length < result.total);
        }
      }
      if (this.isCurrent(request, section, term)) { this.pageIndex = page; this.reloadOnShow = false; }
    } catch (error) {
      if (this.isCurrent(request, section, term)) {
        this.error = error instanceof ForumApiError ? error.message : '目录暂时无法加载，请重试';
        this.needsVerification = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.loading = false; this.refreshing = false; } }
  }
  private isCurrent(request: RequestCancellation, section: DirectorySection, term: string): boolean {
    return this.visible && this.active && this.request === request && !request.isCancelled && this.section === section &&
      (section === DirectorySection.Categories || section === DirectorySection.Badges || this.query === term);
  }

  @Builder
  categoryRow(row: DirectoryCategoryRow) {
    Row({ space: 10 }) {
      Column().width(4).height(38).backgroundColor(`#${/^[0-9A-Fa-f]{6}$/.test(row.category.color) ? row.category.color : '758293'}`).borderRadius(2)
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(row.category.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(`${row.totalTopicCount} 话题`).fontSize(11).fontColor($r('app.color.text_secondary'))
        }.width('100%')
        if (row.category.description) {
          Text(plainText(row.category.description)).fontSize(12).lineHeight(17).fontColor($r('app.color.text_secondary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding({ top: 15, bottom: 15 })
        .id(`category_parent_${row.category.id}`).onClick((): void => { this.onOpenCategory(row.category); })
      if (row.childCount > 0 && !this.query.trim()) {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Column({ space: 3 }) {
            SymbolGlyph(this.expandedIds.indexOf(row.category.id) >= 0 ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(12).fontColor([$r('app.color.text_secondary')])
            Text(String(row.childCount)).fontSize(10).fontColor($r('app.color.text_secondary'))
          }
        }.width(44).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(`${this.expandedIds.indexOf(row.category.id) >= 0 ? '收起' : '展开'} ${row.category.name} 的 ${row.childCount} 个子分类`)
          .id(`directory_expand_${row.category.id}`).onClick((): void => { this.toggleCategory(row.category.id); })
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          .width(24).height(44).onClick((): void => { this.onOpenCategory(row.category); })
      }
    }.width('100%').padding({ left: 18 + Math.min(row.depth, 4) * 18, right: 12 })
  }

  @Builder
  tagRow(tag: DirectoryTag) {
    Row({ space: 12 }) {
      Text('#').fontSize(23).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent')).width(28)
      Column({ space: 5 }) {
        Text(tag.name).fontSize(16).fontColor($r('app.color.text_primary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (tag.description) {
          Text(tag.description).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(`${tag.topicCount} 话题`).fontSize(12).fontColor($r('app.color.text_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
    }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 18, right: 18, top: 12, bottom: 12 })
      .id(`directory_tag_${tag.id || tag.name}`).onClick((): void => { this.onOpenTag(tag.name); })
  }

  @Builder
  badgeRow(badge: DirectoryBadge) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.medal')).fontSize(27)
          .fontColor([badge.badgeType === 1 ? '#B38318' : badge.badgeType === 2 ? '#7F8998' : '#A5734E']).width(32)
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            Text(badge.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (badge.hasBadge) { Text('已获得').fontSize(11).fontColor($r('app.color.accent')) }
          }.width('100%')
          Text(badge.description || badge.groupName).fontSize(12).lineHeight(17).fontColor($r('app.color.text_secondary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(String(badge.grantCount)).fontSize(12).fontColor($r('app.color.text_secondary'))
        SymbolGlyph(this.expandedBadgeIds.indexOf(badge.id) >= 0 ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(11).fontColor([$r('app.color.text_secondary')])
      }.width('100%').onClick((): void => { this.toggleBadge(badge.id); }).id(`directory_badge_${badge.id}`)
      if (this.expandedBadgeIds.indexOf(badge.id) >= 0) {
        Text(badge.longDescription || badge.description).fontSize(14).lineHeight(21)
          .fontColor($r('app.color.text_primary')).width('100%').padding({ left: 44, right: 8, top: 6, bottom: 5 })
        Text(`${badge.grantCount} 次授予${badge.groupName ? ' · ' + badge.groupName : ''}`).fontSize(11)
          .fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 44 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 15, bottom: 15 })
  }

  @Builder
  groupRow(group: DirectoryGroup) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.person_2')).fontSize(25).fontColor([$r('app.color.accent')]).width(32)
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            Text(group.displayName).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (group.joined) { Text('已加入').fontSize(11).fontColor($r('app.color.accent')) }
          }.width('100%')
          Text(group.description || `@${group.name}`).fontSize(12).lineHeight(17).fontColor($r('app.color.text_secondary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(group.userCount >= 0 ? `${group.userCount} 人` : '成员未公开').fontSize(11).fontColor($r('app.color.text_secondary'))
        SymbolGlyph(this.expandedGroupIds.indexOf(group.id) >= 0 ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(11).fontColor([$r('app.color.text_secondary')])
      }.width('100%').onClick((): void => { this.toggleGroup(group.id); }).id(`directory_group_${group.id}`)
      if (this.expandedGroupIds.indexOf(group.id) >= 0) {
        Text(group.description || '此群组未提供简介').fontSize(14).lineHeight(21)
          .fontColor($r('app.color.text_primary')).width('100%').padding({ left: 44, right: 8, top: 6, bottom: 5 })
        Text(`@${group.name} · ${group.automatic ? '系统群组' : group.publicAdmission ? '公开群组' : '群组'}`)
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 44 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 15, bottom: 15 })
  }

  build() {
    Column() {
      Row() {
        Blank().width(44)
        Text('目录').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center).layoutWeight(1)
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(21).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).backgroundColor(Color.Transparent).systemMaterial(materialFor(this.appearance))
          .accessibilityText(this.searchVisible ? '关闭目录搜索' : this.searchPlaceholder).id('directory_search_button')
          .onClick((): void => { this.searchVisible = !this.searchVisible; if (!this.searchVisible) { this.searchChanged(''); } })
      }.width('100%').height(52).padding({ left: 14, right: 14 })
      Row({ space: 4 }) {
        ForEach(directorySections, (option: DirectorySectionOption) => {
          Button(option.label, { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
            .layoutWeight(1).height(36).fontSize(14)
            .fontWeight(this.section === option.value ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.section === option.value ? $r('app.color.accent') : $r('app.color.text_secondary'))
            .backgroundColor(this.section === option.value ? $r('app.color.selected_background') : Color.Transparent)
            .accessibilitySelected(this.section === option.value).id(`directory_section_${option.value}`)
            .onClick((): void => { this.chooseSection(option.value); })
        }, (option: DirectorySectionOption): string => option.value)
      }.width('100%').padding(4).borderRadius(23).backgroundColor($r('app.color.page_background'))
        .margin({ left: 18, right: 18, top: 4, bottom: 12 }).constraintSize({ maxWidth: 520 })
      if (this.searchVisible) {
        Search({ value: this.query, placeholder: this.searchPlaceholder }).height(42).fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.page_background')).margin({ left: 18, right: 18, bottom: 10 })
          .onChange((value: string): void => { this.searchChanged(value); }).onSubmit((): void => { this.submitSearch(); })
          .id('directory_search_input')
      }
      if (this.section === DirectorySection.Tags) {
        Row() {
          Text(`${this.total} 个标签`).fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.alphabetical ? '按名称排序' : '按话题数排序', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(12).height(36).padding({ left: 12, right: 4 }).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
            .id('directory_tag_sort').onClick((): void => { this.alphabetical = !this.alphabetical; void this.load(true); })
        }.width('100%').padding({ left: 18, right: 18 })
      }
      Divider().color($r('app.color.divider'))
      Refresh({ refreshing: this.refreshing }) {
        List({ scroller: this.listScroller }) {
          if (this.section === DirectorySection.Categories) {
            ForEach(this.categoryRows, (row: DirectoryCategoryRow) => {
              ListItem() { this.categoryRow(row); }
            }, (row: DirectoryCategoryRow): string => `category:${row.category.id}`)
          } else if (this.section === DirectorySection.Tags) {
            ForEach(this.tags, (tag: DirectoryTag) => { ListItem() { this.tagRow(tag); } }, (tag: DirectoryTag): string => `tag:${tag.name}`)
          } else if (this.section === DirectorySection.Badges) {
            ForEach(this.visibleBadges, (badge: DirectoryBadge) => { ListItem() { this.badgeRow(badge); } }, (badge: DirectoryBadge): string => `badge:${badge.id}`)
          } else {
            ForEach(this.groups, (group: DirectoryGroup) => { ListItem() { this.groupRow(group); } }, (group: DirectoryGroup): string => `group:${group.id}`)
          }
          ListItem() {
            Column() {
              if (this.error) {
                ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
                  onRetry: (): void => { void this.load(true); }, onVerify: this.onVerify })
              } else if (this.loading) { LoadingProgress().width(30).height(30).margin(20) }
              else if (this.empty) {
                Text(this.query.trim() ? '没有匹配的内容，试试其他关键词' : '当前没有可浏览的内容')
                  .fontSize(14).fontColor($r('app.color.text_secondary')).padding(24)
              } else if (this.hasMore) {
                Button('加载更多', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
                  .fontColor($r('app.color.accent')).margin(12).onClick((): void => { void this.load(false); })
              }
            }.width('100%')
          }
        }.width('100%').height('100%').contentEndOffset(92 + this.bottomInset)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 18, endMargin: 18 })
          .scrollBar(BarState.Off).onWillScroll((offset: number, state: ScrollState, source: ScrollSource): ScrollResult => {
            this.onReadScroll(offset, state, source); return { offsetRemain: offset };
          }).onReachEnd((): void => { void this.load(false); })
      }.layoutWeight(1).onRefreshing((): void => { this.refreshing = true; void this.load(true); })
    }.width('100%').height('100%').backgroundColor($r('app.color.surface')).padding({ top: this.topInset })
      .onAppear((): void => { this.visible = true; if (this.active && this.reloadOnShow) { void this.load(true); } })
      .onDisAppear((): void => { this.visible = false; this.stopRequests(); })
  }
}
