import { ProfileSection, ProfileField, ProfilePage as ProfileContent } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation } from '../services/ForumApi';
import { ForumAvatar } from '../components/ForumComponents';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { materialFor } from '../services/MaterialPolicy';

interface ProfileMenuItem { id: ProfileSection; title: string; subtitle: string; symbol: Resource; }
interface ProfileStatistic { label: string; count: string; section: ProfileSection; }

@ComponentV2
export struct ProfilePage {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param session: ForumSession = forumSession;
  @Param listScroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Event onOpenSection: (section: ProfileSection) => void = (): void => {};
  @Event onSettings: () => void = (): void => {};
  @Event onDiagnostics: () => void = (): void => {};
  @Event onLoggedOut: () => void = (): void => {};
  @Event onOpenUser: (username: string) => void = (): void => {};
  @Local topicCount: string = '—';
  @Local replyCount: string = '—';
  @Local likesReceived: string = '—';
  @Local statisticsError: boolean = false;
  private mounted: boolean = false;
  private summaryRequest: RequestCancellation | undefined = undefined;
  private shortcuts: ProfileMenuItem[] = [
    { id: ProfileSection.Bookmarks, title: '收藏', subtitle: '收藏的话题与帖子', symbol: $r('sys.symbol.bookmark') },
    { id: ProfileSection.Drafts, title: '草稿', subtitle: '继续本机编辑', symbol: $r('sys.symbol.doc_text') }
  ];
  private participation: ProfileMenuItem[] = [
    { id: ProfileSection.Topics, title: '我的话题', subtitle: '', symbol: $r('sys.symbol.doc_text') },
    { id: ProfileSection.Replies, title: '我的回复', subtitle: '', symbol: $r('sys.symbol.message') },
    { id: ProfileSection.Read, title: '已读话题', subtitle: '', symbol: $r('sys.symbol.clock') },
    { id: ProfileSection.Likes, title: '我点赞过', subtitle: '', symbol: $r('sys.symbol.heart') },
    { id: ProfileSection.Boosts, title: '我的 Boost', subtitle: '', symbol: $r('sys.symbol.ellipsis_message') },
    { id: ProfileSection.Votes, title: '我的投票', subtitle: '', symbol: $r('sys.symbol.hand_thumbsup') },
    { id: ProfileSection.Solutions, title: '我的方案', subtitle: '', symbol: $r('sys.symbol.checkmark_circle') },
    { id: ProfileSection.Activity, title: '全部活动', subtitle: '', symbol: $r('sys.symbol.list_bullet') }
  ];
  private community: ProfileMenuItem[] = [
    { id: ProfileSection.Messages, title: '私信', subtitle: '', symbol: $r('sys.symbol.envelope') },
    { id: ProfileSection.Notifications, title: '互动通知', subtitle: '', symbol: $r('sys.symbol.bell') },
    { id: ProfileSection.Summary, title: '我的总结', subtitle: '', symbol: $r('sys.symbol.list_bullet') },
    { id: ProfileSection.Account, title: '账号与邮箱', subtitle: '', symbol: $r('sys.symbol.person') }
  ];

  aboutToAppear(): void { this.mounted = true; void this.loadStatistics(); }
  aboutToDisappear(): void { this.mounted = false; this.summaryRequest?.cancel(); this.summaryRequest = undefined; }

  @Monitor('session.revision')
  accountChanged(): void {
    this.summaryRequest?.cancel(); this.summaryRequest = undefined;
    this.topicCount = '—'; this.replyCount = '—'; this.likesReceived = '—'; this.statisticsError = false;
    if (this.mounted) { void this.loadStatistics(); }
  }

  private async loadStatistics(): Promise<void> {
    this.summaryRequest?.cancel(); this.summaryRequest = undefined;
    const ownerId: number = this.session.user?.id || 0;
    const username: string = this.session.user?.username || '';
    if (!this.mounted || !ownerId || !username) { return; }
    const revision: number = this.session.revision;
    const request: RequestCancellation = new RequestCancellation(); this.summaryRequest = request;
    this.statisticsError = false;
    try {
      const summary: ProfileContent = await forumApi.fetchProfile(username, ProfileSection.Summary, 0, undefined, undefined, request);
      if (!this.mounted || this.summaryRequest !== request || this.session.user?.id !== ownerId || this.session.revision !== revision) { return; }
      this.topicCount = summary.fields.find((field: ProfileField): boolean => field.label === '发表话题')?.value || '—';
      this.replyCount = summary.fields.find((field: ProfileField): boolean => field.label === '回复数量')?.value || '—';
      this.likesReceived = summary.fields.find((field: ProfileField): boolean => field.label === '收到赞')?.value || '—';
    } catch {
      if (this.mounted && this.summaryRequest === request && this.session.user?.id === ownerId && this.session.revision === revision) {
        this.statisticsError = true;
      }
    }
  }

  private openSection(section: ProfileSection): void {
    if (this.session.user === undefined) { this.onLogin(); }
    else { this.onOpenSection(section); }
  }

  private async logout(): Promise<void> {
    try { await this.session.logout(); this.onLoggedOut(); }
    catch { this.getUIContext().getPromptAction().showToast({ message: '本机登录状态暂时无法清除，请重试。' }); }
  }

  @Builder
  statistic($$: ProfileStatistic) {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Column({ space: 5 }) {
        Text($$.count).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).maxLines(1)
        Text($$.label).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.width('100%')
    }.layoutWeight(1).height(76).backgroundColor(Color.Transparent)
      .accessibilityText(`${$$.label}，${$$.count}`).onClick((): void => { this.openSection($$.section); })
  }

  @Builder
  menuRow(menu: ProfileMenuItem) {
    Row({ space: 13 }) {
      SymbolGlyph(menu.symbol).fontSize(21).fontColor([$r('app.color.text_secondary')])
      Text(menu.title).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.text_secondary')])
    }.width('100%').padding({ left: 16, right: 16 }).height(54).id(`profile_${menu.id}`)
      .accessibilityGroup(true).accessibilityText(menu.title).onClick(() => { this.openSection(menu.id); })
  }

  build() {
    Scroll(this.listScroller) {
      Column({ space: 20 }) {
        Row() {
          Blank().width(44)
          Text('我的').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center).layoutWeight(1)
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([$r('app.color.text_primary')])
          }.width(44).height(44).backgroundColor($r('app.color.surface'))
            .systemMaterial(materialFor(this.appearance)).accessibilityText('外观与阅读设置')
            .onClick(() => { this.onSettings(); }).id('profile_settings_button')
        }.width('100%').height(48)
        Column({ space: 12 }) {
          Row({ space: 14 }) {
            ForumAvatar({ name: this.session.user?.username || 'L', url: this.session.user?.avatarUrl || '', avatarSize: 64 })
            Column({ space: 6 }) {
              Text(this.session.user?.name || this.session.user?.username || '欢迎来到 LINUX DO')
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.session.user !== undefined ? `@${this.session.user.username}` : '登录后参与交流，查看个人消息')
                .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.session.user !== undefined) {
                Text(`信任等级 ${this.session.user.trustLevel}`).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.text_secondary')])
          }.width('100%').padding({ left: 4, right: 4, top: 4, bottom: 4 })
            .onClick((): void => {
              if (this.session.user !== undefined) { this.onOpenUser(this.session.user.username); }
              else { this.onLogin(); }
            }).id('profile_identity')
          if (this.session.user !== undefined) {
            Row() {
              this.statistic({ label: '话题', count: this.topicCount, section: ProfileSection.Topics })
              this.statistic({ label: '回复', count: this.replyCount, section: ProfileSection.Replies })
              this.statistic({ label: '收到的赞', count: this.likesReceived, section: ProfileSection.Summary })
            }.width('100%').id('profile_statistics')
            if (this.statisticsError) {
              Button('统计暂未加载，点此重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(36).fontSize(12)
                .fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
                .onClick((): void => { void this.loadStatistics(); })
            }
          } else {
            Button('登录 LINUX DO', { type: ButtonType.Capsule }).width('100%').height(50)
              .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).id('login_entry')
              .onClick(() => { this.onLogin(); })
          }
        }.width('100%')
        Row({ space: 12 }) {
          ForEach(this.shortcuts, (menu: ProfileMenuItem) => {
            Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
              Row({ space: 12 }) {
                SymbolGlyph(menu.symbol).fontSize(24).fontColor([$r('app.color.accent')])
                Column({ space: 5 }) {
                  Text(menu.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  Text(menu.subtitle).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }.layoutWeight(1).height(82).padding(14).borderRadius(18).backgroundColor($r('app.color.surface'))
              .systemMaterial(materialFor(this.appearance)).id(`profile_${menu.id}`)
              .onClick(() => { this.openSection(menu.id); })
          }, (menu: ProfileMenuItem): string => menu.id)
        }.width('100%')
        Column({ space: 8 }) {
          Text('我的参与').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ left: 12 })
          Column() {
            ForEach(this.participation, (menu: ProfileMenuItem, index: number) => {
              this.menuRow(menu)
              if (index < this.participation.length - 1) { Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 }) }
            }, (menu: ProfileMenuItem): string => menu.id)
          }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: 8 }) {
          Text('账户').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ left: 12 })
          Column() {
            ForEach(this.community, (item: ProfileMenuItem) => {
              this.menuRow(item)
              Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 })
            }, (item: ProfileMenuItem): string => item.id)
            Row({ space: 13 }) {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(21).fontColor([$r('app.color.text_secondary')])
              Text('外观与阅读设置').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding({ left: 16, right: 16 }).height(54)
              .onClick(() => { this.onSettings(); }).id('settings_entry')
            Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 })
            Row({ space: 13 }) {
              SymbolGlyph($r('sys.symbol.info_circle')).fontSize(21).fontColor([$r('app.color.text_secondary')])
              Text('关于与连接诊断').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding({ left: 16, right: 16 }).height(54).onClick(() => { this.onDiagnostics(); })
              .id('profile_diagnostics')
          }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
        }.width('100%').alignItems(HorizontalAlign.Start)
        if (this.session.user !== undefined) {
          Button('退出登录', { type: ButtonType.Capsule }).width('100%').height(48)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_secondary'))
            .onClick(() => {
              this.getUIContext().showAlertDialog({ title: '退出本机登录？', message: '将清除本应用的登录状态和缓存。',
                systemMaterial: materialFor(this.appearance), backgroundColor: $r('app.color.surface'),
                primaryButton: { value: '取消', action: (): void => {} },
                secondaryButton: { value: '退出登录', action: (): void => { void this.logout(); } } });
            })
        }
      }.width('100%').constraintSize({ maxWidth: 640 }).alignItems(HorizontalAlign.Start)
        .padding({ left: 18, right: 18, top: this.topInset, bottom: 112 + this.bottomInset })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .onWillScroll((_x: number, y: number, state: ScrollState, source: ScrollSource): void => { this.onReadScroll(y, state, source); })
  }
}
