import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { forumApi, RequestCancellation } from '../services/ForumApi';
import {
  CONNECTION_PROBE_URL, CONNECTION_CONTROL_URL, CONNECTION_PROBE_DOH, connectionTraceScript,
  browserTraceSummary, probeNativeConnection
} from '../services/ConnectionProbe';

@ComponentV2
export struct ConnectionProbePage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Local busy: boolean = false;
  @Local webEnabled: boolean = false;
  @Local nativeResult: string = '尚未检测';
  @Local browserResult: string = '尚未检测';
  @Local mode: string = '';
  @Local control: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private cancellation: RequestCancellation | undefined = undefined;
  private timer: number = 0;
  private nativeDone: boolean = false;
  private browserDone: boolean = false;
  private reading: boolean = false;

  private restoreDns(): void {
    try { webview.WebviewController.setHttpDns(webview.SecureDnsMode.OFF, CONNECTION_PROBE_DOH); }
    catch (error) {
      const code: number = (error as BusinessError).code;
      hilog.warn(0x0000, 'LinuxDoConnection', 'DNS reset failed (code %{public}d)', Number.isFinite(code) ? code : -1);
    }
  }

  private stop(): void {
    this.cancellation?.cancel();
    this.cancellation = undefined;
    clearTimeout(this.timer);
    this.webEnabled = false;
    this.busy = false;
    this.restoreDns();
  }

  private complete(): void {
    if (!this.nativeDone || !this.browserDone) { return; }
    clearTimeout(this.timer);
    this.webEnabled = false;
    this.busy = false;
    this.restoreDns();
    hilog.info(0x0000, 'LinuxDoConnection', 'mode=%{public}s native=%{public}s browser=%{public}s',
      this.mode, this.nativeResult, this.browserResult);
  }

  private async start(doh: boolean, control: boolean = false): Promise<void> {
    if (this.busy) { return; }
    this.stop();
    forumApi.cancelSessionRecovery();
    this.control = control;
    this.mode = control ? 'Cloudflare 对照站点 · 加密 DNS' : doh ? '社区 · 加密 DNS（阿里公共 DNS）' : '社区 · 系统 DNS';
    this.busy = true;
    this.nativeResult = '检测中…'; this.browserResult = '检测中…';
    this.nativeDone = false; this.browserDone = false; this.reading = false;
    const token: RequestCancellation = new RequestCancellation();
    this.cancellation = token;
    try {
      webview.WebviewController.setHttpDns(doh ? webview.SecureDnsMode.SECURE_ONLY : webview.SecureDnsMode.OFF,
        CONNECTION_PROBE_DOH);
    } catch (error) {
      const code: number = (error as BusinessError).code;
      hilog.warn(0x0000, 'LinuxDoConnection', 'DNS configuration failed (code %{public}d)', Number.isFinite(code) ? code : -1);
      this.browserResult = '当前设备无法配置检测所需的 DNS';
      this.browserDone = true;
    }
    // A fresh, private Web never receives the normal forum session.
    this.controller = new webview.WebviewController();
    this.webEnabled = !this.browserDone;
    this.timer = setTimeout((): void => {
      if (this.cancellation !== token) { return; }
      this.browserResult = '网页检测超时'; this.browserDone = true;
      this.complete();
    }, 12000);
    let result: string = '连接未完成';
    try { result = await probeNativeConnection(doh, token, control); } catch { /* No unhandled native capability errors. */ }
    if (this.cancellation !== token || token.isCancelled) { return; }
    this.nativeResult = result; this.nativeDone = true;
    this.complete();
  }

  private async pageFinished(): Promise<void> {
    const token: RequestCancellation | undefined = this.cancellation;
    if (!token || token.isCancelled || this.browserDone || this.reading) { return; }
    try {
      if (this.controller.getUrl() !== (this.control ? CONNECTION_CONTROL_URL : CONNECTION_PROBE_URL)) { return; }
    } catch { return; }
    this.reading = true;
    try {
      const raw: string = await this.controller.runJavaScript(connectionTraceScript(this.control));
      if (this.cancellation !== token || token.isCancelled || this.browserDone) { return; }
      this.browserResult = browserTraceSummary(raw, this.control);
    } catch {
      if (this.cancellation !== token || token.isCancelled || this.browserDone) { return; }
      this.browserResult = '未取得网页握手回执';
    }
    this.browserDone = true;
    this.complete();
  }

  build() {
    NavDestination() {
      Column({ space: 18 }) {
        Text('检测当前设备访问社区时，服务端是否确认目标域名已加密。')
          .fontSize(16).fontColor($r('app.color.text_primary')).lineHeight(24)
        Text('只读取连接信息，不发送论坛账号凭据。检测结束或退出页面后恢复应用原有 DNS 设置。结果仅代表当前网络，不能证明其他地区免代理可用。')
          .fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(22)
        Button('检测系统连接').width('100%').height(48).enabled(!this.busy)
          .onClick(() => { void this.start(false); }).id('connection_probe_system')
        Button('检测加密 DNS 连接').width('100%').height(48).enabled(!this.busy)
          .onClick(() => { void this.start(true); }).id('connection_probe_doh')
        Button('检测内核加密能力（对照站点）').width('100%').height(48).enabled(!this.busy)
          .onClick(() => { void this.start(true, true); }).id('connection_probe_control')
        Text(this.mode).fontSize(15).fontColor($r('app.color.text_primary'))
        Text(`原生请求：${this.nativeResult}`).fontSize(15).lineHeight(24)
          .fontColor($r('app.color.text_primary')).id('connection_probe_native')
        Text(`网页内核：${this.browserResult}`).fontSize(15).lineHeight(24)
          .fontColor($r('app.color.text_primary')).id('connection_probe_browser')
        Text('“本次连接未加密”也可能与系统能力、连接复用、DNS 或网络环境有关。检测不会自动开启免代理模式。')
          .fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(22)
        if (this.webEnabled) {
          Web({ src: this.control ? CONNECTION_CONTROL_URL : CONNECTION_PROBE_URL, controller: this.controller, incognitoMode: true })
            .width(1).height(1).visibility(Visibility.Hidden)
            .javaScriptAccess(true).fileAccess(false).domStorageAccess(false).mixedMode(MixedMode.None)
            .onPageEnd(() => { void this.pageFinished(); })
            .onLoadIntercept((event: OnLoadInterceptEvent) => {
              return event.data.isMainFrame() && event.data.getRequestUrl() !== (this.control ? CONNECTION_CONTROL_URL : CONNECTION_PROBE_URL);
            })
        }
      }.width('100%').height('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.title('连接能力检测').padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor($r('app.color.page_background'))
      .onHidden(() => { this.stop(); })
      .onDisAppear(() => { this.stop(); })
  }
}
