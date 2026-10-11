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
  private menus: ProfileMenuItem[] = [
    { id: ProfileSection.Summary, title: '我的总结', subtitle: '参与、交流与成长', symbol: $r('sys.symbol.list_bullet') },
    { id: ProfileSection.Activity, title: '活动', subtitle: '我的发帖与回复', symbol: $r('sys.symbol.clock') },
    { id: ProfileSection.Notifications, title: '通知', subtitle: '回复、提及与互动', symbol: $r('sys.symbol.bell') },
    { id: ProfileSection.Messages, title: '私信', subtitle: '查看私信话题', symbol: $r('sys.symbol.envelope') },
    { id: ProfileSection.Account, title: '账号与邮箱', subtitle: '查看个人资料', symbol: $r('sys.symbol.person') }
  ];

  private async logout(): Promise<void> {
    try { await forumSession.logout(); this.onLoggedOut(); }
    catch { this.getUIContext().getPromptAction().showToast({ message: '本机登录状态暂时无法清除，请重试。' }); }
  }

  build() {
    Scroll(this.listScroller) {
      Column({ space: 22 }) {
        Text('我的').fontSize(32).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
        Row({ space: 16 }) {
          ForumAvatar({ name: forumSession.user?.username || 'L', url: forumSession.user?.avatarUrl || '', avatarSize: 60 })
          Column({ space: 7 }) {
            Text(forumSession.user?.name || forumSession.user?.username || '欢迎来到 LINUX DO')
              .fontSize(21).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(forumSession.user !== undefined ? `@${forumSession.user.username} · 信任等级 ${forumSession.user.trustLevel}` :
              '登录后参与交流，查看个人消息。').fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(21)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(22).borderRadius(28).backgroundColor($r('app.color.surface'))
        if (forumSession.user === undefined) {
          Button('登录 LINUX DO', { type: ButtonType.Capsule }).width('100%').height(50)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).id('login_entry')
            .onClick(() => { this.onLogin(); })
        }
        Column() {
          ForEach(this.menus, (menu: ProfileMenuItem) => {
            Row({ space: 14 }) {
              SymbolGlyph(menu.symbol).fontSize(23).fontColor([$r('app.color.accent')])
              Column({ space: 5 }) {
                Text(menu.title).fontSize(17).fontColor($r('app.color.text_primary'))
                Text(menu.subtitle).fontSize(12).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.text_secondary')])
            }.width('100%').padding(18).constraintSize({ minHeight: 74 }).id(`profile_${menu.id}`)
              .onClick(() => {
                if (forumSession.user === undefined) { this.onLogin(); }
                else { this.onOpenSection(menu.id); }
              })
          }, (menu: ProfileMenuItem): string => menu.id)
        }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(24)
        Column() {
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(23).fontColor([$r('app.color.accent')])
            Text('外观与阅读设置').fontSize(17).fontColor($r('app.color.text_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.text_secondary')])
          }.width('100%').padding(20).onClick(() => { this.onSettings(); }).id('settings_entry')
          Divider().color($r('app.color.divider')).margin({ left: 20, right: 20 })
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.info_circle')).fontSize(23).fontColor([$r('app.color.accent')])
            Text('关于与连接诊断').fontSize(17).fontColor($r('app.color.text_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.text_secondary')])
          }.width('100%').padding(20).onClick(() => { this.onDiagnostics(); })
        }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(24)
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
        .padding({ left: 20, right: 20, top: 24 + this.topInset, bottom: 112 + this.bottomInset })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .onWillScroll((_x: number, y: number, state: ScrollState, source: ScrollSource): void => {
        this.onReadScroll(y, state, source);
      })
  }
}
