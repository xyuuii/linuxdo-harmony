export interface NavigationMorphFrame {
  surfaceWidth: number;
  surfaceHeight: number;
  surfaceLeft: number;
  buttonWidth: number;
  buttonLeft: number;
  iconTop: number;
  labelOpacity: number;
}

function mix(start: number, end: number, progress: number): number {
  return start + (end - start) * progress;
}

/** Every part of the same surface uses this single, bounded progress in vp. */
export function navigationMorphFrame(availableWidth: number, index: number, progress: number,
  sideLeft: boolean = false): NavigationMorphFrame {
  const width: number = Number.isFinite(availableWidth) && availableWidth >= 52 ? availableWidth : 328;
  const value: number = Number.isFinite(progress) ? Math.max(0, Math.min(1, progress)) : 0;
  const tab: number = Number.isFinite(index) ? Math.max(0, Math.min(3, Math.floor(index))) : 0;
  const surfaceWidth: number = mix(width, 52, value);
  const buttonWidth: number = mix(width / 4, 52, value);
  const center: number = mix((tab + 0.5) * width / 4, 26, value);
  return {
    surfaceWidth: surfaceWidth,
    surfaceHeight: mix(56, 52, value),
    surfaceLeft: sideLeft ? 0 : width - surfaceWidth,
    buttonWidth: buttonWidth,
    buttonLeft: center - buttonWidth / 2,
    iconTop: mix(6, 14.5, value),
    labelOpacity: 1 - value
  };
}
