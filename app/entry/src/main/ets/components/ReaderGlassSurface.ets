import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';

/** Read-only backing. Disabled controls and reduced motion retain a legible, visible surface. */
@ComponentV2
export struct ReaderGlassSurface {
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param radiusVp: number = 26;

  @Computed
  get usesGlass(): boolean { return this.appearance.effectLevel > 0 && !this.appearance.highContrast; }

  @Computed
  get blurRadius(): number {
    if (!this.usesGlass) { return 0; }
    return this.appearance.effectLevel === 1 ? 16 : this.appearance.effectLevel === 2 ? 24 : 32;
  }

  build() {
    Stack() {
      Row().width('100%').height('100%').borderRadius(this.radiusVp)
        .backgroundColor(this.usesGlass ? Color.Transparent : $r('app.color.surface'))
        .backgroundEffect({ radius: this.blurRadius, saturation: 1.05,
          color: this.usesGlass ? $r('app.color.reading_glass_tint') : Color.Transparent })
      Row().width('100%').height('100%').borderRadius(this.radiusVp)
        .linearGradient(this.usesGlass ? { direction: GradientDirection.Bottom,
          colors: [[$r('app.color.reading_glass_highlight'), 0], [Color.Transparent, 0.5], [Color.Transparent, 1]] } : undefined)
        .border({ width: this.appearance.highContrast ? 1 : this.usesGlass ? 0.7 : 0,
          color: this.appearance.highContrast ? $r('app.color.text_primary') : $r('app.color.reading_glass_rim') })
    }.width('100%').height('100%').borderRadius(this.radiusVp)
      .shadow({ radius: this.usesGlass ? this.appearance.effectLevel === 1 ? 6 : 12 : 0,
        offsetY: this.usesGlass ? 3 : 0, color: this.usesGlass ? $r('app.color.reading_glass_shadow') : Color.Transparent })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
