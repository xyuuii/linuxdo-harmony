import { Category, flattenCategories } from '../models/ForumModels';
import { DirectoryTag, DirectoryTagPage } from '../models/DirectoryModels';
import { forumApi, ForumApiError, RequestCancellation } from '../services/ForumApi';
import { ForumErrorView } from './ForumComponents';

/** One searchable picker shared by home category and tag filters. */
@ComponentV2
export struct TopicTaxonomySheet {
  @Param tagMode: boolean = false;
  @Param selectedCategoryId: number = 0;
  @Param selectedTag: string = '';
  @Event onCategory: (category: Category | undefined) => void = (): void => {};
  @Event onTag: (name: string) => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  @Local query: string = '';
  @Local categories: Category[] = [];
  @Local tags: DirectoryTag[] = [];
  @Local tagPage: number = 0;
  @Local hasMore: boolean = false;
  @Local busy: boolean = false;
  @Local error: string = '';
  private generation: number = 0;
  private request: RequestCancellation | undefined = undefined;
  private visible: boolean = false;

  @Computed
  get matchingCategories(): Category[] {
    const query: string = this.query.trim().toLowerCase();
    return this.categories.filter((category: Category): boolean => !query ||
      category.name.toLowerCase().includes(query) || category.description.toLowerCase().includes(query));
  }

  private async load(reset: boolean = true): Promise<void> {
    if (!this.visible || (!reset && (this.busy || !this.hasMore))) { return; }
    this.request?.cancel();
    const token: RequestCancellation = new RequestCancellation();
    const generation: number = ++this.generation;
    this.request = token; this.busy = true; this.error = '';
    try {
      if (this.tagMode) {
        const page: number = reset ? 0 : this.tagPage + 1;
        const result: DirectoryTagPage = await forumApi.fetchDirectoryTags(this.query, page, token);
        if (generation !== this.generation) { return; }
        this.tags = reset ? result.items : this.tags.concat(result.items);
        this.tagPage = page; this.hasMore = result.hasMore;
      } else {
        const result: Category[] = await forumApi.fetchCategories(false, token);
        if (generation !== this.generation) { return; }
        this.categories = flattenCategories(result);
      }
    } catch (error) {
      if (generation !== this.generation) { return; }
      this.error = error instanceof ForumApiError ? error.message : '筛选列表暂时无法加载';
    } finally {
      if (generation === this.generation) { this.busy = false; this.request = undefined; }
    }
  }

  @LocalBuilder
  selectionMark(selected: boolean) {
    if (selected) {
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([$r('app.color.accent')])
    }
  }

  build() {
    Column({ space: 12 }) {
      Text(this.tagMode ? '筛选标签' : '筛选分类').fontSize(22).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).width('100%').padding({ top: 16 })
      TextInput({ text: this.query, placeholder: this.tagMode ? '查找标签' : '查找分类或子分类' })
        .fontSize(16).height(44).backgroundColor($r('app.color.page_background'))
        .fontColor($r('app.color.text_primary')).id('taxonomy_search')
        .onChange((value: string): void => {
          this.query = value;
          if (this.tagMode) { this.tags = []; void this.load(); }
        })
      List({ space: 0 }) {
        ListItem() {
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Row() {
              Text(this.tagMode ? '全部标签' : '全部分类').fontSize(16).layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
              this.selectionMark(this.tagMode ? !this.selectedTag : this.selectedCategoryId === 0)
            }.width('100%').padding({ top: 16, bottom: 16 })
          }.width('100%').backgroundColor(Color.Transparent).id('taxonomy_all')
            .onClick((): void => { if (this.tagMode) { this.onTag(''); } else { this.onCategory(undefined); } })
        }
        if (this.tagMode) {
          ForEach(this.tags, (tag: DirectoryTag) => {
            ListItem() {
              Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                Row({ space: 12 }) {
                  Text('# ' + tag.name).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  Text(String(tag.topicCount)).fontSize(13).fontColor($r('app.color.text_secondary'))
                  this.selectionMark(this.selectedTag === tag.name)
                }.width('100%').padding({ top: 16, bottom: 16 })
              }.width('100%').backgroundColor(Color.Transparent).onClick((): void => { this.onTag(tag.name); })
            }
          }, (tag: DirectoryTag): string => tag.name)
        } else {
          ForEach(this.matchingCategories, (category: Category) => {
            ListItem() {
              Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                Row({ space: 12 }) {
                  Column({ space: 5 }) {
                    Text(category.name).fontSize(16).fontColor($r('app.color.text_primary'))
                    if (category.description) {
                      Text(category.description).fontSize(12).fontColor($r('app.color.text_secondary'))
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  this.selectionMark(this.selectedCategoryId === category.id)
                }.width('100%').padding({ top: 14, bottom: 14, left: category.parentCategoryId > 0 ? 16 : 0 })
              }.width('100%').backgroundColor(Color.Transparent).onClick((): void => { this.onCategory(category); })
            }
          }, (category: Category): string => category.id.toString())
        }
        ListItem() {
          if (this.error) {
            ForumErrorView({ message: this.error, onRetry: (): void => { void this.load(); }, onVerify: this.onVerify })
          } else if (this.busy) {
            LoadingProgress().width(28).height(28).margin(16)
          } else if (this.tagMode && this.hasMore) {
            Button('加载更多标签').height(44).onClick((): void => { void this.load(false); })
          } else if (this.tagMode && this.tags.length === 0 || !this.tagMode && this.matchingCategories.length === 0) {
            Text('没有匹配结果').fontSize(15).fontColor($r('app.color.text_secondary')).padding(24)
          }
        }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 24 })
      .backgroundColor($r('app.color.surface'))
      .onAppear((): void => { this.visible = true; void this.load(); })
      .onDisAppear((): void => { this.visible = false; this.generation++; this.request?.cancel(); })
  }
}
