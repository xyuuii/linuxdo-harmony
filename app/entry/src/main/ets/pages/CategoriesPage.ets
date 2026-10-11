import { Category, flattenCategories } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { ForumErrorView } from '../components/ForumComponents';
import { plainText } from '../services/ForumPresentation';

interface CategoryGroup { parent: Category; levels: Category[]; }

@ComponentV2
export struct CategoriesPage {
  @Param reloadSignal: number = 0;
  @Param listScroller: Scroller = new Scroller();
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onOpenCategory: (category: Category) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Local categories: Category[] = [];
  @Local loading: boolean = false;
  @Local error: string = '';
  @Local needsVerification: boolean = false;
  private request: RequestCancellation | undefined = undefined;

  @Computed
  get groups(): CategoryGroup[] {
    const all: Category[] = flattenCategories(this.categories);
    const byId: Map<number, Category> = new Map<number, Category>();
    all.forEach((item: Category) => { byId.set(item.id, item); });
    const suffix: RegExp = /[,，\s]+Lv\s*\d+$/i;
    const levels: Set<number> = new Set<number>();
    all.forEach((item: Category) => {
      const parent: Category | undefined = byId.get(item.parentCategoryId);
      if (parent !== undefined && suffix.test(item.name) && item.name.replace(suffix, '').trim() === parent.name.trim()) {
        levels.add(item.id);
      }
    });
    return all.filter((item: Category): boolean => !levels.has(item.id)).map((parent: Category): CategoryGroup => {
      return { parent: parent, levels: all.filter((item: Category): boolean => levels.has(item.id) && item.parentCategoryId === parent.id) };
    });
  }

  @Monitor('reloadSignal')
  reload(): void { this.request?.cancel(); this.categories = []; void this.load(true); }

  private async load(force: boolean): Promise<void> {
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request;
    this.loading = true; this.error = '';
    try {
      const result: Category[] = await forumApi.fetchCategories(force, request);
      if (this.request === request) { this.categories = result; }
    } catch (error) {
      if (this.request === request) {
        this.error = error instanceof ForumApiError ? error.message : '分类暂时无法加载';
        this.needsVerification = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.loading = false; } }
  }

  @Builder
  categoryCard(group: CategoryGroup) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(group.parent.name).fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }.width('100%')
          Text(`${group.parent.topicCount} 话题`).fontSize(11).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center).layoutWeight(1).height(44)
          .id(`category_parent_${group.parent.id}`).onClick(() => { this.onOpenCategory(group.parent); })
        if (group.levels.length <= 3) {
          ForEach(group.levels, (level: Category) => {
            Button(level.name.match(/Lv\s*\d+$/i)?.[0] || level.name, { type: ButtonType.Capsule })
              .width(48).height(44).fontSize(12).padding({ left: 0, right: 0 })
              .backgroundColor($r('app.color.selected_background')).fontColor($r('app.color.accent'))
              .id(`category_${level.id}`).onClick(() => { this.onOpenCategory(level); })
          }, (level: Category): string => String(level.id))
        }
      }.width('100%')
      if (group.parent.description.length > 0) {
        Text(plainText(group.parent.description)).fontSize(13).lineHeight(18)
          .fontColor($r('app.color.text_secondary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .onClick(() => { this.onOpenCategory(group.parent); })
      }
      if (group.levels.length > 3) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(group.levels, (level: Category) => {
            Button(level.name.match(/Lv\s*\d+$/i)?.[0] || level.name, { type: ButtonType.Capsule })
              .height(40).fontSize(13).padding({ left: 12, right: 12 })
              .backgroundColor($r('app.color.selected_background'))
              .fontColor($r('app.color.accent')).margin({ right: 6, bottom: 4 }).id(`category_${level.id}`)
              .onClick(() => { this.onOpenCategory(level); })
          }, (level: Category): string => String(level.id))
        }.width('100%')
      }
    }.padding(12).width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface')).borderRadius(18)
  }

  build() {
    List({ scroller: this.listScroller, space: 8 }) {
      ListItem() {
        Text('分类').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .width('100%').padding({ top: 12, bottom: 4 })
      }
      ForEach(this.groups, (group: CategoryGroup) => { ListItem() { this.categoryCard(group); } },
        (group: CategoryGroup): string => String(group.parent.id))
      ListItem() {
        if (this.error) {
          ForumErrorView({ message: this.error, needsVerification: this.needsVerification,
            onRetry: (): void => { void this.load(true); }, onVerify: this.onVerify })
        } else if (this.loading) { LoadingProgress().width(32).height(32).margin(24) }
        else if (this.categories.length === 0) {
          Text('暂时没有可浏览的分类').fontColor($r('app.color.text_secondary')).padding(24)
        }
      }
    }.width('100%').height('100%').padding({ left: 14, right: 14 }).contentEndOffset(92)
      .scrollBar(BarState.Off).onWillScroll(this.onReadScroll)
      .onAppear(() => { if (!this.categories.length) { void this.load(false); } })
      .onDisAppear(() => { this.request?.cancel(); })
  }
}
