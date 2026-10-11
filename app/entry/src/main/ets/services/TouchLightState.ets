/** Window-relative vp coordinates keep one light continuous across child buttons. */
@ObservedV2
export class TouchLightState {
  @Trace active: boolean = false;
  @Trace x: number = 0;
  @Trace y: number = 0;
  private width: number = 0;
  private height: number = 0;
  private windowX: number = 0;
  private windowY: number = 0;
  private primaryId: number | undefined = undefined;

  setArea(width: number, height: number, windowX: number, windowY: number): void {
    if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(height) || height <= 0 ||
      !Number.isFinite(windowX) || !Number.isFinite(windowY)) {
      this.width = 0;
      this.height = 0;
      this.clear();
      return;
    }
    if (this.width !== width || this.height !== height || this.windowX !== windowX || this.windowY !== windowY) {
      this.clear();
    }
    this.width = width;
    this.height = height;
    this.windowX = windowX;
    this.windowY = windowY;
  }

  update(event: TouchEvent, enabled: boolean): void {
    if (!enabled || this.width <= 0 || this.height <= 0 || event.type === TouchType.Cancel) {
      this.clear();
      return;
    }
    if (event.type === TouchType.Up) {
      // Releasing a secondary finger must not relocate the primary finger's light.
      const primaryReleased: boolean = event.changedTouches.some((point: TouchObject): boolean =>
        point.id === this.primaryId);
      if (event.changedTouches.length === 0 || primaryReleased ||
        !event.touches.some((point: TouchObject): boolean => point.id === this.primaryId)) {
        this.clear();
      }
      return;
    }
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      this.clear();
      return;
    }
    if (this.primaryId === undefined) {
      if (event.type !== TouchType.Down || event.changedTouches.length === 0) {
        this.clear();
        return;
      }
      const first: TouchObject = event.changedTouches[0];
      if (!Number.isInteger(first.id)) {
        this.clear();
        return;
      }
      this.primaryId = first.id;
    }
    const point: TouchObject | undefined = event.touches.find((touch: TouchObject): boolean =>
      touch.id === this.primaryId);
    if (point === undefined || !Number.isFinite(point.windowX) || !Number.isFinite(point.windowY)) {
      this.clear();
      return;
    }
    const localX: number = point.windowX - this.windowX;
    const localY: number = point.windowY - this.windowY;
    if (!Number.isFinite(localX) || !Number.isFinite(localY)) {
      this.clear();
      return;
    }
    this.x = Math.min(this.width, Math.max(0, localX));
    this.y = Math.min(this.height, Math.max(0, localY));
    this.active = true;
  }

  clear(): void {
    this.active = false;
    this.x = 0;
    this.y = 0;
    this.primaryId = undefined;
  }
}
