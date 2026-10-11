export interface ViewerSize { width: number; height: number; }
export interface ViewerOffset { x: number; y: number; }

function positive(value: number): boolean { return Number.isFinite(value) && value > 0; }
function finite(value: number): number { return Number.isFinite(value) ? value : 0; }

/** Scale is relative to the image's fitted, fully visible size. */
export function viewerScale(value: number): number {
  return Number.isFinite(value) ? Math.max(1, Math.min(5, value)) : 1;
}

export function containViewerSize(viewport: ViewerSize, image: ViewerSize): ViewerSize {
  if (!positive(viewport.width) || !positive(viewport.height) ||
    !positive(image.width) || !positive(image.height)) { return { width: 0, height: 0 }; }
  const factor: number = Math.min(viewport.width / image.width, viewport.height / image.height);
  return { width: image.width * factor, height: image.height * factor };
}

/** Constrain the pixels of the fitted image, rather than its letterboxed container. */
export function constrainViewerOffset(viewport: ViewerSize, image: ViewerSize,
  scale: number, offset: ViewerOffset): ViewerOffset {
  const fitted: ViewerSize = containViewerSize(viewport, image);
  const boundedScale: number = viewerScale(scale);
  const limitX: number = Math.max(0, (fitted.width * boundedScale - finite(viewport.width)) / 2);
  const limitY: number = Math.max(0, (fitted.height * boundedScale - finite(viewport.height)) / 2);
  return { x: Math.max(-limitX, Math.min(limitX, finite(offset.x))),
    y: Math.max(-limitY, Math.min(limitY, finite(offset.y))) };
}

/** Keep the touched image point beneath the fingers when zooming. Coordinates are in vp. */
export function zoomViewerOffset(viewport: ViewerSize, image: ViewerSize, previousScale: number,
  nextScale: number, offset: ViewerOffset, focus: ViewerOffset, movedFocus: ViewerOffset): ViewerOffset {
  const ratio: number = viewerScale(nextScale) / viewerScale(previousScale);
  const relativeX: number = finite(focus.x) - viewport.width / 2;
  const relativeY: number = finite(focus.y) - viewport.height / 2;
  return constrainViewerOffset(viewport, image, nextScale, {
    x: finite(movedFocus.x) - viewport.width / 2 - (relativeX - finite(offset.x)) * ratio,
    y: finite(movedFocus.y) - viewport.height / 2 - (relativeY - finite(offset.y)) * ratio
  });
}

export function viewerIndex(index: number, count: number): number {
  return count > 0 && Number.isFinite(index) ? Math.max(0, Math.min(count - 1, Math.floor(index))) : 0;
}
