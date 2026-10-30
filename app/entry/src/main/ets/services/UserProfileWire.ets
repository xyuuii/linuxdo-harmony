import { ProfileField, avatarUrlOf } from '../models/ForumModels';
import { ForumUserProfile, ForumUserSummary, ForumUserActivityEntry, ForumUserActivityPage,
  ForumUserActivityFilter, forumUserMetric } from '../models/UserProfileModels';
import { text, numberValue, bool, plainText } from './ForumWire';

export interface ForumUserProfileWire {
  id?: number; username?: string; name?: string; avatar_template?: string; animated_avatar?: string; trust_level?: number;
  title?: string; bio_raw?: string; bio_cooked?: string; bio_excerpt?: string; created_at?: string; last_seen_at?: string;
  location?: string; profile_hidden?: boolean;
}
export interface ForumUserProfileResponseWire { user?: ForumUserProfileWire; }
export interface ForumUserSummaryWire {
  days_visited?: number; time_read?: number; topics_entered?: number; posts_read_count?: number;
  likes_given?: number; likes_received?: number; topic_count?: number; post_count?: number;
  can_see_summary_stats?: boolean; can_see_user_actions?: boolean;
}
export interface ForumUserSummaryResponseWire { user_summary?: ForumUserSummaryWire; }
export interface ForumUserActivityWire {
  action_type?: number; created_at?: string; post_id?: number; topic_id?: number; post_number?: number;
  title?: string; excerpt?: string;
}
export interface ForumUserActivityResponseWire { user_actions?: ForumUserActivityWire[]; }

export function forumUserProfileFromWire(wire: ForumUserProfileWire): ForumUserProfile {
  const trust: number = numberValue(wire.trust_level, -1);
  const hidden: boolean = bool(wire.profile_hidden);
  return { id: numberValue(wire.id), username: text(wire.username), name: plainText(text(wire.name)),
    avatarUrl: avatarUrlOf(text(wire.avatar_template), 144, text(wire.animated_avatar)),
    trustLevel: !hidden && Number.isInteger(trust) && trust >= 0 && trust <= 4 ? trust : -1,
    title: plainText(text(wire.title)),
    bio: hidden ? '' : plainText(text(wire.bio_cooked) || text(wire.bio_excerpt) || text(wire.bio_raw)),
    createdAt: hidden ? '' : text(wire.created_at), lastSeenAt: hidden ? '' : text(wire.last_seen_at),
    location: hidden ? '' : plainText(text(wire.location)), hidden: hidden };
}

export function forumUserSummaryFromWire(wire: ForumUserSummaryWire): ForumUserSummary {
  const allowed: boolean = wire.can_see_summary_stats !== false;
  const read: number | undefined = allowed ? wire.time_read : undefined;
  const fields: ProfileField[] = [
    { label: '发表话题', value: forumUserMetric(allowed ? wire.topic_count : undefined) },
    { label: '回复数量', value: forumUserMetric(allowed ? wire.post_count : undefined) },
    { label: '收到的赞', value: forumUserMetric(allowed ? wire.likes_received : undefined) },
    { label: '送出的赞', value: forumUserMetric(allowed ? wire.likes_given : undefined) },
    { label: '访问天数', value: forumUserMetric(allowed ? wire.days_visited : undefined) },
    { label: '浏览话题', value: forumUserMetric(allowed ? wire.topics_entered : undefined) },
    { label: '已读帖子', value: forumUserMetric(allowed ? wire.posts_read_count : undefined) },
    { label: '阅读时长', value: typeof read === 'number' && Number.isFinite(read) && read >= 0 ? `${Math.floor(read / 60)} 分钟` : '—' }
  ];
  return { fields: fields, canSeeStats: wire.can_see_summary_stats, canSeeActions: wire.can_see_user_actions };
}

export function forumUserActivityFromWire(actions: ForumUserActivityWire[], filter: ForumUserActivityFilter,
  offset: number): ForumUserActivityPage {
  const seen: Set<string> = new Set<string>();
  const entries: ForumUserActivityEntry[] = [];
  actions.forEach((wire: ForumUserActivityWire): void => {
    const actionType: number = numberValue(wire.action_type);
    const topicId: number = numberValue(wire.topic_id);
    if (topicId <= 0 || (actionType !== 4 && actionType !== 5) ||
      (filter === ForumUserActivityFilter.Topics && actionType !== 4) || (filter === ForumUserActivityFilter.Replies && actionType !== 5)) { return; }
    const postNumber: number = numberValue(wire.post_number, 1);
    const id: string = `${actionType}:${numberValue(wire.post_id)}:${topicId}:${postNumber}:${text(wire.created_at)}`;
    if (seen.has(id)) { return; } seen.add(id);
    entries.push({ id: id, topicId: topicId, postNumber: Number.isSafeInteger(postNumber) && postNumber > 0 ? postNumber : 1,
      title: plainText(text(wire.title)) || '社区话题', excerpt: plainText(text(wire.excerpt)),
      createdAt: text(wire.created_at), actionType: actionType });
  });
  // The cursor counts all server rows, including duplicates or a nonmatching row.
  return { entries: entries, hasMore: actions.length >= 30, nextOffset: offset + actions.length };
}
