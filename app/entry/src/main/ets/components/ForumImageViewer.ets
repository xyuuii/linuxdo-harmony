import { NativeForumImage } from './NativeForumImage';
import { forumSession } from '../models/ForumSession';
import { constrainViewerOffset, viewerIndex, viewerScale, ViewerOffset, ViewerSize,
  zoomViewerOffset } from '../services/ImageViewerGeometry';

/** A full-screen layer over the reader; its parent consumes Back and retains the reading position. */
@ComponentV2
export struct ForumImageViewer {
  @Param urls: string[] = [];
  @Param initialIndex: number = 0;
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param ownerId: number = forumSession.user?.id || 0;
  @Param aspectRatios: number[] = [];
  @Param saving: boolean = false;
  @Event onClose: () => void = (): void => {};
  @Event onSave: (url: string) => void = (_url: string): void => {};
  @Event onIndexChange: (index: number) => void = (_index: number): void => {};
  @Local currentIndex: number = 0;
  @Local scaleValue: number = 1;
  @Local offsetX: number = 0;
  @Local offsetY: number = 0;
  @Local controlsVisible: boolean = true;
  @Local pinching: boolean = false;
  @Local viewportWidth: number = 0;
  @Local viewportHeight: number = 0;
  @Local imageSizes: ViewerSize[] = [];
  private swiper: SwiperController = new SwiperController();
  private pinchScale: number = 1;
  private pinchOffset: ViewerOffset = { x: 0, y: 0 };
  private pinchFocus: ViewerOffset = { x: 0, y: 0 };
  private panOffset: ViewerOffset = { x: 0, y: 0 };

  aboutToAppear(): void { this.currentIndex = viewerIndex(this.initialIndex, this.urls.length); }

  @Monitor('urls', 'initialIndex')
  sourceChanged(): void {
    this.currentIndex = viewerIndex(this.initialIndex, this.urls.length);
    this.imageSizes = [];
    this.resetTransform();
    this.swiper.changeIndex(this.currentIndex, false);
  }

  private viewport(): ViewerSize { return { width: this.viewportWidth, height: this.viewportHeight }; }
  private imageSize(): ViewerSize {
    const natural: ViewerSize | undefined = this.imageSizes[this.currentIndex];
    if (natural && natural.width > 0 && natural.height > 0) { return natural; }
    const ratio: number = this.aspectRatios[this.currentIndex] || 0;
    return ratio > 0 ? { width: ratio, height: 1 } : this.viewport();
  }
  private setOffset(offset: ViewerOffset): void { this.offsetX = offset.x; this.offsetY = offset.y; }
  private constrainOffset(): void {
    this.setOffset(constrainViewerOffset(this.viewport(), this.imageSize(), this.scaleValue,
      { x: this.offsetX, y: this.offsetY }));
  }
  private resetTransform(): void {
    this.scaleValue = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.pinching = false;
  }
  private naturalSize(index: number, width: number, height: number): void {
    if (width <= 0 || height <= 0) { return; }
    const sizes: ViewerSize[] = this.imageSizes.slice();
    sizes[index] = { width: width, height: height };
    this.imageSizes = sizes;
    if (index === this.currentIndex) { this.constrainOffset(); }
  }
  private doubleTap(event: GestureEvent): void {
    if (this.scaleValue > 1.01) { this.resetTransform(); return; }
    const finger: FingerInfo | undefined = event.fingerList[0];
    const focus: ViewerOffset = { x: finger?.localX ?? this.viewportWidth / 2,
      y: finger?.localY ?? this.viewportHeight / 2 };
    this.setOffset(zoomViewerOffset(this.viewport(), this.imageSize(), 1, 2.5,
      { x: 0, y: 0 }, focus, focus));
    this.scaleValue = 2.5;
  }
  private pinchStart(event: GestureEvent): void {
    this.pinching = true;
    this.pinchScale = this.scaleValue;
    this.pinchOffset = { x: this.offsetX, y: this.offsetY };
    this.pinchFocus = { x: event.pinchCenterX, y: event.pinchCenterY };
  }
  private pinchUpdate(event: GestureEvent): void {
    const nextScale: number = viewerScale(this.pinchScale * event.scale);
    this.setOffset(zoomViewerOffset(this.viewport(), this.imageSize(), this.pinchScale, nextScale,
      this.pinchOffset, this.pinchFocus, { x: event.pinchCenterX, y: event.pinchCenterY }));
    this.scaleValue = nextScale;
  }
  private pinchEnd(): void { this.pinching = false; this.constrainOffset(); }
  private panUpdate(event: GestureEvent): void {
    if (this.scaleValue <= 1.01 || this.pinching) { return; }
    this.setOffset(constrainViewerOffset(this.viewport(), this.imageSize(), this.scaleValue,
      { x: this.panOffset.x + event.offsetX, y: this.panOffset.y + event.offsetY }));
  }
  private choose(index: number): void {
    this.currentIndex = viewerIndex(index, this.urls.length);
    this.resetTransform();
    this.onIndexChange(this.currentIndex);
  }

  @Builder
  private picture(url: string, index: number) {
    Stack() {
      NativeForumImage({ url: url, fit: ImageFit.Contain, ownerId: this.ownerId,
        accessibleLabel: `帖子图片 ${index + 1}`, previewImageAspectRatio: 0,
        onNaturalSize: (width: number, height: number): void => { this.naturalSize(index, width, height); } })
        .width('100%').height('100%')
        .scale({ x: index === this.currentIndex ? this.scaleValue : 1,
          y: index === this.currentIndex ? this.scaleValue : 1 })
        .translate({ x: index === this.currentIndex ? this.offsetX : 0,
          y: index === this.currentIndex ? this.offsetY : 0 })
    }.width('100%').height('100%').clip(true)
      .id(`viewer_image_${index}`)
      .gesture(GestureGroup(GestureMode.Exclusive,
        PinchGesture({ fingers: 2, distance: 5, isFingerCountLimited: true })
          .onActionStart((event: GestureEvent): void => { this.pinchStart(event); })
          .onActionUpdate((event: GestureEvent): void => { this.pinchUpdate(event); })
          .onActionEnd((): void => { this.pinchEnd(); })
          .onActionCancel((): void => { this.pinchEnd(); }),
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 5, isFingerCountLimited: true }).tag('viewer_pan')
          .onActionStart((): void => { this.panOffset = { x: this.offsetX, y: this.offsetY }; })
          .onActionUpdate((event: GestureEvent): void => { this.panUpdate(event); })
          .onActionEnd((): void => { this.constrainOffset(); })
          .onActionCancel((): void => { this.constrainOffset(); }),
        TapGesture({ count: 2, fingers: 1, distanceThreshold: 8, isFingerCountLimited: true })
          .onAction((event: GestureEvent): void => { this.doubleTap(event); }),
        TapGesture({ count: 1, fingers: 1, distanceThreshold: 8, isFingerCountLimited: true })
          .onAction((): void => { this.controlsVisible = !this.controlsVisible; })
      ))
      .onGestureJudgeBegin((info: GestureInfo): GestureJudgeResult => {
        return info.tag === 'viewer_pan' && this.scaleValue <= 1.01 ?
          GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE;
      })
  }

  @Builder
  private controls() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor(['#FFFFFF'])
        }.width(48).height(48).id('viewer_close').accessibilityText('返回帖子')
          .onClick(this.onClose)
        Text(`${this.currentIndex + 1} / ${this.urls.length}`).fontSize(16).fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium).layoutWeight(1).textAlign(TextAlign.Center)
          .id('viewer_page_count').accessibilityText(`第 ${this.currentIndex + 1} 张，共 ${this.urls.length} 张`)
        Blank().width(48).hitTestBehavior(HitTestMode.None)
      }.width('100%').padding({ left: 8, right: 8, top: 8 + this.topInset, bottom: 4 }).backgroundColor('#66000000')
      Blank().hitTestBehavior(HitTestMode.None)
      Row({ space: 12 }) {
        if (this.urls.length > 1) {
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor(['#FFFFFF'])
          }.width(44).height(44).id('viewer_previous').enabled(this.currentIndex > 0)
            .accessibilityText('上一张').onClick((): void => { this.swiper.changeIndex(this.currentIndex - 1, true); })
        }
        Blank().hitTestBehavior(HitTestMode.None)
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
          .height(44).fontSize(14).iconColor('#FFFFFF').fontColor('#FFFFFF').backgroundColor('#333333')
          .enabled(!this.saving && this.urls.length > 0).id('viewer_save')
          .onClick((_event: ClickEvent, result: SaveButtonOnClickResult): void => {
            const url: string = this.urls[this.currentIndex] || '';
            if (result === SaveButtonOnClickResult.SUCCESS && url) { this.onSave(url); }
          })
        Blank().hitTestBehavior(HitTestMode.None)
        if (this.urls.length > 1) {
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor(['#FFFFFF'])
          }.width(44).height(44).id('viewer_next').enabled(this.currentIndex < this.urls.length - 1)
            .accessibilityText('下一张').onClick((): void => { this.swiper.changeIndex(this.currentIndex + 1, true); })
        }
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 + this.bottomInset }).backgroundColor('#66000000')
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack() {
      Swiper(this.swiper) {
        ForEach(this.urls, (url: string, index: number) => { this.picture(url, index) },
          (url: string): string => url)
      }.width('100%').height('100%').index(this.currentIndex).loop(false).indicator(false).autoPlay(false)
        .cachedCount(1).disableSwipe(this.scaleValue > 1.01 || this.pinching)
        .onChange((index: number): void => { this.choose(index); })
      if (this.controlsVisible) { this.controls() }
    }.width('100%').height('100%').backgroundColor('#000000').clip(true)
      .id('forum_image_viewer')
      .onSizeChange((_old: SizeOptions, next: SizeOptions): void => {
        this.viewportWidth = Number(next.width) || 0;
        this.viewportHeight = Number(next.height) || 0;
        this.constrainOffset();
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
