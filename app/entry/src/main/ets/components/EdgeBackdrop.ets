import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { readerBackdropFor } from '../services/MaterialPolicy';

/** A small status-area surface sampling the scrolling content directly. */
@ComponentV2
export struct EdgeBackdrop {
  @Param heightVp: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param visible: boolean = true;
  @Local cachedEffect: BackgroundEffectOptions | undefined = undefined;

  @Computed
  get edgeHeight(): number {
    return Number.isFinite(this.heightVp) && this.heightVp >= 0 ? this.heightVp : 0;
  }

  aboutToAppear(): void { this.updateEffect(); }

  @Monitor('appearance.effectLevel', 'appearance.highContrast', 'appearance.reduceMotion', 'appearance.themeMode')
  effectChanged(): void { this.updateEffect(); }

  private updateEffect(): void {
    this.cachedEffect = readerBackdropFor(this.appearance);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.appearance.highContrast || this.appearance.effectLevel === 0) {
        Row().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      } else {
        Row().width('100%').height('100%').backgroundColor(Color.Transparent)
          .backgroundEffect(this.cachedEffect)
        Row().width('100%').height('100%')
          .linearGradient({ direction: GradientDirection.Bottom,
            colors: [[$r('app.color.edge_backdrop_tint'), 0], [$r('app.color.edge_backdrop_clear'), 1]] })
      }
    }.width('100%').height(this.edgeHeight).clip(true)
      .visibility(this.visible && this.edgeHeight > 0 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      .id('window_edge_backdrop')
  }
}
