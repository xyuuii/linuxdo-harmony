import { TopicListItem } from '../models/ForumModels';

export interface TopicFeedSections { pinned: TopicListItem[]; topics: TopicListItem[]; }
export const PINNED_PREVIEW_COUNT: number = 3;

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
