import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ForumSession, forumSession } from '../models/ForumSession';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { LOCAL_DRAFT_STORE, DraftTarget, LocalDraftEntry, listLocalDrafts, removeLocalDraft } from '../services/DraftRepository';
import { materialFor } from '../services/MaterialPolicy';

@ComponentV2
export struct DraftsPage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param reloadSignal: number = 0;
  @Param session: ForumSession = forumSession;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Event onOpenDraft: (target: DraftTarget) => void = (_target: DraftTarget): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local entries: LocalDraftEntry[] = [];
  @Local busy: boolean = false;
  @Local refreshing: boolean = false;
  @Local error: string = '';
  private visible: boolean = false;
  private generation: number = 0;
  private store: preferences.Preferences | undefined = undefined;

  @Monitor('session.revision')
  accountChanged(): void {
    this.generation++; this.entries = []; this.store = undefined; this.busy = false; this.refreshing = false; this.error = '';
    if (this.visible) { void this.load(); }
  }

  @Monitor('reloadSignal')
  draftChanged(): void { if (this.visible) { void this.load(); } }

  private async load(): Promise<void> {
    const request: number = ++this.generation;
    const ownerId: number = this.session.user?.id || 0;
    const revision: number = this.session.revision;
    if (!this.visible || ownerId <= 0) { this.entries = []; this.busy = false; this.refreshing = false; return; }
    this.busy = true; this.error = '';
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store: preferences.Preferences = await preferences.getPreferences(context, { name: LOCAL_DRAFT_STORE });
      const entries: LocalDraftEntry[] = await listLocalDrafts(store, ownerId);
      if (request !== this.generation || !this.visible || this.session.user?.id !== ownerId || this.session.revision !== revision) { return; }
      this.store = store; this.entries = entries;
    } catch {
      if (request === this.generation && this.visible) { this.error = '本机草稿暂时无法读取，请重试'; }
    } finally { if (request === this.generation) { this.busy = false; this.refreshing = false; } }
  }

  private openDraft(entry: LocalDraftEntry): void {
    if (!this.busy && entry.readable && this.session.user?.id === entry.target.ownerId) { this.onOpenDraft(entry.target); }
  }

  private confirmDelete(entry: LocalDraftEntry): void {
    if (this.busy || this.session.user?.id !== entry.target.ownerId) { return; }
    const generation: number = this.generation;
    this.getUIContext().showAlertDialog({ title: '删除这份本机草稿？', message: entry.title,
      systemMaterial: materialFor(this.appearance), backgroundColor: $r('app.color.surface'),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { void this.deleteDraft(entry, generation); } } });
  }

  private async deleteDraft(entry: LocalDraftEntry, generation: number): Promise<void> {
    const ownerId: number = this.session.user?.id || 0;
    const store: preferences.Preferences | undefined = this.store;
    if (this.busy || !this.visible || generation !== this.generation || ownerId !== entry.target.ownerId || store === undefined) { return; }
    this.busy = true; this.error = '';
    try {
      await removeLocalDraft(store, entry.target, ownerId);
      if (generation === this.generation && this.session.user?.id === ownerId && this.visible) {
        this.entries = this.entries.filter((draft: LocalDraftEntry): boolean => draft.target.key !== entry.target.key);
      }
    } catch {
      if (generation === this.generation && this.visible) { this.error = '草稿暂时无法删除，请重试'; }
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  private updatedLabel(entry: LocalDraftEntry): string {
    return entry.updatedAt > 0 ? new Date(entry.updatedAt).toLocaleString() : '旧版草稿 · 更新时间未知';
  }

  build() {
    NavDestination() {
      Column({ space: 0 }) {
        Text('草稿仅保存在本机').fontSize(12).fontColor($r('app.color.text_secondary'))
          .width('100%').textAlign(TextAlign.Start).padding({ left: 20, right: 20, top: 8, bottom: 12 })
        Refresh({ refreshing: this.refreshing }) {
          List({ space: 12 }) {
            ForEach(this.entries, (entry: LocalDraftEntry) => {
              ListItem() {
                Row({ space: 8 }) {
                  Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                    Column({ space: 7 }) {
                      Text(entry.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(entry.context).fontSize(12).fontColor($r('app.color.accent')).maxLines(1)
                      if (entry.excerpt) {
                        Text(entry.excerpt).fontSize(14).fontColor($r('app.color.text_secondary')).maxLines(3).lineHeight(21)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      Text(this.updatedLabel(entry)).fontSize(11).fontColor($r('app.color.text_secondary'))
                    }.width('100%').alignItems(HorizontalAlign.Start)
                  }.layoutWeight(1).padding(16).backgroundColor(Color.Transparent).enabled(!this.busy && entry.readable)
                    .id(`local_${entry.target.key}`).onClick((): void => { this.openDraft(entry); })
                  Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                    SymbolGlyph($r('sys.symbol.trash')).fontSize(20).fontColor([$r('app.color.text_secondary')])
                  }.width(44).height(44).margin({ right: 8 }).backgroundColor(Color.Transparent).enabled(!this.busy)
                    .accessibilityText(`删除草稿：${entry.title}`).onClick((): void => { this.confirmDelete(entry); })
                }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
              }
            }, (entry: LocalDraftEntry): string => `${entry.target.key}:${entry.updatedAt}:${entry.excerpt}`)
            ListItem() {
              if (this.session.user === undefined) {
                Button('登录后查看本机草稿').height(48).onClick(this.onLogin)
              } else if (this.error) {
                Column({ space: 8 }) {
                  Text(this.error).fontSize(14).fontColor($r('app.color.text_secondary'))
                  Button('重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).enabled(!this.busy)
                    .onClick((): void => { void this.load(); })
                }.width('100%').padding(20)
              } else if (this.busy) {
                LoadingProgress().width(32).height(32).margin(24)
              } else if (this.entries.length === 0) {
                Text('还没有本机草稿').fontSize(15).fontColor($r('app.color.text_secondary')).padding(32)
              }
            }
          }.width('100%').height('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Off).contentEndOffset(24)
        }.width('100%').layoutWeight(1).onRefreshing((): void => { this.refreshing = true; void this.load(); })
      }.width('100%').height('100%')
    }.title('草稿').padding({ top: this.topInset, bottom: this.bottomInset }).backgroundColor($r('app.color.page_background'))
      .onShown((): void => { this.visible = true; void this.load(); })
      .onHidden((): void => { this.visible = false; this.generation++; this.busy = false; this.refreshing = false; })
  }
}
