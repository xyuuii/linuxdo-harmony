import {
  Topic, Category, DiscourseUser, Poster, Post, Boost, Reaction, PostStream, TopicDetail,
  ForumNotification, avatarUrlOf
} from '../models/ForumModels';

export interface TagWire { name?: string; }
export interface PosterWire { user_id?: number; description?: string; }
export interface UserWire {
  id?: number; username?: string; name?: string; avatar_template?: string; trust_level?: number;
  created_at?: string; bio_raw?: string; bio_cooked?: string; email?: string;
}
export interface TopicWire {
  id?: number; title?: string; slug?: string; posts_count?: number; reply_count?: number; views?: number;
  like_count?: number; category_id?: number; created_at?: string; last_posted_at?: string; bumped_at?: string;
  pinned?: boolean; closed?: boolean; unseen?: boolean; excerpt?: string; image_url?: string;
  tags?: Array<string | TagWire>; last_poster_username?: string; posters?: PosterWire[];
}
export interface TopicListWire { topics?: TopicWire[]; more_topics_url?: string; }
export interface TopicListResponseWire { topic_list?: TopicListWire; users?: UserWire[]; }
export interface CategoryWire {
  id?: number; name?: string; slug?: string; color?: string; text_color?: string; description?: string;
  topic_count?: number; parent_category_id?: number; subcategory_list?: CategoryWire[];
}
export interface CategoryListWire { categories?: CategoryWire[]; }
export interface CategoryResponseWire { category_list?: CategoryListWire; }
export interface ReactionWire { id?: string; count?: number; can_undo?: boolean; }
export interface BoostWire { id?: number; cooked?: string; user?: UserWire; can_delete?: boolean; }
export interface PostWire {
  id?: number; username?: string; avatar_template?: string; post_number?: number; created_at?: string;
  cooked?: string; topic_id?: number; blurb?: string; reply_to_post_number?: number; reply_count?: number;
  boosts?: BoostWire[]; reactions?: ReactionWire[]; current_user_reaction?: ReactionWire; yours?: boolean;
  can_boost?: boolean; can_accept_answer?: boolean; can_unaccept_answer?: boolean; accepted_answer?: boolean;
  can_edit?: boolean; can_delete?: boolean; raw?: string;
}
export interface PostStreamWire { posts?: PostWire[]; stream?: number[]; }
export interface TopicDetailsWire { can_create_post?: boolean; }
export interface TopicDetailWire {
  id?: number; title?: string; category_id?: number; post_stream?: PostStreamWire; valid_reactions?: string[];
  closed?: boolean; archived?: boolean; details?: TopicDetailsWire;
}
export interface PostStreamResponseWire { post_stream?: PostStreamWire; replies?: PostWire[]; posts?: PostWire[]; }
export interface SearchGroupWire { more_full_page_results?: boolean; }
export interface SearchResponseWire { topics?: TopicWire[]; posts?: PostWire[]; grouped_search_result?: SearchGroupWire; }
export interface NotificationDataWire {
  display_username?: string; fancy_title?: string; topic_title?: string; badge_name?: string; message?: string;
  topic_id?: number; original_post_number?: number; post_number?: number; count?: number;
}
export interface NotificationWire {
  id?: number; notification_type?: number; read?: boolean; fancy_title?: string; acting_user_name?: string;
  acting_user_avatar_template?: string; created_at?: string; topic_id?: number; post_number?: number;
  data?: NotificationDataWire;
}
export interface NotificationResponseWire { notifications?: NotificationWire[]; total_rows_notifications?: number; }
export interface CsrfWire { csrf?: string; }
export interface CurrentUserWire { current_user?: UserWire; }
export interface UserResponseWire { user?: UserWire; }
export interface PostResponseWire { post?: PostWire; }
export interface UploadResponseWire { short_url?: string; url?: string; original_filename?: string; width?: number; height?: number; }
export interface LoginResponseWire {
  user?: UserWire; error?: string; reason?: string; totp_enabled?: boolean; backup_enabled?: boolean;
  second_factor_required?: boolean; multiple_second_factor_methods?: Object; success?: string | boolean;
}
export interface SummaryWire {
  days_visited?: number; time_read?: number; topics_entered?: number; posts_read_count?: number;
  likes_given?: number; likes_received?: number; topic_count?: number; post_count?: number;
}
export interface SummaryResponseWire { user_summary?: SummaryWire; }
export interface EmailsWire { email?: string; secondary_emails?: string[]; }
export interface ActionWire { post_id?: number; topic_id?: number; post_number?: number; title?: string;
  excerpt?: string; action_type?: number; created_at?: string; }
export interface ActionsResponseWire { user_actions?: ActionWire[]; }
export interface EmojiWire { name?: string; id?: string; url?: string; }

export function decodeObject<T extends object>(body: string): T {
  const value: T = JSON.parse(body) as T;
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Invalid JSON object');
  }
  return value;
}
export function decodeArray<T>(body: string): T[] {
  const value: T[] = JSON.parse(body) as T[];
  if (!Array.isArray(value)) { throw new Error('Invalid JSON array'); }
  return value;
}
export function text(value: string | undefined, fallback: string = ''): string {
  return typeof value === 'string' ? value : fallback;
}
export function numberValue(value: number | undefined, fallback: number = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
export function bool(value: boolean | undefined, fallback: boolean = false): boolean {
  return typeof value === 'boolean' ? value : fallback;
}
export function list<T>(value: T[] | undefined): T[] { return Array.isArray(value) ? value : []; }
export function plainText(value: string): string {
  return value.replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/\s+/g, ' ').trim();
}
function requireId(value: number | undefined): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) { throw new Error('Invalid id'); }
  return value;
}
function requireUserId(value: number | undefined): number {
  // Discourse service users can have signed IDs (the system account is -1).
  // Zero remains the client's anonymous-owner sentinel, never a user identifier.
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value === 0) { throw new Error('Invalid user id'); }
  return value;
}
export function userFromWire(value: UserWire): DiscourseUser {
  const username: string = text(value.username);
  if (username.length === 0) { throw new Error('Invalid username'); }
  const template: string = text(value.avatar_template);
  return { id: requireUserId(value.id), username: username, name: text(value.name), avatarTemplate: template,
    avatarUrl: avatarUrlOf(template), trustLevel: numberValue(value.trust_level) };
}
export function topicFromWire(value: TopicWire): Topic {
  if (typeof value.title !== 'string') { throw new Error('Invalid title'); }
  const tags: string[] = [];
  list(value.tags).forEach((tag: string | TagWire): void => {
    if (typeof tag === 'string') { tags.push(tag); }
    else if (tag !== null && typeof tag === 'object' && typeof tag.name === 'string') { tags.push(tag.name); }
  });
  const posters: Poster[] = list(value.posters).map((poster: PosterWire): Poster => {
    return { userId: numberValue(poster.user_id), description: text(poster.description) };
  });
  return { id: requireId(value.id), title: plainText(value.title), slug: text(value.slug),
    postsCount: numberValue(value.posts_count), replyCount: numberValue(value.reply_count), views: numberValue(value.views),
    likeCount: numberValue(value.like_count), categoryId: numberValue(value.category_id), createdAt: text(value.created_at),
    lastPostedAt: text(value.last_posted_at), bumpedAt: text(value.bumped_at), pinned: bool(value.pinned),
    closed: bool(value.closed), unseen: bool(value.unseen), excerpt: plainText(text(value.excerpt)),
    imageUrl: text(value.image_url), tags: tags, lastPosterUsername: text(value.last_poster_username), posters: posters };
}
export function categoryFromWire(value: CategoryWire, depth: number = 0): Category {
  if (depth > 12 || typeof value.name !== 'string') { throw new Error('Invalid category tree'); }
  return { id: requireId(value.id), name: value.name, slug: text(value.slug), color: text(value.color, '0A59F7'),
    textColor: text(value.text_color, 'FFFFFF'), description: plainText(text(value.description)),
    topicCount: numberValue(value.topic_count), parentCategoryId: numberValue(value.parent_category_id),
    subcategoryList: list(value.subcategory_list).map((child: CategoryWire): Category => categoryFromWire(child, depth + 1)) };
}
export function reactionFromWire(value: ReactionWire): Reaction {
  if (typeof value.id !== 'string') { throw new Error('Invalid reaction'); }
  return { id: value.id, count: numberValue(value.count), canUndo: bool(value.can_undo) };
}
export function boostFromWire(value: BoostWire): Boost {
  return { id: requireId(value.id), cooked: text(value.cooked),
    user: value.user ? userFromWire(value.user) : undefined, canDelete: bool(value.can_delete) };
}
export function postFromWire(value: PostWire): Post {
  const template: string = text(value.avatar_template);
  return { id: requireId(value.id), username: text(value.username), avatarTemplate: template,
    avatarUrl: avatarUrlOf(template), postNumber: numberValue(value.post_number), createdAt: text(value.created_at),
    cooked: text(value.cooked), topicId: numberValue(value.topic_id), blurb: plainText(text(value.blurb)),
    replyToPostNumber: numberValue(value.reply_to_post_number), replyCount: numberValue(value.reply_count),
    boosts: list(value.boosts).map((boost: BoostWire): Boost => boostFromWire(boost)),
    reactions: list(value.reactions).map((reaction: ReactionWire): Reaction => reactionFromWire(reaction)),
    currentUserReaction: value.current_user_reaction ? reactionFromWire(value.current_user_reaction) : undefined,
    yours: bool(value.yours), canBoost: bool(value.can_boost), canAcceptAnswer: bool(value.can_accept_answer),
    canUnacceptAnswer: bool(value.can_unaccept_answer), acceptedAnswer: bool(value.accepted_answer),
    canEdit: bool(value.can_edit), canDelete: bool(value.can_delete), raw: text(value.raw) };
}
export function streamFromWire(value: PostStreamWire): PostStream {
  const stream: number[] = list(value.stream).filter((id: number): boolean => Number.isSafeInteger(id) && id > 0);
  return { posts: list(value.posts).map((post: PostWire): Post => postFromWire(post)), stream: stream };
}
export function detailFromWire(value: TopicDetailWire): TopicDetail {
  if (!value.post_stream || typeof value.title !== 'string') { throw new Error('Invalid topic detail'); }
  const closed: boolean = bool(value.closed);
  const archived: boolean = bool(value.archived);
  const canCreatePost: boolean = value.details ? bool(value.details.can_create_post) : false;
  return { id: requireId(value.id), title: plainText(value.title), categoryId: numberValue(value.category_id),
    postStream: streamFromWire(value.post_stream), validReactions: list(value.valid_reactions)
      .filter((reaction: string): boolean => typeof reaction === 'string'),
    closed: closed, archived: archived, details: { canCreatePost: canCreatePost },
    canReply: canCreatePost && !closed && !archived };
}
const NOTIFICATION_LABELS: Record<string, string> = {
  '1': '提及', '2': '回复', '3': '引用', '4': '编辑', '5': '收到赞', '6': '私信', '7': '私信',
  '8': '接受邀请', '9': '发布话题', '10': '移动话题', '11': '链接', '12': '获赠徽章', '13': '话题邀请',
  '14': '解决方案', '15': '提及', '16': '私信', '17': '发布话题', '19': '收到赞', '25': '表情回应',
  '27': '活动提醒', '28': '活动邀请', '29': '聊天提及', '30': '聊天消息', '31': '聊天邀请',
  '32': '聊天提及', '33': '聊天引用', '34': '指派', '38': '链接', '43': '简评',
  '800': '关注', '801': '关注的人发布话题', '802': '关注的人回复'
};
export function notificationFromWire(value: NotificationWire): ForumNotification {
  const data: NotificationDataWire = value.data ?? {};
  let type: number = numberValue(value.notification_type);
  if (type === 14 && text(data.message).toLowerCase().indexOf('assigned') >= 0) { type = 34; }
  const label: string = NOTIFICATION_LABELS[String(type)] ?? '社区通知';
  const baseActor: string = text(data.display_username) || text(value.acting_user_name);
  const count: number = numberValue(data.count);
  const actor: string = count > 1 ? `${baseActor} 和其他 ${count - 1} 人` : baseActor;
  let title: string = text(value.fancy_title) || text(data.fancy_title) || text(data.topic_title);
  if (type === 12 && text(data.badge_name).length > 0) { title = `获得了 '${text(data.badge_name)}'`; }
  return { id: requireId(value.id), type: type, read: bool(value.read, true), title: plainText(title) || label,
    label: label, actor: actor, avatarUrl: avatarUrlOf(text(value.acting_user_avatar_template)),
    createdAt: text(value.created_at), topicId: numberValue(value.topic_id) || numberValue(data.topic_id),
    postNumber: numberValue(value.post_number) || numberValue(data.original_post_number) || numberValue(data.post_number) };
}
