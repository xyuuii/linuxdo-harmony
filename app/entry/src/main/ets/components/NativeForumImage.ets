import { common } from '@kit.AbilityKit';
import { AnimatedDrawableDescriptor, DrawableDescriptorLoadedResult } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { fileUri } from '@kit.CoreFileKit';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation, ForumApiError, ForumErrorKind } from '../services/ForumApi';
import { loadForumMedia, invalidateForumMedia } from '../services/ForumMedia';

interface LoadedImageIdentity {
  uri: string;
  source: string;
  ownerId: number;
  generation: number;
  revision: number;
}

@ComponentV2
export struct NativeForumImage {
  @Param url: string = '';
  @Param fit: ImageFit = ImageFit.Cover;
  @Param ownerId: number = forumSession.user?.id || 0;
  @Param accessibleLabel: string = '图片';
  @Param previewImageAspectRatio: number = 1;
  @Event onNaturalSize: (width: number, height: number) => void = (_width: number, _height: number): void => {};
  @Local sessionRef: ForumSession = forumSession;
  @Local cachedUri: string = '';
  @Local animatedSource: AnimatedDrawableDescriptor | undefined = undefined;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  private request: RequestCancellation | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private loadTimer: number = -1;
  private live: boolean = false;
  private imageGeneration: number = -1;
  private imageRevision: number = -1;
  private resetHandler: () => void = (): void => this.clearImage();

  aboutToAppear(): void {
    this.live = true;
    forumApi.onSessionReset(this.resetHandler);
    this.scheduleLoad();
  }
  aboutToDisappear(): void {
    this.live = false;
    forumApi.offSessionReset(this.resetHandler);
    this.clearImage();
  }
  @Monitor('url', 'ownerId', 'sessionRef.revision')
  imageSourceChanged(): void { this.scheduleLoad(); }

  private clearImage(): void {
    if (this.loadTimer >= 0) { clearTimeout(this.loadTimer); this.loadTimer = -1; }
    this.request?.cancel();
    this.request = undefined;
    this.cachedUri = '';
    this.animatedSource = undefined;
    this.imageGeneration = -1;
    this.imageRevision = -1;
    this.loading = false;
    this.failed = false;
  }
  private scheduleLoad(): void {
    this.clearImage();
    if (!this.live || !this.url) { return; }
    this.loadTimer = setTimeout((): void => { this.loadTimer = -1; void this.loadImage(); }, 0);
  }
  private async loadImage(): Promise<void> {
    if (!this.live || !this.url || this.ownerId !== (this.sessionRef.user?.id || 0)) { return; }
    const context: common.UIAbilityContext | undefined = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) { this.failed = true; return; }
    this.context = context;
    const cancellation: RequestCancellation = new RequestCancellation();
    this.request = cancellation;
    this.loading = true;
    const owner: number = this.ownerId;
    const generation: number = forumApi.getSessionGeneration();
    const url: string = this.url;
    try {
      const uri: string = await loadForumMedia(url, context, cancellation);
      const animation: AnimatedDrawableDescriptor | undefined = await this.animationSource(uri, url, cancellation);
      const dimensions: DrawableDescriptorLoadedResult | undefined = animation ? await animation.load() : undefined;
      if (this.live && !cancellation.isCancelled && this.request === cancellation && this.url === url && this.ownerId === owner &&
        (this.sessionRef.user?.id || 0) === owner && forumApi.getSessionGeneration() === generation) {
        this.imageGeneration = generation;
        this.imageRevision = this.sessionRef.revision;
        this.animatedSource = animation;
        this.cachedUri = uri;
        if (dimensions) {
          this.naturalSize(dimensions.imageWidth, dimensions.imageHeight,
            { uri, source: url, ownerId: owner, generation, revision: this.imageRevision });
        }
      }
    } catch (error) {
      if (this.live && this.request === cancellation) {
        this.failed = !(error instanceof ForumApiError && error.kind === ForumErrorKind.Cancelled);
      }
    } finally { if (this.request === cancellation) { this.loading = false; } }
  }
  private async animationSource(uri: string, url: string,
    cancellation: RequestCancellation): Promise<AnimatedDrawableDescriptor | undefined> {
    if (cancellation.isCancelled || !/\.(gif|webp)(?:[?#]|$)/i.test(url)) { return undefined; }
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(new fileUri.FileUri(uri).path);
      const frames: number = await source.getFrameCount();
      if (!cancellation.isCancelled && frames > 1) {
        return new AnimatedDrawableDescriptor(uri, { autoPlay: true, iterations: -1 });
      }
    } catch { /* Keep the ordinary image path when animation metadata is unavailable. */ }
    finally { if (source) { try { await source.release(); } catch { /* Source is no longer used. */ } } }
    return undefined;
  }
  private matchesDecodedImage(identity: LoadedImageIdentity): boolean {
    return this.live && this.cachedUri === identity.uri && this.url === identity.source &&
      this.ownerId === identity.ownerId && (this.sessionRef.user?.id || 0) === identity.ownerId &&
      this.imageGeneration === identity.generation && forumApi.getSessionGeneration() === identity.generation &&
      this.imageRevision === identity.revision && this.sessionRef.revision === identity.revision;
  }
  private naturalSize(width: number, height: number, identity: LoadedImageIdentity): void {
    if (this.matchesDecodedImage(identity) && Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      this.onNaturalSize(width, height);
    }
  }
  private decodeFailed(identity: LoadedImageIdentity): void {
    if (!this.matchesDecodedImage(identity)) { return; }
    this.cachedUri = '';
    this.animatedSource = undefined;
    this.failed = true;
    if (this.context) { void invalidateForumMedia(identity.source, this.context); }
  }
  private animationVisibility(visible: boolean, ratio: number, identity: LoadedImageIdentity): void {
    if (!this.matchesDecodedImage(identity)) { return; }
    const controller = this.animatedSource?.getAnimationController();
    if (!controller) { return; }
    const status: AnimationStatus = controller.getStatus();
    if (!visible || ratio <= 0) {
      if (status === AnimationStatus.Running) { controller.pause(); }
    } else if (status === AnimationStatus.Paused) {
      controller.resume();
    } else if (status !== AnimationStatus.Running) {
      controller.start();
    }
  }

  @Builder
  private decodedImage(identity: LoadedImageIdentity) {
    if (this.animatedSource) {
      Image(this.animatedSource)
        .width('100%')
        .height('100%')
        .objectFit(this.fit)
        .accessibilityText(this.accessibleLabel)
        .onVisibleAreaChange([0.01], (visible: boolean, ratio: number): void => this.animationVisibility(visible, ratio, identity))
    } else {
      Image(identity.uri)
        .width('100%')
        .height('100%')
        .objectFit(this.fit)
        .accessibilityText(this.accessibleLabel)
        .onComplete((event): void => this.naturalSize(event?.width || 0, event?.height || 0, identity))
        .onError((): void => this.decodeFailed(identity))
    }
  }

  @Builder
  private imageContent() {
    if (this.cachedUri && this.ownerId === (this.sessionRef.user?.id || 0)) {
      this.decodedImage({ uri: this.cachedUri, source: this.url, ownerId: this.ownerId,
        generation: this.imageGeneration, revision: this.imageRevision })
    } else if (this.loading) {
      LoadingProgress().width(24).height(24).color($r('sys.color.brand'))
        .accessibilityText('正在加载' + this.accessibleLabel)
    } else if (this.failed) {
      Text('图片暂不可用')
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .padding(4)
        .accessibilityText(this.accessibleLabel + '暂不可用，点击重试')
        .onClick((): void => this.scheduleLoad())
    } else {
      Text('')
    }
  }
  build() {
    if (this.previewImageAspectRatio > 0) {
      Stack() { this.imageContent() }
        .width('100%')
        .height('100%')
        .aspectRatio(this.previewImageAspectRatio)
    } else {
      Stack() { this.imageContent() }
        .width('100%')
        .height('100%')
    }
  }
}
