import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export enum HandednessAvailability { Idle = 'idle', Listening = 'listening', Unsupported = 'unsupported', Unavailable = 'unavailable' }

/** Only an explicit single-hand result may move controls; uncertain results retain the last side. */
export function sideLeftForHolding(previous: boolean, status: motion.HoldingHandStatus): boolean {
  if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) { return true; }
  if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) { return false; }
  return previous;
}

@ObservedV2
export class HandednessState {
  @Trace sideLeft: boolean = false;
  @Trace availability: HandednessAvailability = HandednessAvailability.Idle;
  @Trace holdingStatus: motion.HoldingHandStatus = motion.HoldingHandStatus.UNKNOWN_STATUS;
  @Trace lastErrorCode: number = 0;
  @Trace hasHoldingResult: boolean = false;
  private foreground: boolean = false;
  private generation: number = 0;
  private callback: Callback<motion.HoldingHandStatus> | undefined = undefined;

  start(): void {
    if (this.foreground) { return; }
    this.foreground = true;
    const generation: number = ++this.generation;
    // If off previously failed, remove that exact registration before adding another.
    if (!this.unsubscribe()) { return; }
    this.hasHoldingResult = false;
    this.holdingStatus = motion.HoldingHandStatus.UNKNOWN_STATUS;
    try {
      if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        this.availability = HandednessAvailability.Unsupported;
        this.lastErrorCode = 801;
        this.logState('unsupported');
        return;
      }
      const callback: Callback<motion.HoldingHandStatus> = (status: motion.HoldingHandStatus): void => {
        if (!this.foreground || this.generation !== generation) { return; }
        this.holdingStatus = status;
        this.hasHoldingResult = true;
        this.sideLeft = sideLeftForHolding(this.sideLeft, status);
        this.logState('event');
      };
      motion.on('holdingHandChanged', callback);
      this.callback = callback;
      this.availability = HandednessAvailability.Listening;
      this.lastErrorCode = 0;
      this.logState('subscribe');
    } catch (error) {
      this.callback = undefined;
      this.recordError(error as BusinessError);
    }
  }

  stop(): void {
    this.foreground = false;
    this.generation++;
    if (this.unsubscribe() && this.availability !== HandednessAvailability.Idle) {
      this.availability = HandednessAvailability.Idle;
      this.logState('stop');
    }
  }

  /** Diagnostic wording comes from the actual subscription/result, never from the retained UI side. */
  diagnosticText(): string {
    if (this.availability === HandednessAvailability.Unsupported) {
      return `当前设备暂不支持（${this.lastErrorCode}）`;
    }
    if (this.availability === HandednessAvailability.Unavailable) {
      return `暂不可用（${this.lastErrorCode}）`;
    }
    if (this.availability === HandednessAvailability.Idle) { return '等待应用前台连接'; }
    if (!this.hasHoldingResult) { return '已连接系统，等待握持'; }
    if (this.holdingStatus === motion.HoldingHandStatus.LEFT_HAND_HELD) { return '当前左手握持'; }
    if (this.holdingStatus === motion.HoldingHandStatus.RIGHT_HAND_HELD) { return '当前右手握持'; }
    if (this.holdingStatus === motion.HoldingHandStatus.BOTH_HANDS_HELD) { return '双手握持，保持按钮位置'; }
    if (this.holdingStatus === motion.HoldingHandStatus.NOT_HELD) { return '未握持，保持按钮位置'; }
    return '未识别握持，保持按钮位置';
  }

  private unsubscribe(): boolean {
    const callback: Callback<motion.HoldingHandStatus> | undefined = this.callback;
    if (callback === undefined) { return true; }
    try {
      // Omitting callback would also cancel registrations owned by other consumers.
      motion.off('holdingHandChanged', callback);
      this.callback = undefined;
      this.logState('unsubscribe');
      return true;
    } catch (error) {
      this.recordError(error as BusinessError);
      return false;
    }
  }

  private recordError(error: BusinessError): void {
    const code: number = error?.code;
    this.lastErrorCode = Number.isFinite(code) ? code : -1;
    this.availability = code === 801 ? HandednessAvailability.Unsupported : HandednessAvailability.Unavailable;
    this.logState('error');
  }

  private logState(phase: string): void {
    hilog.info(0x0000, 'LinuxDoGrip',
      '%{public}s availability=%{public}s status=%{public}d code=%{public}d side=%{public}s',
      phase, this.availability, this.holdingStatus, this.lastErrorCode, this.sideLeft ? 'left' : 'right');
  }
}

export const handednessState: HandednessState = new HandednessState();
