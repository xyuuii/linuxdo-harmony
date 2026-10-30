import { ProfileField } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import {
  ForumUserProfile, ForumUserSummary, ForumUserActivityFilter, ForumUserActivityOption,
  ForumUserActivityEntry, ForumUserActivityPage, forumUserActivityFilters, forumUserDate
} from '../models/UserProfileModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { ForumAvatar, ForumErrorView } from '../components/ForumComponents';
import { materialFor } from '../services/MaterialPolicy';

@ComponentV2
export struct UserProfilePage {
  @Param username: string = '';
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param session: ForumSession = forumSession;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local profile: ForumUserProfile | undefined = undefined;
  @Local fields: ProfileField[] = [];
  @Local entries: ForumUserActivityEntry[] = [];
  @Local selectedFilter: ForumUserActivityFilter = ForumUserActivityFilter.Topics;
  @Local identityLoading: boolean = false;
  @Local summaryLoading: boolean = false;
  @Local activityLoading: boolean = false;
  @Local identityError: string = '';
  @Local summaryError: string = '';
  @Local activityError: string = '';
  @Local statsHidden: boolean = false;
  @Local actionsHidden: boolean = false;
  @Local needsLogin: boolean = false;
  @Local hasMore: boolean = false;
  @Local activityOffset: number = 0;
  @Local refreshing: boolean = false;
  private identityRequest: RequestCancellation | undefined = undefined;
  private summaryRequest: RequestCancellation | undefined = undefined;
  private activityRequest: RequestCancellation | undefined = undefined;
  private visible: boolean = false;
  private reloadOnShow: boolean = true;
  private lastActivityReset: boolean = true;
  private listScroller: Scroller = new Scroller();

  @Monitor('username', 'session.revision')
  accountChanged(): void {
    this.stopRequests(); this.profile = undefined; this.fields = []; this.entries = [];
    this.identityError = ''; this.summaryError = ''; this.activityError = '';
    this.statsHidden = false; this.actionsHidden = false; this.hasMore = false; this.activityOffset = 0;
    this.reloadOnShow = true;
    if (this.visible) { void this.loadIdentity(); }
  }

  private stopRequests(): void {
    this.identityRequest?.cancel(); this.summaryRequest?.cancel(); this.activityRequest?.cancel();
    this.identityRequest = undefined; this.summaryRequest = undefined; this.activityRequest = undefined;
    this.identityLoading = false; this.summaryLoading = false; this.activityLoading = false; this.refreshing = false;
  }
  private current(ownerId: number, revision: number, username: string, request: RequestCancellation): boolean {
    return this.visible && !request.isCancelled && (this.session.user?.id ?? 0) === ownerId &&
      this.session.revision === revision && this.username === username;
  }
  private async loadIdentity(): Promise<void> {
    if (!this.visible) { return; }
    const refreshing: boolean = this.refreshing;
    this.stopRequests();
    this.refreshing = refreshing;
    const request: RequestCancellation = new RequestCancellation();
    const ownerId: number = this.session.user?.id ?? 0;
    const revision: number = this.session.revision;
    const username: string = this.username;
    this.identityRequest = request; this.identityLoading = true; this.identityError = ''; this.needsLogin = false;
    this.profile = undefined; this.fields = []; this.entries = []; this.activityOffset = 0; this.hasMore = false;
    this.statsHidden = false; this.actionsHidden = false; this.reloadOnShow = true;
    try {
      const profile: ForumUserProfile = await forumApi.fetchUserProfile(username, request);
      if (this.identityRequest !== request || !this.current(ownerId, revision, username, request)) { return; }
      this.profile = profile; this.reloadOnShow = false;
      if (!profile.hidden) { void this.loadSummary(); void this.loadActivity(true); }
    } catch (error) {
      if (this.identityRequest === request && this.current(ownerId, revision, username, request)) {
        this.identityError = error instanceof ForumApiError ? error.message : '用户资料暂时无法加载';
        this.needsLogin = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.AuthenticationRequired || error.kind === ForumErrorKind.VerificationRequired);
      }
    } finally { if (this.identityRequest === request) { this.identityLoading = false; this.refreshing = false; } }
  }
  private async loadSummary(): Promise<void> {
    if (!this.visible || this.profile === undefined || this.profile.hidden) { return; }
    this.summaryRequest?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    const ownerId: number = this.session.user?.id ?? 0;
    const revision: number = this.session.revision;
    const username: string = this.username;
    this.summaryRequest = request; this.summaryLoading = true; this.summaryError = '';
    try {
      const summary: ForumUserSummary = await forumApi.fetchUserProfileSummary(username, request);
      if (this.summaryRequest !== request || !this.current(ownerId, revision, username, request)) { return; }
      this.fields = summary.fields; this.statsHidden = summary.canSeeStats === false;
      this.actionsHidden = summary.canSeeActions === false;
      if (this.actionsHidden) {
        this.activityRequest?.cancel(); this.activityRequest = undefined; this.activityLoading = false;
        this.entries = []; this.hasMore = false; this.activityError = '';
      }
    } catch (error) {
      if (this.summaryRequest === request && this.current(ownerId, revision, username, request)) {
        this.summaryError = error instanceof ForumApiError && (error.kind === ForumErrorKind.Forbidden || error.kind === ForumErrorKind.NotFound) ?
          '该成员的统计数据不可见' : '统计数据暂时无法加载';
      }
    } finally { if (this.summaryRequest === request) { this.summaryLoading = false; } }
  }
  private async loadActivity(reset: boolean): Promise<void> {
    if (!this.visible || this.profile === undefined || this.profile.hidden || this.actionsHidden ||
      (!reset && (this.activityLoading || !this.hasMore))) { return; }
    this.activityRequest?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    const ownerId: number = this.session.user?.id ?? 0;
    const revision: number = this.session.revision;
    const username: string = this.username;
    const filter: ForumUserActivityFilter = this.selectedFilter;
    this.activityRequest = request; this.activityLoading = true; this.activityError = ''; this.lastActivityReset = reset;
    if (reset) { this.entries = []; this.activityOffset = 0; this.hasMore = false; }
    try {
      const result: ForumUserActivityPage = await forumApi.fetchUserProfileActivity(username, filter, reset ? 0 : this.activityOffset, request);
      if (this.activityRequest !== request || !this.current(ownerId, revision, username, request) || this.selectedFilter !== filter) { return; }
      const combined: ForumUserActivityEntry[] = reset ? result.entries : this.entries.concat(result.entries);
      const seen: Set<string> = new Set<string>();
      this.entries = combined.filter((entry: ForumUserActivityEntry): boolean => {
        if (seen.has(entry.id)) { return false; } seen.add(entry.id); return true;
      });
      this.activityOffset = result.nextOffset; this.hasMore = result.hasMore;
    } catch (error) {
      if (this.activityRequest === request && this.current(ownerId, revision, username, request)) {
        this.activityError = error instanceof ForumApiError && (error.kind === ForumErrorKind.Forbidden || error.kind === ForumErrorKind.NotFound) ?
          '该成员的活动记录不可见' : error instanceof ForumApiError ? error.message : '用户活动暂时无法加载';
      }
    } finally { if (this.activityRequest === request) { this.activityLoading = false; } }
  }
  private chooseFilter(filter: ForumUserActivityFilter): void {
    if (filter === this.selectedFilter) { return; }
    this.selectedFilter = filter; void this.loadActivity(true);
  }

  @Builder
  identityHeader() {
    if (this.profile !== undefined) {
      Column({ space: 16 }) {
        Row({ space: 16 }) {
          ForumAvatar({ name: this.profile.username, url: this.profile.avatarUrl, avatarSize: 72 })
          Column({ space: 5 }) {
            Text(this.profile.name || this.profile.username).fontSize(23).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`@${this.profile.username}`).fontSize(14).fontColor($r('app.color.text_secondary'))
              .copyOption(CopyOptions.LocalDevice)
            if (this.profile.title) { Text(this.profile.title).fontSize(12).fontColor($r('app.color.text_secondary')) }
            Text(this.profile.trustLevel >= 0 ? `信任等级 ${this.profile.trustLevel}` : '信任等级未公开')
              .fontSize(12).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
        if (this.profile.hidden) {
          Text('该成员已隐藏个人资料').fontSize(14).fontColor($r('app.color.text_secondary')).width('100%').padding({ top: 8, bottom: 8 })
        } else {
          Text(this.profile.bio || '个人简介未提供').fontSize(14).lineHeight(22).fontColor($r('app.color.text_primary'))
            .width('100%').copyOption(CopyOptions.LocalDevice)
          Row({ space: 12 }) {
            Text(`加入于 ${forumUserDate(this.profile.createdAt)}`).fontSize(11).fontColor($r('app.color.text_secondary'))
            Text(`最近活跃 ${forumUserDate(this.profile.lastSeenAt)}`).fontSize(11).fontColor($r('app.color.text_secondary'))
          }.width('100%').alignItems(VerticalAlign.Top)
          if (this.profile.location) { Text(this.profile.location).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%') }
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor($r('app.color.surface')).borderRadius(20)
    }
  }

  @Builder
  summaryContent() {
    Column({ space: 8 }) {
      Row() {
        Text('社区统计').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (this.summaryLoading) { LoadingProgress().width(20).height(20) }
      }.width('100%').padding({ left: 16, right: 16, top: 14 })
      if (this.statsHidden) { Text('该成员的统计数据未公开').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 16, right: 16 }) }
      if (this.fields.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.fields, (field: ProfileField) => {
            Column({ space: 5 }) {
              Text(field.value).fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1)
              Text(field.label).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.width('50%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 10, top: 10, bottom: 10 })
          }, (field: ProfileField): string => field.label)
        }.width('100%')
      }
      if (this.summaryError) {
        Row() {
          Text(this.summaryError).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button('重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.accent')).fontSize(12)
            .onClick((): void => { void this.loadSummary(); })
        }.width('100%').padding({ left: 16, right: 8 })
      }
    }.width('100%').padding({ bottom: 10 }).backgroundColor($r('app.color.surface')).borderRadius(20)
  }

  @Builder
  activityRow(entry: ForumUserActivityEntry) {
    Column({ space: 8 }) {
      Text(entry.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .maxLines(2).lineHeight(23).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      if (entry.excerpt) {
        Text(entry.excerpt).fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary'))
          .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      Row() {
        Text(entry.actionType === 4 ? '发表话题' : `回复 · #${entry.postNumber}`).fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text(forumUserDate(entry.createdAt)).fontSize(11).fontColor($r('app.color.text_secondary'))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface')).borderRadius(16)
      .onClick((): void => { this.onOpenTopic(entry.topicId, entry.postNumber); }).id(`user_activity_${entry.id}`)
  }

  build() {
    NavDestination() {
      Refresh({ refreshing: this.refreshing }) {
        List({ scroller: this.listScroller, space: 12 }) {
          if (this.profile !== undefined) { ListItem() { this.identityHeader(); } }
          if (this.profile !== undefined && !this.profile.hidden) {
            ListItem() { this.summaryContent(); }
            ListItem() {
              Row({ space: 4 }) {
                ForEach(forumUserActivityFilters, (option: ForumUserActivityOption) => {
                  Button(option.label, { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
                    .layoutWeight(1).height(40).fontSize(14)
                    .fontColor(this.selectedFilter === option.value ? $r('app.color.accent') : $r('app.color.text_secondary'))
                    .backgroundColor(this.selectedFilter === option.value ? $r('app.color.selected_background') : Color.Transparent)
                    .accessibilitySelected(this.selectedFilter === option.value).enabled(!this.actionsHidden)
                    .onClick((): void => { this.chooseFilter(option.value); }).id(`user_activity_filter_${option.value}`)
                }, (option: ForumUserActivityOption): string => option.value)
              }.width('100%').padding(4).backgroundColor($r('app.color.surface')).borderRadius(24)
                .systemMaterial(materialFor(this.appearance))
            }
            ForEach(this.entries, (entry: ForumUserActivityEntry) => { ListItem() { this.activityRow(entry); } },
              (entry: ForumUserActivityEntry): string => entry.id)
          }
          ListItem() {
            Column() {
              if (this.identityError) {
                ForumErrorView({ message: this.identityError, needsVerification: this.needsLogin,
                  onRetry: (): void => { void this.loadIdentity(); }, onVerify: this.onLogin })
              } else if (this.identityLoading || this.activityLoading) { LoadingProgress().width(30).height(30).margin(20) }
              else if (this.actionsHidden) { Text('该成员的活动记录未公开').fontSize(14).fontColor($r('app.color.text_secondary')).padding(20) }
              else if (this.activityError) {
                ForumErrorView({ message: this.activityError, onRetry: (): void => { void this.loadActivity(this.lastActivityReset); }, onVerify: this.onLogin })
              } else if (this.hasMore) {
                Button('加载更多', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
                  .fontColor($r('app.color.accent')).onClick((): void => { void this.loadActivity(false); }).margin(8)
              } else if (this.profile !== undefined && !this.profile.hidden && this.entries.length === 0) {
                Text(this.selectedFilter === ForumUserActivityFilter.Topics ? '暂无可见话题' : this.selectedFilter === ForumUserActivityFilter.Replies ? '暂无可见回复' : '暂无可见活动')
                  .fontSize(14).fontColor($r('app.color.text_secondary')).padding(20)
              }
            }.width('100%')
          }
        }.width('100%').height('100%').padding({ left: 16, right: 16 }).contentStartOffset(12).contentEndOffset(24)
          .scrollBar(BarState.Off).onReachEnd((): void => { if (!this.activityError) { void this.loadActivity(false); } })
      }.onRefreshing((): void => { this.refreshing = true; void this.loadIdentity(); })
    }.title('个人主页').padding({ top: this.topInset, bottom: this.bottomInset }).backgroundColor($r('app.color.page_background'))
      .onShown((): void => { this.visible = true; if (this.reloadOnShow || this.profile === undefined) { void this.loadIdentity(); } })
      .onHidden((): void => {
        this.visible = false;
        this.reloadOnShow = this.reloadOnShow || this.identityLoading || this.summaryLoading || this.activityLoading;
        this.stopRequests();
      })
      .onDisAppear((): void => { this.visible = false; this.stopRequests(); })
  }
}
