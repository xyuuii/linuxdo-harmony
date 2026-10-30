import { ProfileField } from './ForumModels';

export interface ForumUserProfile {
  id: number; username: string; name: string; avatarUrl: string; trustLevel: number;
  title: string; bio: string; createdAt: string; lastSeenAt: string; location: string; hidden: boolean;
}
export interface ForumUserSummary {
  fields: ProfileField[]; canSeeStats?: boolean; canSeeActions?: boolean;
}
export enum ForumUserActivityFilter { Topics = '4', Replies = '5', All = '4,5' }
export interface ForumUserActivityOption { value: ForumUserActivityFilter; label: string; }
export const forumUserActivityFilters: ForumUserActivityOption[] = [
  { value: ForumUserActivityFilter.Topics, label: '话题' },
  { value: ForumUserActivityFilter.Replies, label: '回复' },
  { value: ForumUserActivityFilter.All, label: '活动' }
];
export interface ForumUserActivityEntry {
  id: string; topicId: number; postNumber: number; title: string; excerpt: string;
  createdAt: string; actionType: number;
}
export interface ForumUserActivityPage { entries: ForumUserActivityEntry[]; hasMore: boolean; nextOffset: number; }

export function forumUserMetric(value: number | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? String(value) : '—';
}
export function forumUserDate(value: string): string {
  return /^\d{4}-\d{2}-\d{2}/.test(value) ? value.substring(0, 10) : '未公开';
}
