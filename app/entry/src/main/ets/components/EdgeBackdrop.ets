import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';

/** A small, alpha-masked status-area surface; scrolling colours remain visible behind it. */
@ComponentV2
export struct EdgeBackdrop {
  @Param heightVp: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param visible: boolean = true;
  @Local cachedEffect: BackgroundEffectOptions | undefined = undefined;
  @Local tintOpacity: number = 0.36;

  @Computed
  get edgeHeight(): number {
    return Number.isFinite(this.heightVp) && this.heightVp >= 0 ? this.heightVp : 0;
  }

  aboutToAppear(): void { this.updateEffect(); }

  @Monitor('appearance.effectLevel', 'appearance.highContrast', 'appearance.reduceMotion', 'appearance.themeMode')
  effectChanged(): void { this.updateEffect(); }

  private updateEffect(): void {
    this.cachedEffect = undefined;
    this.tintOpacity = 0.42;
    if (this.appearance.effectLevel < 1 || this.appearance.effectLevel > 3 || this.appearance.highContrast) { return; }
    const radius: number = this.appearance.effectLevel === 1 ? 3 : this.appearance.effectLevel === 2 ? 5 : 7;
    this.cachedEffect = { radius: radius, saturation: 1, brightness: 1, color: Color.Transparent };
    this.tintOpacity = 0.3;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.appearance.highContrast) {
        Row().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          Row().width('100%').height('100%').backgroundColor(Color.Transparent)
            .backgroundEffect(this.cachedEffect)
          Row().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
            .opacity(this.tintOpacity)
          // Mask only this local surface, never the list or system clock above the application.
          Row().width('100%').height('100%')
            .linearGradient({ direction: GradientDirection.Bottom,
              colors: [['#FFFFFFFF', 0], ['#FFFFFFFF', 0.38], ['#80FFFFFF', 0.7], ['#00FFFFFF', 1]] })
            .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
        }.width('100%').height('100%')
          .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
      }
    }.width('100%').height(this.edgeHeight).clip(true)
      .visibility(this.visible && this.edgeHeight > 0 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      .id('window_edge_backdrop')
  }
}
