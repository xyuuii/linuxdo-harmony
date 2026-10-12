import { ProfileSection } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { ForumAvatar } from '../components/ForumComponents';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { materialFor } from '../services/MaterialPolicy';

interface ProfileMenuItem { id: ProfileSection; title: string; subtitle: string; symbol: Resource; }

@ComponentV2
export struct ProfilePage {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param listScroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onReadScroll: (offset: number, state: ScrollState, source: ScrollSource) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Event onOpenSection: (section: ProfileSection) => void = (): void => {};
  @Event onSettings: () => void = (): void => {};
  @Event onDiagnostics: () => void = (): void => {};
  @Event onLoggedOut: () => void = (): void => {};
  private shortcuts: ProfileMenuItem[] = [
    { id: ProfileSection.Summary, title: '我的总结', subtitle: '参与、交流与成长', symbol: $r('sys.symbol.list_bullet') },
    { id: ProfileSection.Messages, title: '我的私信', subtitle: '查看私信话题', symbol: $r('sys.symbol.envelope') }
  ];
  private participation: ProfileMenuItem[] = [
    { id: ProfileSection.Activity, title: '我的活动', subtitle: '发起的话题与回复', symbol: $r('sys.symbol.clock') },
    { id: ProfileSection.Likes, title: '我点赞过', subtitle: '查看送出的喜欢', symbol: $r('sys.symbol.heart') },
    { id: ProfileSection.Notifications, title: '互动通知', subtitle: '回复、提及与互动', symbol: $r('sys.symbol.bell') }
  ];

  private openSection(section: ProfileSection): void {
    if (forumSession.user === undefined) { this.onLogin(); }
    else { this.onOpenSection(section); }
  }

  private async logout(): Promise<void> {
    try { await forumSession.logout(); this.onLoggedOut(); }
    catch { this.getUIContext().getPromptAction().showToast({ message: '本机登录状态暂时无法清除，请重试。' }); }
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
        Row({ space: 14 }) {
          ForumAvatar({ name: forumSession.user?.username || 'L', url: forumSession.user?.avatarUrl || '', avatarSize: 56 })
          Column({ space: 5 }) {
            Text(forumSession.user?.name || forumSession.user?.username || '欢迎来到 LINUX DO')
              .fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(forumSession.user !== undefined ? `@${forumSession.user.username}` : '登录后参与交流，查看个人消息')
              .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (forumSession.user !== undefined) {
              Text(`信任等级 ${forumSession.user.trustLevel}`).fontSize(12).fontColor($r('app.color.text_secondary'))
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 4, right: 4, top: 4, bottom: 4 })
          .onClick(() => { this.openSection(ProfileSection.Account); }).id('profile_identity')
        if (forumSession.user === undefined) {
          Button('登录 LINUX DO', { type: ButtonType.Capsule }).width('100%').height(50)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).id('login_entry')
            .onClick(() => { this.onLogin(); })
        }
        Row({ space: 10 }) {
          ForEach(this.shortcuts, (menu: ProfileMenuItem) => {
            Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
              Row({ space: 10 }) {
                SymbolGlyph(menu.symbol).fontSize(25).fontColor([$r('app.color.accent')])
                Column({ space: 6 }) {
                  Text(menu.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  Text(menu.subtitle).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }.layoutWeight(1).height(88).padding(14).borderRadius(18).backgroundColor($r('app.color.surface'))
              .systemMaterial(materialFor(this.appearance)).id(`profile_${menu.id}`)
              .onClick(() => { this.openSection(menu.id); })
          }, (menu: ProfileMenuItem): string => menu.id)
        }.width('100%')
        Column({ space: 8 }) {
          Text('我的参与').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ left: 12 })
          Column() {
            ForEach(this.participation, (menu: ProfileMenuItem, index: number) => {
              Row({ space: 12 }) {
                SymbolGlyph(menu.symbol).fontSize(22).fontColor([$r('app.color.text_secondary')])
                Text(menu.title).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
              }.width('100%').padding({ left: 16, right: 16 }).height(56).id(`profile_${menu.id}`)
                .onClick(() => { this.openSection(menu.id); })
              if (index < this.participation.length - 1) {
                Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 })
              }
            }, (menu: ProfileMenuItem): string => menu.id)
          }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: 8 }) {
          Text('账户').fontSize(12).fontColor($r('app.color.text_secondary')).margin({ left: 12 })
          Column() {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.person')).fontSize(22).fontColor([$r('app.color.text_secondary')])
              Text('账号与邮箱').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding({ left: 16, right: 16 }).height(56).id('profile_account')
              .onClick(() => { this.openSection(ProfileSection.Account); })
            Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 })
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([$r('app.color.text_secondary')])
              Text('外观与阅读设置').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding({ left: 16, right: 16 }).height(56)
              .onClick(() => { this.onSettings(); }).id('settings_entry')
            Divider().color($r('app.color.divider')).margin({ left: 50, right: 16 })
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.info_circle')).fontSize(22).fontColor([$r('app.color.text_secondary')])
              Text('关于与连接诊断').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding({ left: 16, right: 16 }).height(56).onClick(() => { this.onDiagnostics(); })
          }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
        }.width('100%').alignItems(HorizontalAlign.Start)
        if (forumSession.user !== undefined) {
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
      .onWillScroll((_x: number, y: number, state: ScrollState, source: ScrollSource): void => {
        this.onReadScroll(y, state, source);
      })
  }
}
