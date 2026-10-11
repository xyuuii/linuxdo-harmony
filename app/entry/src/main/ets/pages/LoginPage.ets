import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';

@ComponentV2
export struct LoginPage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onAuthenticated: () => void = (): void => {};
  @Event onBrowser: () => void = (): void => {};
  @Local emailMode: boolean = false;
  @Local login: string = '';
  @Local password: string = '';
  @Local emailLink: string = '';
  @Local secondFactor: string = '';
  @Local requiresSecondFactor: boolean = false;
  @Local recoveryMode: boolean = false;
  @Local backupEnabled: boolean = false;
  @Local totpEnabled: boolean = true;
  @Local busy: boolean = false;
  @Local emailSent: boolean = false;
  @Local error: string = '';
  private request: RequestCancellation | undefined = undefined;

  private handleError(error: Object): void {
    if (error instanceof ForumApiError) {
      this.error = error.message;
      if (error.kind === ForumErrorKind.SecondFactorRequired) {
        this.requiresSecondFactor = true;
        this.backupEnabled = error.backupEnabled;
        this.totpEnabled = error.totpEnabled;
        if (!error.totpEnabled && error.backupEnabled) { this.recoveryMode = true; }
      }
    } else { this.error = '暂时无法完成登录，请检查网络后重试。'; }
  }

  private tokenFromEmail(): string {
    const value: string = this.emailLink.trim();
    if (/^[a-zA-Z0-9_-]+$/.test(value)) { return value; }
    const match: RegExpMatchArray | null = value.match(/^https:\/\/linux\.do\/session\/email-login\/([a-zA-Z0-9_-]+)(?:[?#].*)?$/);
    if (match === null) { throw new Error('请粘贴 LINUX DO 邮件中的登录链接，或链接里的 token。'); }
    return match[1];
  }

  private async sendEmail(): Promise<void> {
    if (this.busy || !this.login.trim()) { return; }
    this.busy = true; this.error = '';
    const request: RequestCancellation = new RequestCancellation(); this.request = request;
    try {
      await forumApi.sendLoginEmail(this.login.trim(), request);
      this.emailSent = true;
      this.getUIContext().getPromptAction().showToast({ message: '登录邮件已发送，请查收邮件中的登录链接。' });
    } catch (error) { this.handleError(error); }
    finally { this.busy = false; }
  }

  private async submit(): Promise<void> {
    if (this.busy || !this.login.trim()) { return; }
    if (!this.emailMode && !this.password) { this.error = '请输入密码'; return; }
    if (this.requiresSecondFactor && !this.secondFactor.trim()) { this.error = '请输入两步验证码'; return; }
    this.busy = true; this.error = '';
    const request: RequestCancellation = new RequestCancellation(); this.request = request;
    try {
      const factor: string | undefined = this.requiresSecondFactor ? this.secondFactor.trim() : undefined;
      if (this.emailMode) {
        await forumApi.loginWithEmailCode(this.tokenFromEmail(), this.login.trim(), factor, this.recoveryMode ? 2 : 1, request);
      } else {
        await forumApi.loginWithPassword(this.login.trim(), this.password, factor, this.recoveryMode ? 2 : 1, request);
      }
      const confirmed: boolean = await forumSession.refresh();
      if (!confirmed || forumSession.lastError || forumSession.user === undefined) {
        this.error = forumSession.lastError || '请完成网页登录或验证后确认登录状态。';
        return;
      }
      this.password = ''; this.secondFactor = ''; this.emailLink = '';
      this.onAuthenticated();
    } catch (error) {
      if (error instanceof Error && !(error instanceof ForumApiError)) { this.error = error.message; }
      else { this.handleError(error); }
    } finally { this.busy = false; }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 10 }) {
            Text('LINUX DO').fontSize(30).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text('连接彼此，分享可能。').fontSize(16).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 24, bottom: 12 })
          Row({ space: 10 }) {
            Button('账号密码', { type: ButtonType.Capsule }).layoutWeight(1).height(44)
              .backgroundColor(!this.emailMode ? $r('app.color.accent') : $r('app.color.surface'))
              .fontColor(!this.emailMode ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .enabled(!this.busy).onClick(() => { this.emailMode = false; this.error = ''; this.requiresSecondFactor = false; })
            Button('邮件链接', { type: ButtonType.Capsule }).layoutWeight(1).height(44)
              .backgroundColor(this.emailMode ? $r('app.color.accent') : $r('app.color.surface'))
              .fontColor(this.emailMode ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .enabled(!this.busy).onClick(() => { this.emailMode = true; this.error = ''; this.requiresSecondFactor = false; })
          }.width('100%')
          TextInput({ text: this.login, placeholder: this.emailMode ? '账号邮箱' : '用户名或邮箱' })
            .height(54).backgroundColor($r('app.color.surface')).enabled(!this.busy)
            .onChange((value: string) => { this.login = value; }).id('login_username')
          if (!this.emailMode) {
            TextInput({ text: this.password, placeholder: '密码' }).type(InputType.Password)
              .height(54).backgroundColor($r('app.color.surface')).enabled(!this.busy)
              .onChange((value: string) => { this.password = value; }).id('login_password')
          } else {
            Button(this.emailSent ? '重新发送登录邮件' : '发送登录邮件', { type: ButtonType.Capsule })
              .height(48).width('100%').backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent'))
              .enabled(!this.busy && this.login.trim().length > 0).onClick(() => { void this.sendEmail(); })
            TextArea({ text: this.emailLink, placeholder: '粘贴邮件中的登录链接或 token' })
              .height(100).backgroundColor($r('app.color.surface')).enabled(!this.busy)
              .onChange((value: string) => { this.emailLink = value; })
          }
          if (this.requiresSecondFactor) {
            Text(this.recoveryMode ? '输入备用恢复码' : '输入验证器中的动态口令')
              .fontSize(15).fontColor($r('app.color.text_primary')).width('100%')
            TextInput({ text: this.secondFactor, placeholder: this.recoveryMode ? '备用恢复码' : '6 位动态口令' })
              .type(this.recoveryMode ? InputType.Normal : InputType.Number).height(54)
              .backgroundColor($r('app.color.surface')).enabled(!this.busy)
              .onChange((value: string) => { this.secondFactor = value; })
            if (this.backupEnabled && this.totpEnabled) {
              Button(this.recoveryMode ? '改用动态口令' : '使用备用恢复码').fontColor($r('app.color.accent'))
                .backgroundColor(Color.Transparent).enabled(!this.busy)
                .onClick(() => { this.recoveryMode = !this.recoveryMode; this.secondFactor = ''; })
            }
          }
          if (this.error) { Text(this.error).fontSize(14).lineHeight(22).fontColor($r('app.color.error')).width('100%') }
          Button(this.busy ? '正在登录' : '登录', { type: ButtonType.Capsule }).height(52).width('100%')
            .fontSize(16).backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
            .enabled(!this.busy && this.login.trim().length > 0).onClick(() => { void this.submit(); }).id('submit_login')
          Button('在网页中登录或完成验证', { type: ButtonType.Capsule }).height(48).width('100%')
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent')).enabled(!this.busy)
            .onClick(() => { this.onBrowser(); })
          Text('密码和两步验证码仅用于本次登录，应用不会保存。遇到站点验证时，请在可见网页中完成。')
            .fontSize(13).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 24, right: 24, bottom: 40 })
      }.width('100%').height('100%').scrollBar(BarState.Off)
    }.title('登录').padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor($r('app.color.page_background'))
      .onDisAppear(() => { this.request?.cancel(); this.password = ''; this.secondFactor = ''; this.emailLink = ''; })
  }
}
