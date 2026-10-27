import nativeProbe from 'libechprobe.so';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';

interface NativeRequest {
  host: string;
  provider: string;
  mode: string;
  path: string;
  seed_json?: string;
  user_agent: string;
}

@ComponentV2
export struct NativeEchProbePage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onWebCheck: () => void = (): void => {};
  @Local busy: boolean = false;
  @Local result: string = '尚未检测';
  private generation: number = 0;

  private stop(): void {
    this.generation++;
    nativeProbe.cancel();
    this.busy = false;
  }

  private async run(provider: string, path: string = 'trace'): Promise<void> {
    if (this.busy) { return; }
    const generation: number = ++this.generation;
    this.busy = true;
    this.result = '原生探针运行中，单条连接最多等待约14秒…';
    const request: NativeRequest = { host: 'linux.do', provider: provider, mode: path === 'latest' ? 'ech' : 'both', path: path,
      user_agent: webview.WebviewController.getDefaultUserAgent() };
    try {
      if (provider === 'seed') {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const data: Uint8Array = await context.resourceManager.getRawFileContent('ech-seed-linuxdo.json');
        let seed: string = '';
        for (let i: number = 0; i < data.length; i++) { seed += String.fromCharCode(data[i]); }
        request.seed_json = seed;
      }
      if (generation !== this.generation) { return; }
      const result: string = await nativeProbe.run(JSON.stringify(request));
      if (generation !== this.generation) { return; }
      this.result = result;
      hilog.info(0x0000, 'LinuxDoNativeECH', 'provider=%{public}s path=%{public}s result=%{public}s', provider, path, result);
    } catch {
      if (generation === this.generation) { this.result = '原生探针未完成，请检查构建或配置有效期。'; }
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 14 }) {
          Text('Rustls ECH 原型').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text('独立原生网络探针，保留证书校验，不发送账号 Cookie。普通 TLS 与强制 ECH 使用同一目标 IP。短期配置对照依赖电脑提供的公开 DNS 数据，仅用于隔离握手问题。')
            .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary'))
          Button('手机 DoH + ECH').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('cloudflare'); }).id('native_ech_doh')
          Button('阿里 DoH 对照').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('aliyun'); }).id('native_ech_aliyun')
          Button('社区 DoH + ECH（kudo）').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('kudo'); }).id('native_ech_kudo')
          Button('社区优选 DoH + ECH（edge）').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('edge'); }).id('native_ech_edge')
          Button('社区 DoH：读取公开话题列表').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('kudo', 'latest'); }).id('native_ech_kudo_latest')
          Button('网页内核 ECH 对照').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { this.onWebCheck(); }).id('native_ech_web')
          Button('恢复系统 DNS').width('100%').height(48).enabled(!this.busy)
            .onClick(() => {
              webview.WebviewController.setHttpDns(webview.SecureDnsMode.OFF, 'https://kudo.ddd.oaifree.com/query-dns');
              this.result = '已撤销本进程的试验 DNS 配置';
            }).id('native_ech_reset_dns')
          Button('短期配置：普通 TLS / ECH 对照').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('seed'); }).id('native_ech_seed')
          Button('短期配置：读取公开话题列表').width('100%').height(48).enabled(!this.busy)
            .onClick(() => { void this.run('seed', 'latest'); }).id('native_ech_latest')
          Text(this.result).fontSize(12).lineHeight(18).fontColor($r('app.color.text_primary'))
            .width('100%').id('native_ech_result')
        }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%')
    }.title('原生 ECH 验证').padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor($r('app.color.page_background'))
      .onHidden(() => { this.stop(); }).onDisAppear(() => { this.stop(); })
  }
}
