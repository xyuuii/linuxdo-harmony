import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';

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
  private foreground: boolean = false;
  private generation: number = 0;
  private callback: Callback<motion.HoldingHandStatus> | undefined = undefined;

  start(): void {
    if (this.foreground) { return; }
    this.foreground = true;
    const generation: number = ++this.generation;
    // If off previously failed, remove that exact registration before adding another.
    if (!this.unsubscribe()) { return; }
    try {
      if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        this.availability = HandednessAvailability.Unsupported;
        this.lastErrorCode = 801;
        return;
      }
      const callback: Callback<motion.HoldingHandStatus> = (status: motion.HoldingHandStatus): void => {
        if (!this.foreground || this.generation !== generation) { return; }
        this.holdingStatus = status;
        this.sideLeft = sideLeftForHolding(this.sideLeft, status);
      };
      motion.on('holdingHandChanged', callback);
      this.callback = callback;
      this.availability = HandednessAvailability.Listening;
      this.lastErrorCode = 0;
    } catch (error) {
      this.callback = undefined;
      this.recordError(error as BusinessError);
    }
  }

  stop(): void {
    this.foreground = false;
    this.generation++;
    if (this.unsubscribe()) { this.availability = HandednessAvailability.Idle; }
  }

  private unsubscribe(): boolean {
    const callback: Callback<motion.HoldingHandStatus> | undefined = this.callback;
    if (callback === undefined) { return true; }
    try {
      // Omitting callback would also cancel registrations owned by other consumers.
      motion.off('holdingHandChanged', callback);
      this.callback = undefined;
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
  }
}

export const handednessState: HandednessState = new HandednessState();
