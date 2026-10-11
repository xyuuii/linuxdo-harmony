import { ProfileSection, ProfilePage as ProfileContent, ProfileEntry, ProfileField } from '../models/ForumModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';
import { ForumSession } from '../models/ForumSession';
import { ForumAvatar, ForumErrorView } from '../components/ForumComponents';

@ComponentV2
export struct ProfileSectionPage {
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
  private request: RequestCancellation | undefined = undefined;

  @Monitor('session.revision')
  accountChanged(): void {
    this.request?.cancel(); this.request = undefined;
    this.fields = []; this.entries = []; this.hasMore = false; this.cursor = 0; this.busy = false;
    this.error = ''; this.needsLogin = this.session.user === undefined;
  }

  private title(): string {
    if (this.section === ProfileSection.Summary) { return '我的总结'; }
    if (this.section === ProfileSection.Activity) { return '活动'; }
    if (this.section === ProfileSection.Messages) { return '私信'; }
    return '账号与邮箱';
  }

  private async load(reset: boolean): Promise<void> {
    const username: string = forumSession.user?.username || '';
    if (!username) { this.needsLogin = true; this.error = '请先登录再查看个人内容。'; return; }
    if (this.busy && !reset) { return; }
    this.request?.cancel();
    const request: RequestCancellation = new RequestCancellation();
    this.request = request; this.busy = true; this.error = ''; this.needsLogin = false;
    try {
      const result: ProfileContent = await forumApi.fetchProfile(username, this.section, reset ? 0 : this.cursor);
      if (this.request !== request || forumSession.user?.username !== username) { return; }
      this.fields = result.fields;
      const merged: ProfileEntry[] = reset ? result.entries : this.entries.concat(result.entries);
      const seen: Set<string> = new Set<string>();
      this.entries = merged.filter((entry: ProfileEntry): boolean => {
        if (seen.has(entry.id)) { return false; } seen.add(entry.id); return true;
      });
      this.cursor = result.nextCursor; this.hasMore = result.hasMore;
    } catch (error) {
      if (this.request === request) {
        this.error = error instanceof ForumApiError ? error.message : '个人内容暂时无法加载';
        this.needsLogin = error instanceof ForumApiError &&
          (error.kind === ForumErrorKind.VerificationRequired || error.kind === ForumErrorKind.AuthenticationRequired);
      }
    } finally { if (this.request === request) { this.busy = false; } }
  }

  build() {
    NavDestination() {
      List({ space: 12 }) {
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
              .onClick(() => { if (entry.topicId > 0) { this.onOpenTopic(entry.topicId, Math.max(1, entry.postNumber)); } })
          }
        }, (entry: ProfileEntry): string => entry.id)
        ListItem() {
          if (this.error) {
            ForumErrorView({ message: this.error, needsVerification: this.needsLogin,
              onRetry: (): void => { void this.load(true); }, onVerify: this.onLogin })
          } else if (this.busy) { LoadingProgress().width(32).height(32).margin(24) }
          else if (this.hasMore) {
            Button('加载更多').height(48).width('100%').fontColor($r('app.color.accent'))
              .backgroundColor($r('app.color.surface')).onClick(() => { void this.load(false); })
          } else if (this.entries.length === 0 && this.fields.length === 0) {
            Text('暂时没有内容').fontColor($r('app.color.text_secondary')).padding(24)
          }
        }
      }.width('100%').height('100%').padding(20).scrollBar(BarState.Off)
    }.title(this.title()).backgroundColor($r('app.color.page_background'))
      .onReady(() => { void this.load(true); }).onDisAppear(() => { this.request?.cancel(); })
  }
}
