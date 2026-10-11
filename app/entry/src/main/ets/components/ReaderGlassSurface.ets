import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { materialFor, materialSupported } from '../services/MaterialPolicy';
import { TouchLightState } from '../services/TouchLightState';

/** One material on the control container; child buttons must use Material.empty. */
@ComponentV2
export struct ReaderGlassSurface {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param radiusVp: number = 26;
  @Param lightId: string = 'reading_touch_light';
  @BuilderParam content: () => void = this.emptyContent;
  @Local touchLight: TouchLightState = new TouchLightState();
  @Local cachedMaterial: uiMaterial.Material = uiMaterial.Material.empty;
  // API26's emulator advertises support but does not render the optical surface.
  private nativeAvailable: boolean = deviceInfo.productModel !== 'emulator' && materialSupported();

  @Computed
  get usesGlass(): boolean { return this.appearance.effectLevel > 0 && !this.appearance.highContrast; }

  @Computed
  get usesFallback(): boolean { return this.usesGlass && !this.nativeAvailable; }

  @Computed
  get touchLightEnabled(): boolean { return this.usesFallback && this.appearance.effectLevel >= 2; }

  aboutToAppear(): void { this.updateMaterial(); }
  aboutToDisappear(): void { this.touchLight.clear(); }

  @Monitor('appearance.effectLevel', 'appearance.highContrast', 'appearance.reduceMotion', 'appearance.themeMode')
  effectChanged(): void {
    this.updateMaterial();
    if (!this.touchLightEnabled) { this.touchLight.clear(); }
  }

  private updateMaterial(): void {
    this.cachedMaterial = this.usesGlass && this.nativeAvailable ? materialFor(this.appearance) : uiMaterial.Material.empty;
  }

  @Builder
  emptyContent() {}

  @Builder
  fallbackSurface() {
    Row().width('100%').height('100%').borderRadius(this.radiusVp)
      .backgroundEffect({
        radius: this.appearance.effectLevel === 1 ? 16 : this.appearance.effectLevel === 2 ? 24 : 32,
        saturation: 1.05, color: $r('app.color.reading_glass_tint') })
      .border({ width: 0.6, color: $r('app.color.reading_glass_rim') })
      .shadow(this.appearance.effectLevel > 1 ? {
        radius: 6, offsetY: 2, fill: false, color: $r('app.color.reading_glass_shadow') } : undefined)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }

  build() {
    Stack() {
      if (this.usesFallback) {
        this.fallbackSurface()
        Stack({ alignContent: Alignment.TopStart }) {
          Row().width(112).height(112).borderRadius(56)
            .radialGradient({ center: ['50%', '50%'], radius: 56,
              colors: [[$r('app.color.touch_light_core'), 0], [$r('app.color.touch_light_halo'), 0.38],
                [$r('app.color.touch_light_fade'), 1]] })
            .position({ x: this.touchLight.x - 56, y: this.touchLight.y - 56 })
            .visibility(this.touchLightEnabled && this.touchLight.active ? Visibility.Visible : Visibility.Hidden)
            .id(this.lightId)
        }.width('100%').height('100%').borderRadius(this.radiusVp).clip(true)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }
      this.content()
    }.width('100%').height('100%').borderRadius(this.radiusVp)
      // Only the small capsule blocks lower layers; its child controls still receive touches.
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .backgroundColor(this.usesGlass ? Color.Transparent : $r('app.color.surface'))
      .border(this.appearance.highContrast ? { width: 1, color: $r('app.color.text_primary') } : undefined)
      .systemMaterial(this.cachedMaterial)
      .onAreaChange((_old: Area, next: Area): void => {
        this.touchLight.setArea(Number(next.width), Number(next.height),
          Number(next.globalPosition.x), Number(next.globalPosition.y));
      })
      .onTouch((event: TouchEvent): void => { this.touchLight.update(event, this.touchLightEnabled); })
  }
}
