import { ProfileSection, ProfileBoostDirection, ProfilePage as ProfileContent, ProfileEntry, ProfileField } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';
import { ForumSession } from '../models/ForumSession';
import { ForumAvatar, ForumErrorView } from '../components/ForumComponents';

@ComponentV2
export struct ProfileSectionPage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param session: ForumSession = forumSession;
  @Param section: ProfileSection = ProfileSection.Summary;
  @Event onOpenTopic: (id: number, postNumber: number) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local fields: ProfileField[] = [];
  @Local entries: ProfileEntry[] = [];
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local cursor: number = 0;
  @Local hasMore: boolean = false;
  @Local needsLogin: boolean = false;
  @Local boostDirection: ProfileBoostDirection = ProfileBoostDirection.Given;
  private request: RequestCancellation | undefined = undefined;
  private lastLoadReset: boolean = true;
  private visible: boolean = false;
  private reloadOnShow: boolean = true;

  @Monitor('session.revision')
  accountChanged(): void {
    this.request?.cancel(); this.request = undefined;
    this.fields = []; this.entries = []; this.hasMore = false; this.cursor = 0; this.busy = false;
    this.error = ''; this.needsLogin = this.session.user === undefined;
    this.reloadOnShow = true;
    if (this.visible) { void this.load(true); }
  }

  private title(): string {
    if (this.section === ProfileSection.Summary) { return '我的总结'; }
    if (this.section === ProfileSection.Activity) { return '活动'; }
    if (this.section === ProfileSection.Likes) { return '我点赞过'; }
    if (this.section === ProfileSection.Messages) { return '私信'; }
    if (this.section === ProfileSection.Bookmarks) { return '收藏'; }
    if (this.section === ProfileSection.Topics) { return '我的话题'; }
    if (this.section === ProfileSection.Replies) { return '我的回复'; }
    if (this.section === ProfileSection.Read) { return '已读话题'; }
    if (this.section === ProfileSection.Votes) { return '我的投票'; }
    if (this.section === ProfileSection.Solutions) { return '我的方案'; }
    if (this.section === ProfileSection.Boosts) { return '我的 Boost'; }
    return '账号与邮箱';
  }

  private emptyMessage(): string {
    if (this.section === ProfileSection.Likes) { return '还没有送出喜欢，给喜欢的帖子点个赞吧。'; }
    if (this.section === ProfileSection.Bookmarks) { return '还没有收藏的话题或帖子'; }
    if (this.section === ProfileSection.Topics) { return '还没有发表话题'; }
    if (this.section === ProfileSection.Replies) { return '还没有发表回复'; }
    if (this.section === ProfileSection.Read) { return '社区暂无已读话题记录'; }
    if (this.section === ProfileSection.Votes) { return '还没有未归档的话题投票'; }
    if (this.section === ProfileSection.Solutions) { return '还没有可见的被采纳方案'; }
    if (this.section === ProfileSection.Boosts) {
      return this.boostDirection === ProfileBoostDirection.Given ? '还没有发出过 Boost' : '还没有收到 Boost';
    }
    return '暂时没有内容';
  }

  private pageIsVisible(): boolean { return this.visible; }

  private async load(reset: boolean): Promise<void> {
    if (this.visible === false) { return; }
    const username: string = this.session.user?.username || '';
    const ownerId: number = this.session.user?.id || 0;
    const revision: number = this.session.revision;
    const section: ProfileSection = this.section;
    const boostDirection: ProfileBoostDirection = this.boostDirection;
    if (!username) { this.needsLogin = true; this.error = '请先登录再查看个人内容。'; return; }
    if (this.busy && !reset) { return; }
    this.lastLoadReset = reset;
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsLogin = false;
    try {
      const result: ProfileContent = await forumApi.fetchProfile(username, section, reset ? 0 : this.cursor,
        undefined, undefined, request, boostDirection);
      if (!this.pageIsVisible() || this.request !== request || request.isCancelled || this.session.user?.id !== ownerId ||
        this.session.revision !== revision || this.section !== section || this.boostDirection !== boostDirection) { return; }
      this.fields = result.fields;
      const merged: ProfileEntry[] = reset ? result.entries : this.entries.concat(result.entries);
      const seen: Set<string> = new Set<string>();
      this.entries = merged.filter((entry: ProfileEntry): boolean => {
        if (seen.has(entry.id)) { return false; } seen.add(entry.id); return true;
      });
      this.cursor = result.nextCursor; this.hasMore = result.hasMore;
      this.reloadOnShow = false;
    } catch (error) {
      if (this.pageIsVisible() && this.request === request && !request.isCancelled && this.session.user?.id === ownerId && this.session.revision === revision) {
        this.error = error instanceof ForumApiError ? error.message : '个人内容暂时无法加载';
        this.needsLogin = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; } }
  }

  private chooseBoostDirection(direction: ProfileBoostDirection): void {
    if (this.boostDirection === direction) { return; }
    this.request?.cancel(); this.boostDirection = direction;
    this.entries = []; this.fields = []; this.cursor = 0; this.hasMore = false; this.error = '';
    void this.load(true);
  }

  build() {
    NavDestination() {
      List({ space: 12 }) {
        if (this.section === ProfileSection.Boosts) {
          ListItem() {
            Row({ space: 8 }) {
              Button('我发出的', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
                .layoutWeight(1).height(42).fontColor(this.boostDirection === ProfileBoostDirection.Given ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .backgroundColor(this.boostDirection === ProfileBoostDirection.Given ? $r('app.color.selected_background') : $r('app.color.surface'))
                .accessibilitySelected(this.boostDirection === ProfileBoostDirection.Given)
                .onClick((): void => { this.chooseBoostDirection(ProfileBoostDirection.Given); }).id('profile_boosts_given')
              Button('我收到的', { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
                .layoutWeight(1).height(42).fontColor(this.boostDirection === ProfileBoostDirection.Received ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .backgroundColor(this.boostDirection === ProfileBoostDirection.Received ? $r('app.color.selected_background') : $r('app.color.surface'))
                .accessibilitySelected(this.boostDirection === ProfileBoostDirection.Received)
                .onClick((): void => { this.chooseBoostDirection(ProfileBoostDirection.Received); }).id('profile_boosts_received')
            }.width('100%')
          }
        }
        if (this.section === ProfileSection.Votes || this.section === ProfileSection.Solutions) {
          ListItem() {
            Text(this.section === ProfileSection.Votes ? '仅显示未归档的话题投票，不含正文内的投票' : '仅显示你的回复被采纳为解答的记录')
              .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 4, right: 4, bottom: 4 })
          }
        }
        ForEach(this.fields, (field: ProfileField) => {
          ListItem() {
            Row({ space: 16 }) {
              Text(field.label).fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1)
              Text(field.value).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                .constraintSize({ maxWidth: '65%' }).copyOption(CopyOptions.LocalDevice)
            }.width('100%').padding(18).backgroundColor($r('app.color.surface')).borderRadius(20)
          }
        }, (field: ProfileField): string => field.label)
        ForEach(this.entries, (entry: ProfileEntry) => {
          ListItem() {
            Row({ space: 12 }) {
              if (entry.avatarUrl) { ForumAvatar({ name: entry.actor, url: entry.avatarUrl }) }
              Column({ space: 8 }) {
                Text(entry.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  .lineHeight(25).maxLines(3)
                Text(entry.subtitle).fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(21).maxLines(3)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              if (entry.topicId > 0) {
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
              }
            }.width('100%').padding(18).backgroundColor($r('app.color.surface')).borderRadius(22)
              .enabled(entry.topicId > 0)
              .onClick(() => { if (entry.topicId > 0) { this.onOpenTopic(entry.topicId, Math.max(1, entry.postNumber)); } })
          }
        }, (entry: ProfileEntry): string => entry.id)
        ListItem() {
          if (this.error) {
            ForumErrorView({ message: this.error, needsVerification: this.needsLogin,
              onRetry: (): void => { void this.load(this.lastLoadReset); }, onVerify: this.onLogin })
          } else if (this.busy) { LoadingProgress().width(32).height(32).margin(24) }
          else if (this.hasMore) {
            Button('加载更多').height(48).width('100%').fontColor($r('app.color.accent'))
              .backgroundColor($r('app.color.surface')).onClick(() => { void this.load(false); })
          } else if (this.entries.length === 0 && this.fields.length === 0) {
            Text(this.emptyMessage())
              .fontColor($r('app.color.text_secondary')).padding(24)
          }
        }
      }.width('100%').height('100%').padding(20).scrollBar(BarState.Off)
        .onReachEnd((): void => { if (this.hasMore && !this.error && !this.busy) { void this.load(false); } })
    }.title(this.title()).padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor($r('app.color.page_background'))
      .onShown((): void => { this.visible = true; if (this.reloadOnShow) { void this.load(this.lastLoadReset); } })
      .onHidden((): void => {
        this.visible = false; this.reloadOnShow = this.reloadOnShow || this.busy;
        this.request?.cancel(); this.request = undefined; this.busy = false;
      })
      .onDisAppear((): void => { this.visible = false; this.request?.cancel(); this.request = undefined; this.busy = false; })
  }
}
