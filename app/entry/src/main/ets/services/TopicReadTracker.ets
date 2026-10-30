/** Actual native viewport and lifecycle evidence supplied by the reader. */
export interface TopicReadContext {
  ownerId: number;
  sessionGeneration: number;
  topicId: number;
  foreground: boolean;
  visible: boolean;
}
export interface TopicReadTiming { postNumber: number; milliseconds: number; }
export interface TopicReadBatch {
  ownerId: number;
  sessionGeneration: number;
  topicId: number;
  topicTimeMs: number;
  postTimings: TopicReadTiming[];
}

// Official Discourse screen-track uses milliseconds, pauses after three idle
// minutes and caps a post at six minutes. PostTiming caps each batch at 60s.
// A delayed native timer is not proof of continuous foreground visibility.
export const TOPIC_READ_FLUSH_MS: number = 15000;
const TOPIC_READ_IDLE_MS: number = 180000;
const TOPIC_READ_POST_LIMIT_MS: number = 360000;
const TOPIC_READ_BATCH_LIMIT_MS: number = 60000;
const TOPIC_READ_MAX_SAMPLE_GAP_MS: number = 5000;
const TOPIC_READ_MIN_POST_MS: number = 1000;

/** Pure accumulator: no timers, network, synthetic floors or automatic retries.
 * Call tick from a foreground timer; feed actual row-visibility callbacks.
 * A taken batch is consumed once, even if its write outcome is unknown.
 */
export class TopicReadTracker {
  private ownerId: number = 0;
  private sessionGeneration: number = -1;
  private topicId: number = 0;
  private active: boolean = false;
  private lastSampleAt: number = -1;
  private lastInteractionAt: number = -1;
  private lastBatchAt: number = -1;
  private visiblePosts: Set<number> = new Set<number>();
  private pendingPosts: Map<number, number> = new Map<number, number>();
  private totalPosts: Map<number, number> = new Map<number, number>();
  private topicTimeMs: number = 0;

  reset(): void {
    this.ownerId = 0; this.sessionGeneration = -1; this.topicId = 0; this.active = false;
    this.lastSampleAt = -1; this.lastInteractionAt = -1; this.lastBatchAt = -1;
    this.visiblePosts.clear(); this.pendingPosts.clear(); this.totalPosts.clear(); this.topicTimeMs = 0;
  }

  setContext(context: TopicReadContext, nowMs: number): void {
    if (!this.validClock(nowMs) || !Number.isSafeInteger(context.ownerId) || context.ownerId <= 0 ||
      !Number.isSafeInteger(context.sessionGeneration) || context.sessionGeneration < 0 ||
      !Number.isSafeInteger(context.topicId) || context.topicId <= 0) { this.reset(); return; }
    if (this.ownerId !== context.ownerId || this.sessionGeneration !== context.sessionGeneration || this.topicId !== context.topicId) {
      // Discard the former account/topic's pending batch; never migrate it.
      this.reset(); this.ownerId = context.ownerId; this.sessionGeneration = context.sessionGeneration;
      this.topicId = context.topicId; this.lastSampleAt = nowMs; this.lastInteractionAt = nowMs; this.lastBatchAt = nowMs;
    } else { this.tick(nowMs); }
    const nextActive: boolean = context.foreground && context.visible;
    if (nextActive && !this.active) { this.lastInteractionAt = nowMs; }
    this.active = nextActive;
    this.lastSampleAt = nowMs;
  }

  setPostVisible(postNumber: number, visible: boolean, nowMs: number): void {
    this.tick(nowMs);
    if (!this.validClock(nowMs) || !Number.isSafeInteger(postNumber) || postNumber <= 0) { return; }
    if (visible) { this.visiblePosts.add(postNumber); }
    else { this.visiblePosts.delete(postNumber); }
  }

  /** Clear stale native rows when a slice/tree is rebuilt, without guessing replacements. */
  clearVisiblePosts(nowMs: number): void { this.tick(nowMs); this.visiblePosts.clear(); }

  recordInteraction(nowMs: number): void {
    this.tick(nowMs);
    if (this.active && this.validClock(nowMs)) { this.lastInteractionAt = nowMs; }
  }

  tick(nowMs: number): void {
    if (!this.validClock(nowMs)) { return; }
    const previous: number = this.lastSampleAt;
    this.lastSampleAt = nowMs;
    if (previous < 0 || nowMs <= previous || nowMs - previous > TOPIC_READ_MAX_SAMPLE_GAP_MS ||
      !this.active || this.ownerId <= 0 || this.visiblePosts.size === 0 || this.lastInteractionAt < 0) { return; }
    const observed: number = Math.max(0, Math.min(nowMs, this.lastInteractionAt + TOPIC_READ_IDLE_MS) - previous);
    const elapsed: number = Math.min(observed, TOPIC_READ_BATCH_LIMIT_MS - this.topicTimeMs);
    if (elapsed <= 0) { return; }
    let tracked: boolean = false;
    this.visiblePosts.forEach((postNumber: number): void => {
      const total: number = this.totalPosts.get(postNumber) ?? 0;
      const pending: number = this.pendingPosts.get(postNumber) ?? 0;
      const duration: number = Math.min(elapsed, TOPIC_READ_POST_LIMIT_MS - total, TOPIC_READ_BATCH_LIMIT_MS - pending);
      if (duration > 0) {
        this.pendingPosts.set(postNumber, pending + duration); this.totalPosts.set(postNumber, total + duration); tracked = true;
      }
    });
    // Topic time counts a wall-clock interval once, even with several visible posts.
    if (tracked) { this.topicTimeMs += elapsed; }
  }

  takeBatch(nowMs: number, force: boolean = false): TopicReadBatch | undefined {
    this.tick(nowMs);
    if (!this.validClock(nowMs) || this.ownerId <= 0 || this.topicTimeMs <= 0 ||
      (!force && nowMs - this.lastBatchAt < TOPIC_READ_FLUSH_MS)) { return undefined; }
    const timings: TopicReadTiming[] = [];
    this.pendingPosts.forEach((milliseconds: number, postNumber: number): void => {
      // Briefly passing a row during a fling is not a confirmed read.
      if (milliseconds >= TOPIC_READ_MIN_POST_MS) { timings.push({ postNumber: postNumber, milliseconds: Math.floor(milliseconds) }); }
    });
    timings.sort((first: TopicReadTiming, second: TopicReadTiming): number => first.postNumber - second.postNumber);
    const topicTime: number = Math.floor(this.topicTimeMs);
    this.pendingPosts.clear(); this.topicTimeMs = 0; this.lastBatchAt = nowMs;
    if (timings.length === 0) { return undefined; }
    return { ownerId: this.ownerId, sessionGeneration: this.sessionGeneration, topicId: this.topicId,
      topicTimeMs: topicTime, postTimings: timings };
  }

  isCurrent(batch: TopicReadBatch): boolean {
    return this.ownerId > 0 && this.ownerId === batch.ownerId && this.sessionGeneration === batch.sessionGeneration && this.topicId === batch.topicId;
  }

  private validClock(nowMs: number): boolean { return Number.isFinite(nowMs) && nowMs >= 0; }
}
