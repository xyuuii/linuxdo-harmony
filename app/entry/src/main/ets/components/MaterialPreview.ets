import { AppearanceSettings } from '../models/AppearanceSettings';
import { effectPresets, materialFor, materialSupported } from '../services/MaterialPolicy';

@ComponentV2
export struct MaterialPreview {
  @Param appearance: AppearanceSettings = new AppearanceSettings();
  @Local warmScene: boolean = false;
  @Local touchCount: number = 0;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.warmScene ? $r('app.media.scene_warm') : $r('app.media.scene_mint'))
        .width('100%').height('100%').objectFit(ImageFit.Cover).accessibilityLevel('no')
      Column({ space: 18 }) {
        Text(this.warmScene ? '晚霞' : '晨光').fontSize(13).letterSpacing(4).fontColor('#344C44')
        Text('光随心动').fontSize(31).fontWeight(FontWeight.Medium).fontColor('#173A2E')
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.sun_max')).fontSize(21).fontColor([$r('app.color.text_primary')])
            Text(this.touchCount > 0 ? `已轻触 ${this.touchCount} 次` : '轻触，感受光')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          }
        }.height(56).width(214).backgroundColor($r('app.color.surface')).id('material_preview_button')
          .onClick(() => { this.touchCount++; }).systemMaterial(materialFor(this.appearance))
        Text(this.appearance.highContrast ? '高对比度 · 清晰样式' : materialSupported() ?
          `当前效果 · ${effectPresets[this.appearance.effectLevel].label}${this.appearance.reduceMotion ? ' · 减少动态' : ''}` :
          '当前设备使用清晰样式')
          .fontSize(12).fontColor('#344C44').id('current_effect_label')
      }
      Row() {
        Blank()
        Button(this.warmScene ? '切换为晨光' : '切换为晚霞', { type: ButtonType.Capsule })
          .height(40).fontSize(12).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.surface'))
          .id('switch_scene').onClick(() => { this.warmScene = !this.warmScene; })
          .systemMaterial(materialFor(this.appearance))
      }.width('100%').padding({ left: 14, right: 14 }).position({ x: 0, y: 14 })
    }.width('100%').height(292).borderRadius(32).clip(true)
  }
}
