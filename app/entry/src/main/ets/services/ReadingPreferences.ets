import { TopicFeedFilter, TopicFeedFilterOption, topicFeedFilters } from '../models/ForumModels';

/** Stored values use the server filter names so a reordered control remains compatible. */
export function defaultTopicFeedIndex(feed: string): number {
  const index: number = topicFeedFilters.findIndex((option: TopicFeedFilterOption): boolean => option.value === feed);
  return index >= 0 ? index : 0;
}

export function defaultTopicFeedValue(index: number): TopicFeedFilter {
  return Number.isInteger(index) && index >= 0 && index < topicFeedFilters.length ?
    topicFeedFilters[index].value : TopicFeedFilter.Latest;
}

export function shouldCollapseTopicBars(immersiveTopics: boolean, reduceMotion: boolean, highContrast: boolean): boolean {
  return immersiveTopics && !reduceMotion && !highContrast;
}

/** Resume within a known server post range; explicit links should keep their own target. */
export function firstUnreadPostNumber(lastReadPostNumber: number, highestPostNumber: number, openAtUnread: boolean): number {
  if (!openAtUnread || !Number.isSafeInteger(lastReadPostNumber) || lastReadPostNumber < 1 ||
    !Number.isSafeInteger(highestPostNumber) || highestPostNumber < 1) {
    return 1;
  }
  return Math.min(lastReadPostNumber + 1, highestPostNumber);
}
