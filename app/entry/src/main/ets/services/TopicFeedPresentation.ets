import { TopicListItem } from '../models/ForumModels';

export interface TopicFeedSections { pinned: TopicListItem[]; topics: TopicListItem[]; }
export const PINNED_PREVIEW_COUNT: number = 3;

/** Compact metadata keeps real category/tag names in the server's order. */
export function topicMetadata(item: TopicListItem): string {
  const values: string[] = [];
  if (item.category?.name) { values.push(item.category.name); }
  item.topic.tags.slice(0, 2).forEach((tag: string): void => { values.push(tag); });
  return values.join(' · ') || item.authorUsername || item.topic.lastPosterUsername;
}

export function compactTopicTime(value: string): string {
  const millis: number = Date.parse(value);
  if (!Number.isFinite(millis)) { return ''; }
  const minutes: number = Math.max(0, Math.floor((Date.now() - millis) / 60000));
  if (minutes < 1) { return '刚刚'; }
  if (minutes < 60) { return `${minutes}分`; }
  if (minutes < 1440) { return `${Math.floor(minutes / 60)}小时`; }
  if (minutes < 10080) { return `${Math.floor(minutes / 1440)}天`; }
  const date: Date = new Date(millis);
  return `${date.getMonth() + 1}/${date.getDate()}`;
}

/** Presentation grouping preserves the server order and does not alter pin/read state. */
export function splitTopicFeed(items: TopicListItem[]): TopicFeedSections {
  const pinned: TopicListItem[] = [];
  const topics: TopicListItem[] = [];
  const seen: Set<number> = new Set<number>();
  items.forEach((item: TopicListItem): void => {
    if (seen.has(item.topic.id)) { return; }
    seen.add(item.topic.id);
    if (item.topic.pinned) { pinned.push(item); }
    else { topics.push(item); }
  });
  return { pinned: pinned, topics: topics };
}

export function visiblePinnedTopics(items: TopicListItem[], expanded: boolean): TopicListItem[] {
  return expanded ? items : items.slice(0, PINNED_PREVIEW_COUNT);
}
