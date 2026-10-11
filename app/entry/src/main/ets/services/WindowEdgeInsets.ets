import { window } from '@kit.ArkUI';

function nonNegativeInset(value: number | undefined): number {
  return value !== undefined && Number.isFinite(value) && value >= 0 ? value : 0;
}

/** UIEnvWindowAvoidAreaInfoVP is already measured in vp; overlapping areas must not be added. */
export function topWindowInset(info: window.UIEnvWindowAvoidAreaInfoVP | undefined | null): number {
  return Math.max(nonNegativeInset(info?.statusBar?.topRect?.height),
    nonNegativeInset(info?.cutout?.topRect?.height));
}

export function bottomWindowInset(info: window.UIEnvWindowAvoidAreaInfoVP | undefined | null): number {
  return Math.max(nonNegativeInset(info?.navigationIndicator?.bottomRect?.height),
    nonNegativeInset(info?.statusBar?.bottomRect?.height),
    nonNegativeInset(info?.cutout?.bottomRect?.height));
}
