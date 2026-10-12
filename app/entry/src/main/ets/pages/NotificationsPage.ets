import { uiMaterial } from '@kit.ArkUI';
import { ForumNotification, NotificationFilter, NotificationPage, notificationFilters, NotificationFilterOption } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';
import { ForumSession } from '../models/ForumSession';
import { ForumAvatar, ForumErrorView } from '../components/ForumComponents';
import { relativeTime } from '../services/ForumPresentation';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { ReaderGlassSurface } from '../components/ReaderGlassSurface';

@ComponentV2
export struct NotificationsPage {
  @Param embedded: boolean = false;
  @Param active: boolean = true;
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param listScroller: Scroller = new Scroller();
  @Param session: ForumSession = forumSession;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Local items: ForumNotification[] = [];
  @Local filterIndex: number = 0;
  @Local notificationOffset: number = 0;
  @Local hasMore: boolean = false;
  @Local busy: boolean = false;
  @Local refreshing: boolean = false;
  @Local error: string = '';
  @Local needsLogin: boolean = false;
  private request: RequestCancellation | undefined = undefined;
  private mounted: boolean = false;
  private visible: boolean = false;
  private reloadOnShow: boolean = true;
  private lastLoadReset: boolean = true;

  private cancelLoad(): void {
    this.request?.cancel(); this.request = undefined;
    this.busy = false; this.refreshing = false;
  }

  private shown(): void {
    if (!this.active || (this.embedded && !this.mounted)) { return; }
    this.visible = true;
    if (this.reloadOnShow && !this.busy) { void this.load(true); }
  }

  private hidden(): void {
    this.reloadOnShow = this.reloadOnShow || this.busy || this.needsLogin;
    this.visible = false;
    this.cancelLoad();
  }

  private embeddedAppeared(): void {
    this.mounted = true;
    if (this.active) { this.shown(); }
  }

  private embeddedDisappeared(): void {
    this.mounted = false;
    this.hidden();
  }

  @Monitor('active')
  activeChanged(): void {
    if (!this.embedded || !this.mounted) { return; }
    if (this.active) { this.shown(); } else { this.hidden(); }
  }

  @Monitor('session.revision')
  accountChanged(): void {
    this.cancelLoad();
    this.items = []; this.notificationOffset = 0; this.hasMore = false;
    this.error = ''; this.needsLogin = this.session.user === undefined;
    this.reloadOnShow = true;
    if (this.visible && this.active) { void this.load(true); }
  }

  private selectFilter(index: number): void {
    if (index === this.filterIndex || index < 0 || index >= notificationFilters.length) { return; }
    this.cancelLoad();
    this.filterIndex = index;
    // Never show the preceding category under the newly selected tab, even on failure.
    this.items = []; this.notificationOffset = 0; this.hasMore = false;
    this.listScroller.scrollEdge(Edge.Top);
    void this.load(true);
  }

  private async load(reset: boolean): Promise<void> {
    // A kept-alive main tab may receive refresh/account callbacks while covered.
    if (!this.visible || !this.active) { this.reloadOnShow = true; this.cancelLoad(); return; }
    if (this.session.user === undefined) {
      this.cancelLoad(); this.items = []; this.notificationOffset = 0; this.hasMore = false;
      this.error = '登录后查看回复、提及和私信。'; this.needsLogin = true;
      this.reloadOnShow = true; return;
    }
    if (this.busy && !reset) { return; }
    this.lastLoadReset = reset;
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsLogin = false;
    const userId: number = this.session.user.id;
    const revision: number = this.session.revision;
    const filter: NotificationFilter = notificationFilters[this.filterIndex].value;
    this.reloadOnShow = true;
    try {
      const result: NotificationPage = await forumApi.fetchNotifications(reset ? 0 : this.notificationOffset, filter, request);
      if (!this.visible || !this.active || this.request !== request || request.isCancelled || this.session.user?.id !== userId ||
        this.session.revision !== revision || notificationFilters[this.filterIndex].value !== filter) { return; }
      const merged: ForumNotification[] = reset ? result.notifications : this.items.concat(result.notifications);
      const seen: Set<number> = new Set<number>();
      this.items = merged.filter((item: ForumNotification): boolean => {
        if (seen.has(item.id)) { return false; } seen.add(item.id); return true;
      });
      this.notificationOffset = result.nextOffset; this.hasMore = result.hasMore;
      this.reloadOnShow = false;
    } catch (error) {
      if (this.visible && this.active && this.request === request && !request.isCancelled && this.session.user?.id === userId &&
        this.session.revision === revision) {
        this.error = error instanceof ForumApiError ? error.message : '通知暂时无法加载';
        this.needsLogin = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; this.refreshing = false; } }
  }

  private open(item: ForumNotification): void {
    const userId: number | undefined = this.session.user?.id;
    const revision: number = this.session.revision;
    if (!item.read) {
      void forumApi.markNotificationRead(item.id).then(() => {
        if (this.session.user?.id !== userId || this.session.revision !== revision) { return; }
        this.items = this.items.map((value: ForumNotification): ForumNotification => {
          return value.id === item.id ? { id: value.id, type: value.type, read: true, title: value.title, label: value.label,
            actor: value.actor, avatarUrl: value.avatarUrl, createdAt: value.createdAt, topicId: value.topicId,
            postNumber: value.postNumber } : value;
        });
        void this.session.refreshUnread();
      }).catch(() => {
        if (this.visible && this.session.user?.id === userId && this.session.revision === revision) {
          this.getUIContext().getPromptAction().showToast({ message: '已读状态暂时未同步' });
        }
      });
    }
    if (item.topicId > 0) { this.onOpenTopic(item.topicId, Math.max(1, item.postNumber)); }
  }

  private emptyMessage(): string {
    if (this.filterIndex === 1) { return '还没有回复或提及'; }
    if (this.filterIndex === 2) { return '还没有收到赞或表情回应'; }
    if (this.filterIndex === 3) { return '还没有私信通知'; }
    return '暂时没有通知';
  }

  @LocalBuilder
  filterButtons() {
    Row({ space: 2 }) {
      ForEach(notificationFilters, (filter: NotificationFilterOption, index: number) => {
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Text(filter.label).fontSize(13).maxLines(1)
            .fontWeight(this.filterIndex === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.filterIndex === index ? $r('app.color.accent') : $r('app.color.text_secondary'))
        }.height(44).layoutWeight(1).padding({ left: 4, right: 4 })
          .backgroundColor(this.filterIndex === index ?
            (this.appearance.effectLevel > 0 && !this.appearance.highContrast ?
              $r('app.color.reading_glass_selection') : $r('app.color.selected_background')) : Color.Transparent)
          .systemMaterial(uiMaterial.Material.empty).stateEffect(false)
          .accessibilitySelected(this.filterIndex === index).accessibilityText(filter.label)
          .id(`notification_filter_${filter.value}`).onClick(() => { this.selectFilter(index); })
      }, (filter: NotificationFilterOption): string => filter.value)
    }.width('100%').height(52).padding(4)
  }

  @LocalBuilder
  notificationContent() {
    Column({ space: 0 }) {
      if (this.embedded) {
        Text('消息').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .width('100%').height(44).textAlign(TextAlign.Center).id('messages_title')
      }
      ReaderGlassSurface({ appearance: this.appearance, content: this.filterButtons,
        radiusVp: 26, lightId: 'notification_filter_touch_light' })
        .width('100%').height(52).margin({ top: 8, bottom: 12 }).id('notification_filter_surface')
      Row() {
        Text(notificationFilters[this.filterIndex].label).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary')).id('notification_current_filter')
        Blank()
        Text(this.busy ? '正在加载…' : '按时间排序').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.width('100%').padding({ left: 8, right: 8, top: 2, bottom: 10 })
      Refresh({ refreshing: this.refreshing }) {
        List({ space: 0, scroller: this.listScroller }) {
          ForEach(this.items, (item: ForumNotification) => {
            ListItem() {
              Row({ space: 10 }) {
                ForumAvatar({ name: item.actor, url: item.avatarUrl, avatarSize: 36 })
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(item.actor || '社区通知').fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontWeight(item.read ? FontWeight.Normal : FontWeight.Medium)
                      .fontColor($r('app.color.text_primary')).layoutWeight(1)
                    Text(relativeTime(item.createdAt)).fontSize(11).fontColor($r('app.color.text_secondary'))
                    if (!item.read) { Circle().width(6).height(6).fill($r('app.color.accent')) }
                  }.width('100%')
                  Text(item.title || item.label).fontSize(15).fontWeight(item.read ? FontWeight.Normal : FontWeight.Medium)
                    .fontColor($r('app.color.text_primary')).lineHeight(21).maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  Text(item.label).fontSize(11).fontColor($r('app.color.accent'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').padding({ left: 12, right: 12, top: 13, bottom: 13 })
                .backgroundColor($r('app.color.surface')).alignItems(VerticalAlign.Top)
                .onClick(() => { this.open(item); }).id(`notification_${item.id}`)
                .accessibilityText(`${item.read ? '已读' : '未读'}，${item.actor}，${item.label}，${item.title}`)
            }
          // Plain wire objects are replaced on refresh; include their snapshot so
          // ForEach cannot retain a stale row or its old topic/post click target.
          }, (item: ForumNotification): string => JSON.stringify(item))
          ListItem() {
            if (this.error) {
              ForumErrorView({ message: this.error, needsVerification: this.needsLogin,
                onRetry: (): void => { void this.load(this.lastLoadReset); }, onVerify: this.onLogin })
            } else if (this.busy) {
              Column({ space: 10 }) {
                LoadingProgress().width(30).height(30)
                Text(`正在查找${notificationFilters[this.filterIndex].label}…`).fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }.width('100%').padding(28).id('notification_loading')
            }
            else if (this.hasMore) {
              Column({ space: 10 }) {
                if (!this.items.length) {
                  Text('最近的通知中没有此类消息，可继续查找更早的记录。')
                    .fontSize(13).lineHeight(20).textAlign(TextAlign.Center).fontColor($r('app.color.text_secondary'))
                }
                Button(this.items.length ? '更早的通知' : '继续查找').height(44).fontColor($r('app.color.accent'))
                  .backgroundColor($r('app.color.surface')).onClick(() => { void this.load(false); })
                  .id('notification_load_more')
              }.width('100%').padding(20)
            } else if (!this.items.length) {
              Column({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.bell')).fontSize(32).fontColor([$r('app.color.text_secondary')])
                Text(this.emptyMessage()).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                Text('新的消息会显示在这里').fontSize(13).fontColor($r('app.color.text_secondary'))
              }.width('100%').padding({ top: 64, bottom: 32, left: 16, right: 16 }).id('notification_empty')
            }
          }
        }.width('100%').height('100%').scrollBar(BarState.Off)
          .contentEndOffset(this.embedded ? 92 + this.bottomInset : 0)
          .onWillScroll((offset: number, state: ScrollState, source: ScrollSource): ScrollResult => {
            this.onReadScroll(offset, state, source);
            return { offsetRemain: offset };
          })
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 58, endMargin: 12 })
          .borderRadius(18).clip(true).id('notification_list')
      }.width('100%').layoutWeight(1).onRefreshing(() => { this.refreshing = true; void this.load(true); })
    }.width('100%').height('100%')
      .padding({ left: 16, right: 16, top: this.embedded ? this.topInset : 0, bottom: this.embedded ? 0 : 8 })
      .backgroundColor($r('app.color.page_background'))
      .onAppear(() => { if (this.embedded) { this.embeddedAppeared(); } })
      .onDisAppear(() => { if (this.embedded) { this.embeddedDisappeared(); } })
  }

  build() {
    if (this.embedded) {
      this.notificationContent()
    } else {
      NavDestination() {
        this.notificationContent()
      }.title('通知').padding({ top: this.topInset, bottom: this.bottomInset })
        .backgroundColor($r('app.color.page_background'))
        .onShown(() => { this.shown(); }).onHidden(() => { this.hidden(); })
        .onDisAppear(() => { this.hidden(); })
    }
  }
}
