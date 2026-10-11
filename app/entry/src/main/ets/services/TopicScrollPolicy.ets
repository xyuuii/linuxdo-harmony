/** Consume scroll deltas in vp; positive movement reads towards the topic's tail. */
export class TopicScrollPolicy {
  private directionDistance: number = 0;

  reset(): void { this.directionDistance = 0; }

  update(offset: number, userDriven: boolean, atStart: boolean, blocked: boolean): boolean | undefined {
    if (!userDriven || blocked) {
      this.reset();
      return undefined;
    }
    if (atStart) {
      this.reset();
      return true;
    }
    if (!Number.isFinite(offset)) {
      this.reset();
      return undefined;
    }
    if (offset === 0) { return undefined; }
    if ((offset > 0 && this.directionDistance < 0) || (offset < 0 && this.directionDistance > 0)) {
      this.directionDistance = offset;
    } else {
      this.directionDistance += offset;
    }
    if (this.directionDistance >= 32) {
      this.reset();
      return false;
    }
    if (this.directionDistance <= -16) {
      this.reset();
      return true;
    }
    return undefined;
  }
}

/** End feedback reaches its full visual distance at a 64 vp upward pull. */
export function endPullProgress(distance: number): number {
  return distance > 0 ? Math.min(64, distance) / 64 : 0;
}

/** A topic has ended only after actual content was loaded with no next page or active failure. */
export function canShowTopicEnd(hasTopic: boolean, postCount: number, nextCount: number,
  loading: boolean, hasError: boolean): boolean {
  return hasTopic && Number.isFinite(postCount) && postCount > 0 && nextCount === 0 && !loading && !hasError;
}
