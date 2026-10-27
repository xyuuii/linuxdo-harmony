import { CommonModifier, uiMaterial } from '@kit.ArkUI';

/** A native TabBar presentation host; navigation and gestures remain owned by its content. */
@ComponentV2
export struct MaterialBarHost {
  @Param barHeight: number = 0;
  @BuilderParam barContent: () => void = this.emptyContent;
  private readonly barModifier: CommonModifier = new CommonModifier()
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.NONE)
    .systemMaterial(uiMaterial.Material.empty)
    .hitTestBehavior(HitTestMode.Transparent)
    .accessibilityLevel('no')
    .accessibilityGroup(false);

  @Builder
  emptyContent() {}

  @Builder
  hostedBar() {
    Stack({ alignContent: Alignment.BottomStart }) { this.barContent() }
      .width('100%').height(this.barHeight)
      .hitTestBehavior(HitTestMode.Transparent)
      .accessibilityLevel('no').accessibilityGroup(false)
  }

  build() {
    Tabs({ index: 0, barPosition: BarPosition.End, barModifier: this.barModifier }) {
      TabContent() {
        Row().width('100%').height('100%')
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }.tabBar(this.hostedBar)
        .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no').accessibilityGroup(false)
    }.width('100%').height('100%')
      .barOverlap(true).vertical(false).barMode(BarMode.Fixed)
      .barWidth('100%').barHeight(this.barHeight).scrollable(false).animationDuration(0)
      .barBackgroundColor(Color.Transparent).barBackgroundBlurStyle(BlurStyle.NONE).divider(null)
      .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.Transparent)
      .accessibilityLevel('no').accessibilityGroup(false)
  }
}
