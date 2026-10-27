export interface NavigationMorphFrame {
  surfaceWidth: number;
  surfaceHeight: number;
  surfaceLeft: number;
  buttonWidth: number;
  buttonLeft: number;
  iconTop: number;
  labelOpacity: number;
}

export const navigationBarHeight: number = 52;
export const navigationCircleSize: number = 48;
export const navigationBarMaxWidth: number = 280;
export const navigationIconSize: number = 21;

function mix(start: number, end: number, progress: number): number {
  return start + (end - start) * progress;
}

/** Every part of the same surface uses this single, bounded progress in vp. */
export function navigationMorphFrame(availableWidth: number, index: number, progress: number,
  sideLeft: boolean = false): NavigationMorphFrame {
  const width: number = Number.isFinite(availableWidth) && availableWidth >= navigationCircleSize ? availableWidth : 328;
  const value: number = Number.isFinite(progress) ? Math.max(0, Math.min(1, progress)) : 0;
  const tab: number = Number.isFinite(index) ? Math.max(0, Math.min(4, Math.floor(index))) : 0;
  const expandedWidth: number = Math.min(width, navigationBarMaxWidth);
  const expandedLeft: number = (width - expandedWidth) / 2;
  const collapsedLeft: number = sideLeft ? 0 : width - navigationCircleSize;
  const surfaceWidth: number = mix(expandedWidth, navigationCircleSize, value);
  const buttonWidth: number = mix(expandedWidth / 5, navigationCircleSize, value);
  const center: number = mix((tab + 0.5) * expandedWidth / 5, navigationCircleSize / 2, value);
  return {
    surfaceWidth: surfaceWidth,
    surfaceHeight: mix(navigationBarHeight, navigationCircleSize, value),
    surfaceLeft: mix(expandedLeft, collapsedLeft, value),
    buttonWidth: buttonWidth,
    buttonLeft: center - buttonWidth / 2,
    iconTop: mix(5, (navigationCircleSize - navigationIconSize) / 2, value),
    labelOpacity: 1 - value
  };
}
