import { common } from '@kit.AbilityKit';
import { forumSession } from '../models/ForumSession';
import { materialSupported } from '../services/MaterialPolicy';

@ComponentV2
export struct AboutPage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Event onVerify: () => void = (): void => {};
  private openSource(): void {
    const context: common.UIAbilityContext | undefined = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context !== undefined) {
      void context.startAbility({ action: 'ohos.want.action.viewData', uri: 'https://github.com/xuemk/linuxdo-android' })
        .catch(() => { this.getUIContext().getPromptAction().showToast({ message: '暂时无法打开浏览器' }); });
    }
  }
  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 18 }) {
          Row({ space: 12 }) {
            Image($r('app.media.app_icon')).width(64).height(64).objectFit(ImageFit.Contain)
              .borderRadius(16).clip(true).id('app_brand_icon').accessibilityText('LINUX DO 光感图标')
            Column({ space: 6 }) {
              Text('LINUX DO · 鸿蒙').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              Text('为交流而来。').fontSize(14).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Column({ space: 14 }) {
            Text('版本 0.2.7 · 本地开发版本').fontColor($r('app.color.text_primary'))
            Text(`登录状态：${forumSession.user !== undefined ? forumSession.user.username : '未登录'}`)
              .fontSize(14).fontColor($r('app.color.text_secondary'))
            Text(`沉浸材质：${materialSupported() ? '设备支持' : '使用清晰样式'}`)
              .fontSize(14).fontColor($r('app.color.text_secondary'))
            if (forumSession.lastError) {
              Text(forumSession.lastError).fontSize(14).fontColor($r('app.color.text_secondary')).lineHeight(22)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
            .backgroundColor($r('app.color.surface')).borderRadius(24)
          Button('打开网页登录或验证', { type: ButtonType.Capsule }).height(48).width('100%')
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent')).onClick(() => { this.onVerify(); })
          Button('查看参考项目', { type: ButtonType.Capsule }).height(48).width('100%')
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent')).onClick(() => { this.openSource(); })
          Text('行为与接口参考 xuemk/linuxdo-android，界面与平台能力以 ArkTS 和 ArkUI 原生实现。')
            .fontSize(13).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%')
    }.title('关于与诊断').padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor($r('app.color.page_background'))
  }
}
