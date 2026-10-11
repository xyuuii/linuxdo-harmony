import { common } from '@kit.AbilityKit';
import { forumSession } from '../models/ForumSession';
import { materialSupported } from '../services/MaterialPolicy';

@ComponentV2
export struct AboutPage {
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
          Text('LINUX DO · 鸿蒙').fontSize(25).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
          Text('为交流而来。').fontSize(16).fontColor($r('app.color.text_secondary')).width('100%')
          Column({ space: 14 }) {
            Text('版本 0.1.1 · 本地开发版本').fontColor($r('app.color.text_primary'))
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
    }.title('关于与诊断').backgroundColor($r('app.color.page_background'))
  }
}
