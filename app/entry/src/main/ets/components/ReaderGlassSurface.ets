import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { materialFor, materialSupported } from '../services/MaterialPolicy';

/** One material on the control container; child buttons must use Material.empty. */
@ComponentV2
export struct ReaderGlassSurface {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param radiusVp: number = 26;
  @BuilderParam content: () => void = this.emptyContent;
  // API26's emulator advertises support but does not render the optical surface.
  private nativeAvailable: boolean = deviceInfo.productModel !== 'emulator' && materialSupported();

  @Computed
  get usesGlass(): boolean { return this.appearance.effectLevel > 0 && !this.appearance.highContrast; }

  @Computed
  get usesFallback(): boolean { return this.usesGlass && !this.nativeAvailable; }

  @Builder
  emptyContent() {}

  build() {
    Stack() {
      this.content()
    }.width('100%').height('100%').borderRadius(this.radiusVp)
      .backgroundColor(this.usesGlass ? Color.Transparent : $r('app.color.surface'))
      .backgroundEffect(this.usesFallback ? {
        radius: this.appearance.effectLevel === 1 ? 16 : this.appearance.effectLevel === 2 ? 24 : 32,
        saturation: 1.05, color: $r('app.color.reading_glass_tint') } : undefined)
      .border(this.appearance.highContrast ? { width: 1, color: $r('app.color.text_primary') } :
        this.usesFallback ? { width: 0.6, color: $r('app.color.reading_glass_rim') } : undefined)
      .shadow(this.usesFallback && this.appearance.effectLevel > 1 ? {
        radius: 6, offsetY: 2, fill: false, color: $r('app.color.reading_glass_shadow') } : undefined)
      .systemMaterial(this.usesGlass && this.nativeAvailable ? materialFor(this.appearance) : uiMaterial.Material.empty)
  }
}
