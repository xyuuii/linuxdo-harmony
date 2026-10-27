import { uiMaterial } from '@kit.ArkUI';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { TouchLightState } from '../services/TouchLightState';
import { readerMaterialFor, readerBackdropFor } from '../services/MaterialPolicy';

/** A visible glass surface and one touch light; child buttons must use Material.empty. */
@ComponentV2
export struct ReaderGlassSurface {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param radiusVp: number = 26;
  @Param lightId: string = 'reading_touch_light';
  // Ordinary overlays cannot render systemMaterial; only opt in inside a supported native bar.
  @Param nativeBar: boolean = false;
  @BuilderParam content: () => void = this.emptyContent;
  @Local touchLight: TouchLightState = new TouchLightState();
  @Local nativeMaterial: uiMaterial.Material = uiMaterial.Material.empty;
  @Local nativeRequested: boolean = false;
  @Local fallbackEffect: BackgroundEffectOptions | undefined = undefined;

  @Computed
  get usesGlass(): boolean { return this.appearance.effectLevel > 0 && !this.appearance.highContrast; }

  @Computed
  get touchLightEnabled(): boolean { return this.usesGlass && !this.nativeRequested && this.appearance.effectLevel >= 2; }

  aboutToAppear(): void { this.updateSurface(); }
  aboutToDisappear(): void { this.touchLight.clear(); }

  @Monitor('nativeBar', 'appearance.effectLevel', 'appearance.highContrast', 'appearance.reduceMotion', 'appearance.themeMode')
  effectChanged(): void { this.updateSurface(); }

  private updateSurface(): void {
    const material: uiMaterial.ImmersiveMaterial | undefined = this.nativeBar ? readerMaterialFor(this.appearance) : undefined;
    this.nativeMaterial = material || uiMaterial.Material.empty;
    this.nativeRequested = material !== undefined;
    this.fallbackEffect = readerBackdropFor(this.appearance);
    if (!this.touchLightEnabled) { this.touchLight.clear(); }
  }

  @Builder
  emptyContent() {}

  @Builder
  glassSurface() {
    Stack() {
      Row().width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp)
        .backgroundEffect(this.fallbackEffect)
      // Tint is a normal paint layer, so unavailable filters cannot erase the visible surface.
      Row().width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp)
        .backgroundColor($r('app.color.reading_glass_tint'))
    }.width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp)
      .border({ width: 0.6, color: $r('app.color.reading_glass_rim') })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }

  build() {
    Stack() {
      if (this.usesGlass && !this.nativeRequested) {
        this.glassSurface()
      }
      if (this.usesGlass && !this.nativeRequested) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row().width(112).height(112).borderRadius(56)
            .radialGradient({ center: ['50%', '50%'], radius: 56,
              colors: [[$r('app.color.touch_light_core'), 0], [$r('app.color.touch_light_halo'), 0.38],
                [$r('app.color.touch_light_fade'), 1]] })
            .position({ x: this.touchLight.x - 56, y: this.touchLight.y - 56 })
            .visibility(this.touchLightEnabled && this.touchLight.active ? Visibility.Visible : Visibility.Hidden)
            .id(this.lightId)
        }.width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp).clip(true)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }
      Stack() { this.content() }
        .width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp)
        .backgroundColor(Color.Transparent)
        // Native material samples the page directly; the compatibility backing is mutually exclusive.
        .systemMaterial(this.nativeMaterial)
    }.width('100%').height(this.radiusVp * 2).borderRadius(this.radiusVp)
      // Only the small capsule blocks lower layers; its child controls still receive touches.
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .backgroundColor(this.usesGlass ? Color.Transparent : $r('app.color.surface'))
      .border(this.appearance.highContrast ? { width: 1, color: $r('app.color.text_primary') } : undefined)
      .onAreaChange((_old: Area, next: Area): void => {
        this.touchLight.setArea(Number(next.width), Number(next.height),
          Number(next.globalPosition.x), Number(next.globalPosition.y));
      })
      .onTouch((event: TouchEvent): void => {
        if (!this.nativeRequested) { this.touchLight.update(event, this.touchLightEnabled); }
      })
  }
}
