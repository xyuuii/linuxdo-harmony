import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';

/** Non-interactive status-area blur; feed content continues behind this small overlay. */
@ComponentV2
export struct EdgeBackdrop {
  @Param heightVp: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param visible: boolean = true;

  @Computed
  get edgeHeight(): number {
    return Number.isFinite(this.heightVp) && this.heightVp >= 0 ? this.heightVp : 0;
  }

  @Computed
  get blurRadius(): number {
    if (this.appearance.effectLevel === 0 || this.appearance.highContrast) { return 0; }
    return this.appearance.effectLevel === 1 ? 12 : this.appearance.effectLevel === 2 ? 20 : 28;
  }

  build() {
    Row()
      .width('100%').height(this.edgeHeight)
      .backgroundColor(this.appearance.highContrast ? $r('app.color.page_background') : Color.Transparent)
      .backgroundEffect({ radius: this.blurRadius, saturation: 1.05, color: Color.Transparent })
      .linearGradient(!this.appearance.highContrast ? {
        direction: GradientDirection.Bottom,
        colors: [[$r('app.color.page_background'), 0], [Color.Transparent, 1]]
      } : undefined)
      .visibility(this.visible && this.edgeHeight > 0 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      .id('window_edge_backdrop')
  }
}
