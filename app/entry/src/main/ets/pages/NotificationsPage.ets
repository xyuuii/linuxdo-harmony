import { ForumNotification, NotificationFilter, NotificationPage, notificationFilters, NotificationFilterOption } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';
import { ForumSession } from '../models/ForumSession';
import { ForumAvatar, ForumErrorView } from '../components/ForumComponents';
import { relativeTime } from '../services/ForumPresentation';

@ComponentV2
export struct NotificationsPage {
  @Param session: ForumSession = forumSession;
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local items: ForumNotification[] = [];
  @Local filterIndex: number = 0;
  @Local notificationOffset: number = 0;
  @Local hasMore: boolean = false;
  @Local busy: boolean = false;
  @Local refreshing: boolean = false;
  @Local error: string = '';
  @Local needsLogin: boolean = false;
  private request: RequestCancellation | undefined = undefined;

  @Monitor('session.revision')
  accountChanged(): void {
    this.request?.cancel(); this.request = undefined;
    this.items = []; this.notificationOffset = 0; this.hasMore = false; this.busy = false;
    this.error = ''; this.needsLogin = this.session.user === undefined;
  }

  private async load(reset: boolean): Promise<void> {
    if (forumSession.user === undefined) { this.error = '登录后查看回复、提及和私信。'; this.needsLogin = true; return; }
    if (this.busy && !reset) { return; }
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsLogin = false;
    const userId: number = forumSession.user.id;
    try {
      const filter: NotificationFilter = notificationFilters[this.filterIndex].value;
      const result: NotificationPage = await forumApi.fetchNotifications(reset ? 0 : this.notificationOffset, filter, request);
      if (this.request !== request || forumSession.user?.id !== userId) { return; }
      const merged: ForumNotification[] = reset ? result.notifications : this.items.concat(result.notifications);
      const seen: Set<number> = new Set<number>();
      this.items = merged.filter((item: ForumNotification): boolean => {
        if (seen.has(item.id)) { return false; } seen.add(item.id); return true;
      });
      this.notificationOffset = result.nextOffset; this.hasMore = result.hasMore;
      void forumSession.refreshUnread();
    } catch (error) {
      if (this.request === request) {
        this.error = error instanceof ForumApiError ? error.message : '通知暂时无法加载';
        this.needsLogin = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; this.refreshing = false; } }
  }

  private open(item: ForumNotification): void {
    if (!item.read) {
      void forumApi.markNotificationRead(item.id).then(() => {
        this.items = this.items.map((value: ForumNotification): ForumNotification => {
          return value.id === item.id ? { id: value.id, type: value.type, read: true, title: value.title, label: value.label,
            actor: value.actor, avatarUrl: value.avatarUrl, createdAt: value.createdAt, topicId: value.topicId,
            postNumber: value.postNumber } : value;
        });
        void forumSession.refreshUnread();
      }).catch(() => { this.getUIContext().getPromptAction().showToast({ message: '已读状态暂时未同步' }); });
    }
    if (item.topicId > 0) { this.onOpenTopic(item.topicId, Math.max(1, item.postNumber)); }
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          ForEach(notificationFilters, (filter: NotificationFilterOption, index: number) => {
            Button(filter.label, { type: ButtonType.Capsule }).fontSize(14).height(38).layoutWeight(1)
              .fontColor(this.filterIndex === index ? $r('app.color.on_accent') : $r('app.color.text_secondary'))
              .backgroundColor(this.filterIndex === index ? $r('app.color.accent') : $r('app.color.surface'))
              .onClick(() => { this.filterIndex = index; void this.load(true); })
          }, (filter: NotificationFilterOption): string => filter.value)
        }.width('100%')
        Refresh({ refreshing: this.refreshing }) {
          List({ space: 10 }) {
            ForEach(this.items, (item: ForumNotification) => {
              ListItem() {
                Row({ space: 12 }) {
                  ForumAvatar({ name: item.actor, url: item.avatarUrl })
                  Column({ space: 8 }) {
                    Row() {
                      Text(item.label).fontSize(12).fontColor($r('app.color.accent'))
                      Blank()
                      Text(relativeTime(item.createdAt)).fontSize(11).fontColor($r('app.color.text_secondary'))
                    }.width('100%')
                    Text(item.title).fontSize(16).fontWeight(item.read ? FontWeight.Normal : FontWeight.Medium)
                      .fontColor($r('app.color.text_primary')).lineHeight(24).maxLines(3)
                    Text(item.actor).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  if (!item.read) { Circle().width(8).height(8).fill($r('app.color.accent')) }
                }.width('100%').padding(18).backgroundColor($r('app.color.surface')).borderRadius(22)
                  .onClick(() => { this.open(item); }).id(`notification_${item.id}`)
              }
            }, (item: ForumNotification): string => String(item.id))
            ListItem() {
              if (this.error) {
                ForumErrorView({ message: this.error, needsVerification: this.needsLogin,
                  onRetry: (): void => { void this.load(true); }, onVerify: this.onLogin })
              } else if (this.busy) { LoadingProgress().width(32).height(32).margin(24) }
              else if (this.hasMore) {
                Button('更早的通知').height(48).width('100%').fontColor($r('app.color.accent'))
                  .backgroundColor($r('app.color.surface')).onClick(() => { void this.load(false); })
              } else if (!this.items.length) {
                Text('暂时没有通知').fontColor($r('app.color.text_secondary')).padding(24)
              }
            }
          }.width('100%').height('100%').scrollBar(BarState.Off)
        }.width('100%').layoutWeight(1).onRefreshing(() => { this.refreshing = true; void this.load(true); })
      }.width('100%').height('100%').padding(20)
    }.title('通知').backgroundColor($r('app.color.page_background'))
      .onReady(() => { void this.load(true); }).onDisAppear(() => { this.request?.cancel(); })
  }
}
