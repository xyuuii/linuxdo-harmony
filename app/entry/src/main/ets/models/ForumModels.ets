export interface Poster { userId: number; description: string; }
export interface Topic {
  id: number;
  title: string;
  slug: string;
  postsCount: number;
  replyCount: number;
  views: number;
  likeCount: number;
  categoryId: number;
  createdAt: string;
  lastPostedAt: string;
  bumpedAt: string;
  pinned: boolean;
  closed: boolean;
  unseen: boolean;
  excerpt: string;
  imageUrl: string;
  tags: string[];
  lastPosterUsername: string;
  posters: Poster[];
}
export interface DiscourseUser {
  id: number;
  username: string;
  name: string;
  avatarTemplate: string;
  avatarUrl: string;
  trustLevel: number;
}
export interface Category {
  id: number;
  name: string;
  slug: string;
  color: string;
  textColor: string;
  description: string;
  topicCount: number;
  parentCategoryId: number;
  subcategoryList: Category[];
}
export interface TopicListItem {
  topic: Topic;
  authorUsername: string;
  avatarUrl: string;
  category?: Category;
}
export interface TopicPage { items: TopicListItem[]; hasMore: boolean; }
export interface Reaction { id: string; count: number; canUndo: boolean; }
export interface Boost { id: number; cooked: string; user?: DiscourseUser; canDelete: boolean; }
export interface Post {
  id: number;
  username: string;
  avatarTemplate: string;
  avatarUrl: string;
  postNumber: number;
  createdAt: string;
  cooked: string;
  topicId: number;
  blurb: string;
  replyToPostNumber: number;
  replyCount: number;
  boosts: Boost[];
  reactions: Reaction[];
  currentUserReaction?: Reaction;
  yours: boolean;
  canBoost: boolean;
  canAcceptAnswer: boolean;
  canUnacceptAnswer: boolean;
  acceptedAnswer: boolean;
  canEdit: boolean;
  canDelete: boolean;
  raw: string;
}
export interface PostStream { posts: Post[]; stream: number[]; }
export interface TopicDetails { canCreatePost: boolean; }
export interface TopicDetail {
  id: number;
  title: string;
  categoryId: number;
  postStream: PostStream;
  validReactions: string[];
  closed: boolean;
  archived: boolean;
  details: TopicDetails;
  canReply: boolean;
}
export enum SearchOrder {
  Relevance = '', Latest = 'latest', Likes = 'likes', Views = 'views', LatestTopic = 'latest_topic', Read = 'read'
}
export interface SearchPage { items: TopicListItem[]; excerpts: Map<number, string>; hasMore: boolean; }
export enum ProfileSection {
  Summary = 'summary', Activity = 'activity', Notifications = 'notifications', Messages = 'messages', Account = 'account'
}
export enum NotificationFilter { All = 'all', Replies = 'replies', Likes = 'likes', Messages = 'messages' }
export enum ProfileOrder { Latest = 'latest' }
export interface SearchOrderOption { value: SearchOrder; key: string; label: string; }
export const searchOrders: SearchOrderOption[] = [
  { value: SearchOrder.Relevance, key: '', label: '相关性' },
  { value: SearchOrder.Latest, key: 'latest', label: '最新帖子' },
  { value: SearchOrder.Likes, key: 'likes', label: '赞最多' },
  { value: SearchOrder.Views, key: 'views', label: '浏览最多' },
  { value: SearchOrder.LatestTopic, key: 'latest_topic', label: '最新话题' },
  { value: SearchOrder.Read, key: 'read', label: '最近阅读' }
];
export interface NotificationFilterOption { value: NotificationFilter; label: string; }
export const notificationFilters: NotificationFilterOption[] = [
  { value: NotificationFilter.All, label: '全部' }, { value: NotificationFilter.Replies, label: '回复' },
  { value: NotificationFilter.Likes, label: '点赞' }, { value: NotificationFilter.Messages, label: '私信' }
];
export interface ForumNotification {
  id: number;
  type: number;
  read: boolean;
  title: string;
  label: string;
  actor: string;
  avatarUrl: string;
  createdAt: string;
  topicId: number;
  postNumber: number;
}
export interface NotificationPage { notifications: ForumNotification[]; hasMore: boolean; nextOffset: number; }
export interface UnreadSummary {
  count: number;
  unreadFilters: NotificationFilter[];
  unreadByFilter: Map<NotificationFilter, number>;
}
export interface ProfileField { label: string; value: string; }
export interface ProfileEntry {
  id: string;
  title: string;
  subtitle: string;
  topicId: number;
  unread: boolean;
  notificationType: number;
  avatarUrl: string;
  actor: string;
  postNumber: number;
}
export interface ProfilePage { fields: ProfileField[]; entries: ProfileEntry[]; hasMore: boolean; nextCursor: number; }
export interface UploadedFile { shortUrl: string; fileName: string; width: number; height: number; }
export interface BoostLength { visible: number; emoji: number; submittable: boolean; }

export function safeForumUrl(value: string): string {
  if (/[\u0000-\u0020\u007F\\]/.test(value)) { return ''; }
  if (/^https:\/\/linux\.do(?:\/|$)/.test(value)) { return value; }
  if (value.startsWith('/') && !value.startsWith('//')) { return 'https://linux.do' + value; }
  return '';
}

export function avatarUrlOf(template: string, size: number = 144): string {
  if (template.length === 0) { return ''; }
  const path: string = template.replace('{size}', String(size));
  if (path.startsWith('//')) { return 'https:' + path; }
  if (path.startsWith('https://')) { return path; }
  return path.startsWith('/') ? 'https://linux.do' + path : '';
}

export function flattenCategories(categories: Category[]): Category[] {
  const result: Category[] = [];
  const seen: Set<number> = new Set<number>();
  const pending: Category[] = categories.slice();
  while (pending.length > 0) {
    const category: Category | undefined = pending.shift();
    if (category !== undefined && !seen.has(category.id)) {
      seen.add(category.id);
      result.push(category);
      pending.push(...category.subcategoryList);
    }
  }
  return result;
}

export function notificationIncludes(filter: NotificationFilter, type: number): boolean {
  if (filter === NotificationFilter.Replies) { return [1, 2, 3, 15, 33, 43].indexOf(type) >= 0; }
  if (filter === NotificationFilter.Likes) { return [5, 19, 25].indexOf(type) >= 0; }
  if (filter === NotificationFilter.Messages) { return [6, 7, 16].indexOf(type) >= 0; }
  return true;
}

export function uploadedFileMarkdown(file: UploadedFile): string {
  const name: string = file.fileName.replace(/[\[\]\r\n|]/g, '_');
  return file.width > 0 && file.height > 0 ?
    `![${name}|${file.width}x${file.height}](${file.shortUrl})` : `[${name}|attachment](${file.shortUrl})`;
}

export function measureBoost(raw: string): BoostLength {
  let emoji: number = 0;
  const text: string = raw.trim().replace(/:[a-zA-Z0-9_+\-]{1,40}:/g, (): string => { emoji++; return ''; });
  let visible: number = 0;
  let index: number = 0;
  let joined: boolean = false;
  let regional: boolean = false;
  while (index < text.length) {
    const code: number = text.codePointAt(index) ?? 0;
    index += code > 0xFFFF ? 2 : 1;
    if (code === 0x200D) { joined = true; }
    else if ((code >= 0xFE00 && code <= 0xFE0F) || (code >= 0x1F3FB && code <= 0x1F3FF) || code === 0x20E3) {
      // Emoji modifiers belong to the previous visible grapheme.
    } else if (code >= 0x1F1E6 && code <= 0x1F1FF) {
      if (!regional) { emoji++; }
      regional = !regional;
      joined = false;
    } else if ((code >= 0x1F000 && code <= 0x1FAFF) || (code >= 0x2600 && code <= 0x27BF) ||
      (code >= 0x2B00 && code <= 0x2BFF)) {
      if (!joined) { emoji++; }
      joined = false;
      regional = false;
    } else { visible++; joined = false; regional = false; }
  }
  return { visible: visible, emoji: emoji, submittable: visible <= 16 && emoji <= 5 && visible + emoji > 0 };
}
