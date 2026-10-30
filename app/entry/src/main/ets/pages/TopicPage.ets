import { ReaderGlassSurface } from '../components/ReaderGlassSurface';
import { MaterialBarHost } from '../components/MaterialBarHost';
import { BoostBubble } from '../components/BoostBubble';
import { common } from '@kit.AbilityKit';
import { window, curves, uiMaterial } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { Boost, Category, Post, Reaction, TopicDetail, flattenCategories, measureBoost } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { materialFor, readerBackdropFor } from '../services/MaterialPolicy';
import { RichPostContent, postContentUrl, parsePostContent, PostBlock } from '../components/RichPostContent';
import { ForumAvatar } from '../components/ForumComponents';
import { ForumImageViewer } from '../components/ForumImageViewer';
import { NativeForumImage } from '../components/NativeForumImage';
import { relativeTime } from '../services/ForumPresentation';
import { TopicScrollPolicy, endPullProgress, canShowTopicEnd } from '../services/TopicScrollPolicy';
import { copyPostLink, sharePostLink } from '../services/PostSharing';
import { TopicNotificationOptions } from '../components/TopicNotificationOptions';
import { FlagPostSheet } from '../components/FlagPostSheet';
import { PostRevisionSheet } from '../components/PostRevisionSheet';
import { canReadPostHistory } from '../models/PostRevisionModels';
import { TopicReadTracker, TopicReadContext, TopicReadBatch } from '../services/TopicReadTracker';

export interface TopicTreeRow {
  post: Post;
  rootId: number;
  depth: number;
  lastInGroup: boolean;
  totalReplies: number;
  loadedReplies: number;
  shownReplies: number;
  unloadedIds: number[];
}

interface TreeNode { post: Post; depth: number; }

function parentNumber(post: Post): number {
  if (post.replyToPostNumber > 1) { return post.replyToPostNumber; }
  const aside: RegExpExecArray | null = /<aside\b[^>]*\bclass\s*=\s*["'][^"']*quote[^"']*["'][^>]*>/i.exec(post.cooked);
  if (aside === null) { return 0; }
  const topic: RegExpExecArray | null = /\bdata-topic\s*=\s*["'](\d+)["']/i.exec(aside[0]);
  if (topic !== null && Number(topic[1]) !== post.topicId) { return 0; }
  const number: RegExpExecArray | null = /\bdata-post\s*=\s*["'](\d+)["']/i.exec(aside[0]);
  const value: number = number === null ? 0 : Number(number[1]);
  return value > 1 && value < post.postNumber ? value : 0;
}

/** Missing parents stay visible; the original post is never a threaded reply root. */
export function topicTreeRows(posts: Post[], expanded: number[], collapsed: number[], tree: boolean): TopicTreeRow[] {
  const ordered: Post[] = posts.slice().sort((left: Post, right: Post): number => left.postNumber - right.postNumber);
  const byNumber: Map<number, Post> = new Map<number, Post>();
  const children: Map<number, Post[]> = new Map<number, Post[]>();
  ordered.forEach((post: Post): void => { byNumber.set(post.postNumber, post); });
  ordered.forEach((post: Post): void => {
    const parent: Post | undefined = byNumber.get(parentNumber(post));
    const id: number = tree && parent !== undefined && parent.postNumber > 1 &&
      parent.postNumber < post.postNumber ? parent.id : 0;
    const group: Post[] = children.get(id) || [];
    group.push(post);
    children.set(id, group);
  });
  const output: TopicTreeRow[] = [];
  for (const root of children.get(0) || []) {
    const descendants: TreeNode[] = [];
    const stack: TreeNode[] = (children.get(root.id) || []).slice().reverse()
      .map((post: Post): TreeNode => ({ post: post, depth: 1 }));
    let total: number = root.postNumber === 1 ? 0 : Math.max(root.replyCount, (children.get(root.id) || []).length);
    const unloaded: number[] = root.postNumber !== 1 && root.replyCount > (children.get(root.id) || []).length ? [root.id] : [];
    while (stack.length > 0) {
      const node: TreeNode = stack.pop() as TreeNode;
      descendants.push(node);
      const direct: Post[] = children.get(node.post.id) || [];
      total += Math.max(direct.length, node.post.replyCount);
      if (node.post.replyCount > direct.length) { unloaded.push(node.post.id); }
      direct.slice().reverse().forEach((post: Post): void => { stack.push({ post: post, depth: node.depth + 1 }); });
    }
    const visible: TreeNode[] = collapsed.includes(root.id) ? [] :
      expanded.includes(root.id) ? descendants : descendants.slice(0, 3);
    output.push({ post: root, rootId: root.id, depth: 0, lastInGroup: visible.length === 0,
      totalReplies: total, loadedReplies: descendants.length, shownReplies: visible.length, unloadedIds: unloaded });
    visible.forEach((node: TreeNode, index: number): void => {
      output.push({ post: node.post, rootId: root.id, depth: node.depth, lastInGroup: index === visible.length - 1,
        totalReplies: total, loadedReplies: descendants.length, shownReplies: visible.length, unloadedIds: unloaded });
    });
  }
  return output;
}

@ObservedV2
class ObservedTopicTreeRow implements TopicTreeRow {
  @Trace post: Post = {} as Post;
  @Trace rootId: number = 0;
  @Trace depth: number = 0;
  @Trace lastInGroup: boolean = false;
  @Trace totalReplies: number = 0;
  @Trace loadedReplies: number = 0;
  @Trace shownReplies: number = 0;
  @Trace unloadedIds: number[] = [];
  constructor(value: TopicTreeRow) { this.update(value); }
  update(value: TopicTreeRow): void {
    this.post = value.post;
    this.rootId = value.rootId;
    this.depth = value.depth;
    this.lastInGroup = value.lastInGroup;
    this.totalReplies = value.totalReplies;
    this.loadedReplies = value.loadedReplies;
    this.shownReplies = value.shownReplies;
    this.unloadedIds = value.unloadedIds;
  }
}

/** Keep observable rows alive while their layout/reactions change under stable keys. */
class TopicRowsSource implements IDataSource {
  private items: ObservedTopicTreeRow[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): ObservedTopicTreeRow { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
  update(items: TopicTreeRow[]): void {
    const existing: Map<string, ObservedTopicTreeRow> = new Map<string, ObservedTopicTreeRow>();
    this.items.forEach((row: ObservedTopicTreeRow): void => {
      existing.set(`${row.post.id}-${row.rootId}-${row.depth}`, row);
    });
    this.items = items.map((row: TopicTreeRow): ObservedTopicTreeRow => {
      const old: ObservedTopicTreeRow | undefined = existing.get(`${row.post.id}-${row.rootId}-${row.depth}`);
      if (old !== undefined) { old.update(row); return old; }
      return new ObservedTopicTreeRow(row);
    });
    this.listeners.forEach((listener: DataChangeListener): void => { listener.onDataReloaded(); });
  }
}

function dateLabel(value: string): string {
  const date: Date = new Date(value);
  return Number.isNaN(date.getTime()) ? '日期未知' : relativeTime(value);
}

function failureMessage(error: Object): string {
  return error instanceof Error && error.message ? error.message : '请求未完成，请稍后重试。';
}

function postWithBoosts(post: Post, boosts: Boost[]): Post {
  return { id: post.id, username: post.username, displayName: post.displayName, avatarTemplate: post.avatarTemplate, avatarUrl: post.avatarUrl,
    bookmarked: post.bookmarked, bookmarkId: post.bookmarkId, flagTypes: post.flagTypes,
    version: post.version, canViewEditHistory: post.canViewEditHistory,
    postNumber: post.postNumber, createdAt: post.createdAt, cooked: post.cooked, topicId: post.topicId, blurb: post.blurb,
    replyToPostNumber: post.replyToPostNumber, replyCount: post.replyCount, boosts: boosts, reactions: post.reactions,
    currentUserReaction: post.currentUserReaction, yours: post.yours, canBoost: post.canBoost,
    canAcceptAnswer: post.canAcceptAnswer, canUnacceptAnswer: post.canUnacceptAnswer,
    acceptedAnswer: post.acceptedAnswer, canEdit: post.canEdit, canDelete: post.canDelete, raw: post.raw };
}

function postWithBookmark(post: Post, bookmarkId: number): Post {
  const updated: Post = postWithBoosts(post, post.boosts);
  updated.bookmarked = bookmarkId > 0;
  updated.bookmarkId = bookmarkId > 0 ? bookmarkId : undefined;
  return updated;
}

interface TopicLink { id: number; number: number; }

const POST_ATTACHMENT_EXTENSIONS: string[] = ['zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz',
  'apk', 'apks', 'xapk', 'ipa', 'exe', 'msi', 'dmg', 'pkg', 'deb', 'rpm', 'pdf', 'doc', 'docx',
  'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'txt', 'json', 'xml', 'yaml', 'yml', 'toml', 'ini', 'conf',
  'log', 'sql', 'sh', 'bat', 'ps1', 'py', 'jar', 'iso', 'mp3', 'flac', 'wav', 'mp4', 'mkv', 'mov'];

export function isPostAttachmentUrl(url: string): boolean {
  const path: string = url.split('?')[0].split('#')[0].toLowerCase();
  const extension: string = path.split('.').pop() || '';
  if (POST_ATTACHMENT_EXTENSIONS.includes(extension)) { return true; }
  return /\/uploads\/(?:short-url|default)\//.test(path) &&
    !['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'svg', 'avif', 'heic'].includes(extension);
}

export function parseTopicLink(url: string): TopicLink | undefined {
  const match: RegExpExecArray | null = /^https:\/\/(?:www\.)?linux\.do(?::443)?(\/[^?#]*)/i.exec(url);
  if (match === null) { return undefined; }
  const parts: string[] = match[1].split('/').filter((part: string): boolean => part.length > 0);
  if (parts[0] !== 't' || parts.length < 2) { return undefined; }
  const first: number = Number(parts[1]);
  if (Number.isInteger(first) && first > 0) {
    const number: number = parts.length > 2 ? Number(parts[2]) : 1;
    return { id: first, number: Number.isInteger(number) && number > 0 ? number : 1 };
  }
  const id: number = parts.length > 2 ? Number(parts[2]) : 0;
  const number: number = parts.length > 3 ? Number(parts[3]) : 1;
  return Number.isInteger(id) && id > 0 ? { id: id, number: Number.isInteger(number) && number > 0 ? number : 1 } : undefined;
}

@ComponentV2
struct TopicPostCard {
  @Param post: Post = {} as Post;
  @Param compact: boolean = false;
  @Param topicTitle: string = '';
  @Param category: Category | undefined = undefined;
  @Param tags: string[] = [];
  @Param replyCount: number = 0;
  @Param authorUsername: string = '';
  @Param topicState: string = '';
  @Param canReply: boolean = false;
  @Param busy: boolean = false;
  @Param highlighted: boolean = false;
  @Param reactions: string[] = [];
  @Param reactionEmojiUrls: Map<string, string> = new Map<string, string>();
  @Param reduceMotion: boolean = false;
  @Param loggedIn: boolean = false;
  @Event onReply: (post: Post) => void = (_post: Post): void => {};
  @Event onEdit: (post: Post) => void = (_post: Post): void => {};
  @Event onDelete: (post: Post) => void = (_post: Post): void => {};
  @Event onReact: (post: Post, reaction: string) => void = (_post: Post, _reaction: string): void => {};
  @Event onSolution: (post: Post) => void = (_post: Post): void => {};
  @Event onBookmark: (post: Post) => void = (_post: Post): void => {};
  @Event onCopyLink: (post: Post) => void = (_post: Post): void => {};
  @Event onShare: (post: Post) => void = (_post: Post): void => {};
  @Event onQuote: (post: Post) => void = (_post: Post): void => {};
  @Event onFlag: (post: Post) => void = (_post: Post): void => {};
  @Event onHistory: (post: Post) => void = (_post: Post): void => {};
  @Event onBoost: (post: Post, raw: string) => Promise<boolean> =
    async (_post: Post, _raw: string): Promise<boolean> => false;
  @Event onDeleteBoost: (post: Post, boost: Boost) => void = (_post: Post, _boost: Boost): void => {};
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Event onOpenUser: (username: string) => void = (_username: string): void => {};
  @Event onJump: (number: number) => void = (_number: number): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local boosting: boolean = false;
  @Local boostDraft: string = '';

  @Computed
  get reactionChoices(): string[] { return Array.from(new Set<string>(['heart'].concat(this.reactions))); }

  @Computed
  get canReact(): boolean {
    return this.loggedIn && !this.busy && !this.post.yours &&
      (this.post.currentUserReaction === undefined || this.post.currentUserReaction.canUndo);
  }

  @Computed
  get isAuthor(): boolean { return this.post.username.length > 0 && this.post.username === this.authorUsername; }

  @Computed
  get postDisplayName(): string { return this.post.displayName?.trim() || this.post.username; }

  @Computed
  get visibleReactions(): Reaction[] {
    return this.post.reactions.filter((reaction: Reaction): boolean => Number.isFinite(reaction.count) && reaction.count > 0);
  }

  @Computed
  get totalReactions(): number {
    return this.visibleReactions.reduce((total: number, reaction: Reaction): number => total + reaction.count, 0);
  }

  @Computed
  get reactionSummary(): string {
    return this.visibleReactions.map((reaction: Reaction): string =>
      `${reaction.id === 'heart' ? '喜欢' : reaction.id} ${reaction.count}`).join('，');
  }

  @Computed
  get heartCount(): number {
    return this.post.reactions.find((reaction: Reaction): boolean => reaction.id === 'heart')?.count || 0;
  }

  @Computed
  get primaryReaction(): string {
    // LINUX DO's visible primary control uses heart. Like the official client,
    // an existing emoji is toggled off instead of silently changed into heart.
    return this.post.currentUserReaction?.id || 'heart';
  }

  @Computed
  get reactionLabel(): string {
    const selected: Reaction | undefined = this.post.currentUserReaction;
    if (selected !== undefined && selected.id !== 'heart') { return '✓ 已回应'; }
    return `${selected !== undefined ? '♥' : '♡'} ${this.heartCount > 0 ? this.heartCount :
      (selected !== undefined ? '已喜欢' : '喜欢')}`;
  }

  @Computed
  get hasMoreActions(): boolean {
    return Number.isSafeInteger(this.post.id) && this.post.id > 0;
  }

  @Builder
  reactionIcon(reaction: string) {
    if (reaction === 'heart') {
      SymbolGlyph($r('sys.symbol.heart_fill')).fontSize(14).fontColor([$r('app.color.error')])
    } else if (this.reactionEmojiUrls.has(reaction)) {
      NativeForumImage({ url: this.reactionEmojiUrls.get(reaction) || '', fit: ImageFit.Contain,
        accessibleLabel: `${reaction} 表情`, previewImageAspectRatio: 0 }).width(14).height(14)
    } else {
      Text('◌').fontSize(14).fontColor($r('app.color.text_secondary')).width(14).height(14)
        .accessibilityText(`${reaction} 表情暂不可用`)
    }
  }

  @Builder
  reactionOption(reaction: string) {
    Row({ space: 10 }) {
      this.reactionIcon(reaction)
      Text(reaction === 'heart' ? '喜欢' : reaction).fontSize(14).fontColor($r('app.color.text_primary'))
    }.padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  @Builder
  reactionMenu() {
    Menu() {
      ForEach(this.reactionChoices, (reaction: string) => {
        MenuItem(() => { this.reactionOption(reaction) })
          .enabled(this.canReact).onClick(() => { this.onReact(this.post, reaction); })
      }, (reaction: string): string => reaction)
    }
  }

  @Builder
  manageMenu() {
    Menu() {
      MenuItem({ content: '复制楼层链接' }).onClick(() => { this.onCopyLink(this.post); })
      MenuItem({ content: '分享' }).onClick(() => { this.onShare(this.post); })
      if (this.loggedIn) {
        MenuItem({ content: this.post.bookmarked ? '取消收藏' : '收藏' }).enabled(!this.busy)
          .onClick(() => { this.onBookmark(this.post); })
      } else {
        MenuItem({ content: '登录后收藏' }).onClick(this.onLogin)
      }
      if (this.canReply && this.loggedIn) {
        MenuItem({ content: '引用回复' }).enabled(!this.busy).onClick((): void => { this.onQuote(this.post); })
      }
      if ((this.post.flagTypes?.length ?? 0) > 0) {
        MenuItem({ content: '举报' }).enabled(!this.busy).onClick((): void => { this.onFlag(this.post); })
      }
      if (canReadPostHistory(this.post)) {
        MenuItem({ content: '编辑历史' }).enabled(!this.busy).onClick((): void => { this.onHistory(this.post); })
      }
      if (this.post.canEdit) {
        MenuItem({ content: '编辑' }).enabled(!this.busy).onClick(() => { this.onEdit(this.post); })
      }
      if (this.post.canDelete) {
        MenuItem({ content: '删除' }).enabled(!this.busy).onClick(() => { this.onDelete(this.post); })
      }
      if (this.post.canBoost) {
        MenuItem({ content: '写简评' }).enabled(!this.busy).onClick(() => { this.boosting = !this.boosting; })
      }
      if (this.post.canAcceptAnswer || this.post.canUnacceptAnswer) {
        MenuItem({ content: this.post.acceptedAnswer ? '取消解决方案' : '标为解决方案' }).enabled(!this.busy)
          .onClick(() => { this.onSolution(this.post); })
      }
    }
  }

  build() {
    Column({ space: this.compact ? 6 : 8 }) {
      if (this.post.postNumber === 1 && this.topicTitle.length > 0) {
        Column({ space: 10 }) {
          Text(this.topicTitle).fontSize(22).lineHeight(30).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary')).width('100%').id('topic_main_title')
          Row({ space: 6 }) {
            if (this.category !== undefined) {
              Circle().width(7).height(7).fill(/^#?[0-9a-fA-F]{6}$/.test(this.category.color) ?
                `#${this.category.color.replace('#', '')}` : $r('app.color.accent'))
              Text(this.category.name).fontSize(12).fontColor($r('app.color.text_secondary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            } else { Blank() }
            Text(`${this.replyCount} 条回复`).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.width('100%')
          if (this.tags.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.tags, (tag: string) => {
                Text(tag).fontSize(12).fontColor($r('app.color.text_secondary'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor($r('app.color.page_background')).borderRadius(6)
                  .margin({ right: 6, bottom: 5 })
              }, (tag: string): string => tag)
            }.width('100%')
          }
          if (this.topicState.length > 0) {
            Text(this.topicState).fontSize(12).fontColor($r('app.color.text_secondary'))
          }
        }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 4 })
      }
      Row({ space: 8 }) {
        ForumAvatar({ name: this.post.username, url: this.post.avatarUrl, avatarSize: this.compact ? 24 : 32 })
          .onClick((): void => { if (this.post.username) { this.onOpenUser(this.post.username); } })
        Column({ space: this.compact ? 1 : 2 }) {
          Row({ space: 5 }) {
            Text(this.postDisplayName).fontSize(this.compact ? 14 : 16).lineHeight(this.compact ? 18 : 20)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
              .onClick((): void => { if (this.post.username) { this.onOpenUser(this.post.username); } })
            if (this.isAuthor) {
              Text('楼主').fontSize(10).fontColor($r('app.color.accent')).padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .backgroundColor($r('app.color.selected_background')).borderRadius(4)
            }
          }.width('100%')
          Text(`@${this.post.username}`).fontSize(this.compact ? 11 : 12).lineHeight(this.compact ? 14 : 16)
            .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => { if (this.post.username) { this.onOpenUser(this.post.username); } })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 3 }) {
          Text(dateLabel(this.post.createdAt)).fontSize(11).lineHeight(14).fontColor($r('app.color.text_secondary'))
          Text(`#${this.post.postNumber}`).fontSize(11).lineHeight(14).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.End)
      }.width('100%')
      if (this.post.replyToPostNumber > 0) {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left')).fontSize(14).fontColor([$r('app.color.text_secondary')])
            Text(`回复第 ${this.post.replyToPostNumber} 楼`).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.width('100%').justifyContent(FlexAlign.Start).padding({ left: 10, right: 10 })
        }.width('100%').height(32).borderRadius(8).backgroundColor($r('app.color.boost_background'))
          .systemMaterial(uiMaterial.Material.empty).accessibilityText(`查看回复引用的第 ${this.post.replyToPostNumber} 楼`)
          .onClick((): void => { this.onJump(this.post.replyToPostNumber); })
      }
      RichPostContent({ cooked: this.post.cooked, compact: this.compact, reduceMotion: this.reduceMotion,
        onOpenLink: this.onOpenLink, onPicture: this.onPicture })
      if (this.post.boosts.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(this.post.boosts, (boost: Boost) => {
            BoostBubble({ boost: boost, busy: this.busy, reduceMotion: this.reduceMotion,
              onOpenLink: this.onOpenLink, onPicture: this.onPicture,
              onDelete: (item: Boost): void => { this.onDeleteBoost(this.post, item); } })
              .margin({ right: 4, bottom: 3 })
          }, (boost: Boost): string => boost.id.toString())
        }.width('100%')
      }
      if (this.boosting && this.post.canBoost) {
        Column({ space: 8 }) {
          TextInput({ text: this.boostDraft, placeholder: '写一句简评…' }).maxLength(120).height(44)
            .onChange((value: string): void => { this.boostDraft = value; })
          Row() {
            Text(`${measureBoost(this.boostDraft).visible}/16 字 · ${measureBoost(this.boostDraft).emoji}/5 表情`)
              .fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
            Button('发送简评', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).height(40)
              .enabled(!this.busy && measureBoost(this.boostDraft).submittable)
              .onClick(async (): Promise<void> => {
                if (await this.onBoost(this.post, this.boostDraft)) { this.boostDraft = ''; this.boosting = false; }
              })
          }.width('100%')
        }.width('100%')
      }
      Row({ space: 4 }) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph(this.post.currentUserReaction !== undefined ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(20).fontColor([this.post.currentUserReaction !== undefined ? $r('app.color.error') : $r('app.color.text_secondary')])
        }.width(40).height(40).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
          .enabled(this.canReact).onClick((): void => { this.onReact(this.post, this.primaryReaction); })
          .bindContextMenu(this.reactionMenu, ResponseType.LongPress)
          .accessibilityText(this.post.currentUserReaction === undefined ? '点按喜欢，长按选择回应表情' :
            (this.post.currentUserReaction.canUndo ? '已回应，点按撤销，长按选择回应表情' : '已回应，已超过可撤销时间'))
          .id(`post_reaction_${this.post.id}`)
        if (this.totalReactions > 0) {
          Row({ space: 2 }) {
            ForEach(this.visibleReactions.slice(0, 3), (reaction: Reaction) => {
              this.reactionIcon(reaction.id)
            }, (reaction: Reaction): string => reaction.id)
            Text(String(this.totalReactions)).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
          }.flexShrink(1).accessibilityGroup(true).accessibilityText(this.reactionSummary)
            .id(`post_reactions_summary_${this.post.id}`)
        }
        if (this.post.replyCount > 0) {
          Text(`${this.post.replyCount} 回复`).fontSize(11).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            .accessibilityText(`${this.post.replyCount} 条直接回复`)
        }
        if (this.post.acceptedAnswer) {
          Text('✓ 已解决').fontSize(11).fontColor($r('app.color.accent')).maxLines(1).flexShrink(1)
        }
        Blank()
        if (this.canReply || (!this.loggedIn && this.topicState.length === 0)) {
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          }.width(40).height(40).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
            .accessibilityText(`回复第 ${this.post.postNumber} 楼`).enabled(!this.busy)
            .onClick((): void => { if (this.loggedIn) { this.onReply(this.post); } else { this.onLogin(); } })
        }
        if (this.post.canBoost) {
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Image($r('app.media.ic_boost_rocket')).width(20).height(20)
              .fillColor($r('app.color.text_secondary')).accessibilityLevel('no')
          }.width(40).height(40).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
            .enabled(!this.busy).accessibilityText(this.boosting ? '收起简评输入' : '写简评')
            .id(`post_add_boost_${this.post.postNumber}`).onClick((): void => { this.boosting = !this.boosting; })
        }
        if (this.hasMoreActions) {
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Image($r('app.media.ic_more_horiz')).width(22).height(22)
              .fillColor($r('app.color.text_secondary')).accessibilityLevel('no')
          }.width(40).height(40).backgroundColor(Color.Transparent).systemMaterial(uiMaterial.Material.empty)
            .accessibilityText(`第 ${this.post.postNumber} 楼更多操作`).id(`post_more_${this.post.id}`)
            .bindMenu(this.manageMenu)
        }
      }.width('100%').height(40)
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: this.compact ? 10 : 16, right: this.compact ? 10 : 16,
        top: this.compact ? 8 : 12, bottom: this.compact ? 8 : 10 })
      .backgroundColor(this.highlighted ? $r('app.color.selected_background') : $r('app.color.surface'))
      .borderRadius(this.compact ? 6 : 0).id(`post_${this.post.postNumber}`)
  }
}

@ComponentV2
export struct TopicPage {
  @Param topicId: number = 0;
  @Param postNumber: number = 1;
  @Param reloadSignal: number = 0;
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param treeView: boolean = true;
  @Param foreground: boolean = true;
  @Param readerCovered: boolean = false;
  @Param session: ForumSession = forumSession;
  @Event onCompose: (topicId: number, replyTo: number, postId: number) => void =
    (_topicId: number, _replyTo: number, _postId: number): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (_id: number, _number: number): void => {};
  @Event onLogin: () => void = (): void => {};
  @Event onBack: () => void = (): void => {};
  @Event onSearchTopic: (id: number) => void = (_id: number): void => {};
  @Event onOpenUser: (username: string) => void = (_username: string): void => {};
  @Event onQuote: (topicId: number, postNumber: number, quoteText: string) => void =
    (_topicId: number, _postNumber: number, _quoteText: string): void => {};
  @Local topic: TopicDetail | undefined = undefined;
  @Local topicCategory: Category | undefined = undefined;
  @Local reactionEmojiUrls: Map<string, string> = new Map<string, string>();
  @Local posts: Post[] = [];
  @Local rows: TopicTreeRow[] = [];
  @Local loading: boolean = false;
  @Local refreshing: boolean = false;
  @Local writeBusy: boolean = false;
  @Local error: string = '';
  @Local expanded: number[] = [];
  @Local collapsed: number[] = [];
  @Local completedReplies: number[] = [];
  @Local loadingReplies: number[] = [];
  @Local sliceStart: number = 0;
  @Local sliceEnd: number = -1;
  @Local consumed: number[] = [];
  @Local currentNumber: number = 1;
  @Local highlightedId: number = 0;
  @Local showJump: boolean = false;
  @Local showTopicOptions: boolean = false;
  @Local sharingPanelOpen: boolean = false;
  @Local showFlag: boolean = false;
  @Local flagTarget: Post | undefined = undefined;
  @Local showHistory: boolean = false;
  @Local historyTarget: Post | undefined = undefined;
  @Local jumpInput: string = '';
  @Local showPicture: boolean = false;
  @Local pictureUrl: string = '';
  @Local savingPicture: boolean = false;
  @Local savingAttachment: boolean = false;
  @Local pictureUrls: string[] = [];
  @Local pictureInitialIndex: number = 0;
  @Local toolbarExpanded: boolean = true;
  @Local readerBarWidth: number = 360;
  @Local endFeedbackProgress: number = 0;
  @Local endFeedbackVisible: boolean = false;
  private endPullDistance: number = 0;
  private endHintTimer: number = 0;
  private readonly scrollPolicy: TopicScrollPolicy = new TopicScrollPolicy();
  private pictureScrollOffset: number = 0;
  private pendingNumber: number = 0;
  private preserveRequestedFloor: boolean = false;
  private viewportAnchorNumber: number = 0;
  private generation: number = 0;
  private entered: boolean = false;
  private lastInputNumber: number = 1;
  private handledReloadSignal: number = 0;
  private hidden: boolean = false;
  private pendingVisibleReload: number = 0;
  private topicOwnerId: number = 0;
  private reactionEmojiOwnerId: number = 0;
  private reactionEmojiGeneration: number = -1;
  private writeRequest: RequestCancellation | undefined = undefined;
  private readonly source: TopicRowsSource = new TopicRowsSource();
  private readonly scroller: Scroller = new Scroller();
  private readTracker: TopicReadTracker | undefined = undefined;
  private readTimer: number = 0;
  private readRequest: RequestCancellation | undefined = undefined;
  private quoteRequest: RequestCancellation | undefined = undefined;
  private readFinalizing: boolean = false;
  private readOwnerId: number = 0;
  private readSessionGeneration: number = -1;
  private readTopicId: number = 0;
  private readonly visibleReadPosts: Set<number> = new Set<number>();

  aboutToAppear(): void {
    if (this.readTracker === undefined) { this.readTracker = new TopicReadTracker(); }
  }

  aboutToDisappear(): void {
    if (this.readTimer !== 0) { clearInterval(this.readTimer); this.readTimer = 0; }
  }

  @Monitor('foreground', 'readerCovered', 'showPicture', 'showJump', 'showTopicOptions', 'sharingPanelOpen', 'showFlag', 'showHistory', 'loading')
  readingVisibilityChanged(): void {
    this.syncReadingContext();
    if (this.foreground && !this.hidden && this.entered) { this.startReadingTimer(); }
    else if (this.readTimer !== 0) { clearInterval(this.readTimer); this.readTimer = 0; }
  }

  private syncReadingContext(): void {
    const tracker: TopicReadTracker | undefined = this.readTracker;
    if (tracker === undefined) { return; }
    const now: number = Date.now();
    const owner: number = this.session.user?.id || 0;
    const sessionGeneration: number = forumApi.getSessionGeneration();
    if (owner !== this.readOwnerId || sessionGeneration !== this.readSessionGeneration || this.topicId !== this.readTopicId) {
      this.readRequest?.cancel(); this.readRequest = undefined; this.readFinalizing = false;
      this.visibleReadPosts.clear(); tracker.reset();
      this.readOwnerId = owner; this.readSessionGeneration = sessionGeneration; this.readTopicId = this.topicId;
    }
    const visible: boolean = this.readingViewportActive();
    const context: TopicReadContext = { ownerId: owner, sessionGeneration: sessionGeneration,
      topicId: this.topicId, foreground: this.foreground, visible: visible };
    tracker.setContext(context, now);
    if (!this.foreground || (!visible && !this.readFinalizing)) { this.readRequest?.cancel(); }
  }

  private readingViewportActive(): boolean {
    return this.entered && !this.hidden && !this.readerCovered && !this.showPicture && !this.showJump &&
      !this.showTopicOptions && !this.sharingPanelOpen && !this.showFlag && !this.showHistory && !this.loading && this.topic !== undefined &&
      this.topicOwnerId === (this.session.user?.id || 0);
  }

  private startReadingTimer(): void {
    if (this.readTracker === undefined || this.readTimer !== 0 || !this.foreground || this.hidden) { return; }
    this.syncReadingContext();
    this.readTimer = setInterval((): void => {
      this.syncReadingContext();
      void this.flushReadingTimings(false);
    }, 1000);
  }

  private async flushReadingTimings(force: boolean): Promise<void> {
    const tracker: TopicReadTracker | undefined = this.readTracker;
    if (tracker === undefined || !this.foreground || (!force && !this.readingViewportActive()) ||
      (this.readRequest !== undefined && !force)) { return; }
    const batch: TopicReadBatch | undefined = tracker.takeBatch(Date.now(), force);
    if (batch === undefined || !tracker.isCurrent(batch)) { return; }
    if (force) { this.readRequest?.cancel(); }
    const cancellation: RequestCancellation = new RequestCancellation();
    this.readRequest = cancellation; this.readFinalizing = force;
    try { await forumApi.recordTopicReadTimings(batch, cancellation); }
    catch { /* A consumed timing batch is never replayed after an uncertain write. */ }
    finally {
      if (this.readRequest === cancellation) { this.readRequest = undefined; this.readFinalizing = false; }
    }
  }

  private postVisibilityChanged(postNumber: number, visible: boolean): void {
    this.syncReadingContext();
    if (visible) { this.visibleReadPosts.add(postNumber); } else { this.visibleReadPosts.delete(postNumber); }
    this.readTracker?.setPostVisible(postNumber, visible, Date.now());
  }

  private resetReadingIdentity(): void {
    this.readRequest?.cancel(); this.readRequest = undefined; this.readFinalizing = false;
    this.readTracker?.reset(); this.visibleReadPosts.clear();
    this.readOwnerId = 0; this.readSessionGeneration = -1; this.readTopicId = 0;
  }

  @Computed
  get originalAuthor(): string { return this.posts.find((post: Post): boolean => post.postNumber === 1)?.username || ''; }

  @Computed
  get totalFloors(): number {
    return Math.max(1, this.topic?.highestPostNumber || 0, this.stream.length,
      ...this.posts.map((post: Post): number => post.postNumber));
  }

  @Computed
  get visibleFloor(): number { return Math.max(1, Math.min(this.currentNumber, this.totalFloors)); }

  @Computed
  get topicReplyCount(): number { return this.topic?.replyCount ?? Math.max(0, this.stream.length - 1); }

  @Computed
  get readerToolsVisible(): boolean { return this.appearance.reduceMotion || this.appearance.highContrast || this.toolbarExpanded; }

  @Computed
  get readerPrimaryPost(): Post | undefined { return this.posts.find((post: Post): boolean => post.postNumber === 1); }

  @Computed
  get readerSurfaceWidth(): number { return this.readerToolsVisible ? Math.min(460, Math.max(0, this.readerBarWidth - 32)) : 52; }

  @Monitor('showPicture')
  pictureVisibilityChanged(): void {
    const visible: boolean = this.showPicture;
    if (!visible) {
      setTimeout((): void => {
        if (!this.showPicture && !this.hidden) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: this.pictureScrollOffset, animation: false });
        }
      }, 30);
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      void window.getLastWindow(context).then((main: window.Window): void => {
        if (this.showPicture !== visible) { return; }
        const background: string = visible ? '#FF000000' : '#00000000';
        const foreground: string = visible ? '#FFFFFFFF' :
          '#' + (context.resourceManager.getColorSync($r('app.color.text_primary').id) >>> 0).toString(16).padStart(8, '0');
        void main.setWindowSystemBarProperties({ statusBarColor: background, navigationBarColor: background,
          statusBarContentColor: foreground, navigationBarContentColor: foreground }).catch(() => {});
      }).catch(() => {});
    } catch { /* Viewing remains available without system bar customization. */ }
  }

  @Monitor('treeView')
  treeViewChanged(): void { this.rebuild(); }

  @Monitor('postNumber', 'reloadSignal', 'loading', 'writeBusy')
  targetNumberChanged(): void {
    if (this.entered && !this.hidden) {
      if (this.loading || this.writeBusy) { return; }
      const refresh: boolean = this.reloadSignal !== this.handledReloadSignal;
      if (!refresh && this.postNumber === this.lastInputNumber) { return; }
      this.lastInputNumber = this.postNumber;
      if (refresh) {
        this.handledReloadSignal = this.reloadSignal;
        void this.reload(this.postNumber);
      } else { this.jump(this.postNumber); }
    }
  }

  @Monitor('session.revision')
  accountChanged(): void {
    this.resetReadingIdentity();
    this.quoteRequest?.cancel(); this.quoteRequest = undefined; this.showFlag = false; this.flagTarget = undefined;
    this.showHistory = false; this.historyTarget = undefined;
    this.preserveRequestedFloor = false; this.viewportAnchorNumber = 0;
    this.resetReaderControls();
    this.pendingVisibleReload = 0;
    this.writeRequest?.cancel();
    this.writeRequest = undefined;
    this.writeBusy = false;
    this.generation++;
    this.posts = [];
    this.topic = undefined;
    this.topicCategory = undefined;
    if ((this.session.user?.id || 0) !== this.reactionEmojiOwnerId ||
      forumApi.getSessionGeneration() !== this.reactionEmojiGeneration) {
      this.reactionEmojiUrls = new Map<string, string>();
    }
    this.pictureScrollOffset = 0;
    this.showPicture = false;
    this.pictureUrl = '';
    this.pictureUrls = [];
    this.pictureInitialIndex = 0;
    this.showJump = false;
    this.topicOwnerId = 0;
    this.error = '';
    this.loading = false;
    this.refreshing = false;
    this.rebuild();
    if (!this.hidden && this.entered) { this.reload(this.currentNumber); }
  }

  private signedIn(): boolean {
    if (this.session.user === undefined) { this.onLogin(); return false; }
    if (this.topicOwnerId !== this.session.user.id) {
      this.error = '登录状态已变化，请刷新话题后继续操作。';
      return false;
    }
    return true;
  }

  private startWrite(): RequestCancellation {
    const request: RequestCancellation = new RequestCancellation();
    this.writeRequest = request;
    return request;
  }

  private endWrite(request: RequestCancellation): void {
    if (this.writeRequest !== request) { return; }
    this.writeRequest = undefined;
    const number: number = this.pendingVisibleReload;
    this.pendingVisibleReload = 0;
    this.writeBusy = false;
    // Returning while a mutation is in flight needs one read of server truth.
    // Repeating a toggle would undo the successful action, so only reload here.
    if (number > 0 && !this.hidden) { void this.reload(number); }
  }

  @Computed
  get stream(): number[] { return this.topic?.postStream.stream || []; }

  @Computed
  get previousIds(): number[] {
    return this.stream.slice(0, this.sliceStart).filter((id: number): boolean => !this.consumed.includes(id));
  }

  @Computed
  get nextIds(): number[] {
    return this.stream.slice(this.sliceEnd + 1).filter((id: number): boolean => !this.consumed.includes(id));
  }

  @Computed
  get topicEnded(): boolean {
    return canShowTopicEnd(this.topic !== undefined, this.posts.length, this.nextIds.length,
      this.loading, this.error.length > 0);
  }

  @Computed
  get replyLabel(): string {
    return this.topic?.archived ? '帖子已归档' : this.topic?.closed ? '帖子已关闭' :
      this.session.user === undefined ? '登录后参与讨论' : this.topic?.canReply ? '回复话题' : '暂无回复权限';
  }

  @Computed
  get replyEnabled(): boolean {
    return !this.writeBusy && this.topic !== undefined && !this.topic.closed && !this.topic.archived &&
      (this.session.user === undefined || this.topic.canReply);
  }

  private dismissEndFeedback(animated: boolean = false): void {
    if (this.endHintTimer !== 0) { clearTimeout(this.endHintTimer); this.endHintTimer = 0; }
    this.endPullDistance = 0;
    if (animated && !this.appearance.reduceMotion && this.endFeedbackProgress > 0) {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.95), onFinish: (): void => {
        if (this.endFeedbackProgress === 0) { this.endFeedbackVisible = false; }
      } }, (): void => {
        this.endFeedbackProgress = 0;
      });
    } else { this.endFeedbackProgress = 0; this.endFeedbackVisible = false; }
  }

  private resetReaderControls(): void {
    this.dismissEndFeedback();
    this.scrollPolicy.reset();
    this.toolbarExpanded = true;
  }

  private readScroll(offset: number, state: ScrollState, source: ScrollSource): void {
    const blocked: boolean = this.hidden || this.showPicture || this.showJump || this.readerCovered || this.showTopicOptions ||
      this.sharingPanelOpen || this.showFlag || this.showHistory || this.loading || this.refreshing;
    const userDriven: boolean = source === ScrollSource.DRAG || source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT;
    if (userDriven && Number.isFinite(offset) && offset !== 0 && !blocked) {
      this.preserveRequestedFloor = false;
      this.applyViewportReadingAnchor();
    }
    if (userDriven) { this.readTracker?.recordInteraction(Date.now()); }
    // contentStartOffset makes the native list's origin negative, including the overlay title.
    const readingOffset: number = this.scroller.currentOffset().yOffset + this.topInset + 56;
    const expanded: boolean | undefined = this.scrollPolicy.update(offset, userDriven,
      readingOffset <= 1, blocked || this.appearance.reduceMotion || this.appearance.highContrast || this.appearance.immersiveTopics === false);
    if (expanded !== undefined) { this.toolbarExpanded = expanded; }
    if (blocked || !this.topicEnded) { this.dismissEndFeedback(); return; }
    // Reaching the last item, programmatic jumps and spring rebound are not a new pull.
    if (source !== ScrollSource.DRAG || state !== ScrollState.Scroll) { return; }
    if (this.scroller.isAtEnd() && offset > 0) {
      if (this.endHintTimer !== 0) { clearTimeout(this.endHintTimer); this.endHintTimer = 0; }
      this.endPullDistance = Math.min(64, this.endPullDistance + offset);
      this.endFeedbackVisible = true;
      this.endFeedbackProgress = this.appearance.reduceMotion ? 1 : endPullProgress(this.endPullDistance);
    } else if (offset < 0 && this.endFeedbackProgress > 0) { this.dismissEndFeedback(true); }
  }

  private settleReaderScroll(): void {
    this.scrollPolicy.reset();
    if (this.endFeedbackProgress <= 0 || this.hidden || this.showPicture || !this.topicEnded) { return; }
    if (this.appearance.reduceMotion) { this.endFeedbackProgress = 1; }
    else {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.86) }, (): void => {
        this.endFeedbackProgress = 1;
      });
    }
    if (this.endHintTimer !== 0) { clearTimeout(this.endHintTimer); }
    this.endHintTimer = setTimeout((): void => { this.dismissEndFeedback(true); }, 3200);
  }

  private backToTopicTop(): void {
    if (this.loading || this.writeBusy) { return; }
    this.resetReaderControls();
    // Tail pagination may retain the first post but omit its following floors.
    if (this.sliceStart > 0) { this.jump(1); }
    else {
      this.currentNumber = 1;
      this.preserveRequestedFloor = true;
      this.highlightedId = 0;
      this.pendingNumber = 0;
      if (this.appearance.reduceMotion) { this.scroller.scrollEdge(Edge.Top); }
      else { this.scroller.scrollEdge(Edge.Top, { velocity: 1200 }); }
    }
  }

  private openFloorNavigation(): void {
    this.dismissEndFeedback();
    this.jumpInput = this.currentNumber.toString();
    this.showJump = true;
  }

  private toggleReaderTools(): void {
    this.showJump = false;
    this.toolbarExpanded = !this.toolbarExpanded;
    this.scrollPolicy.reset();
  }

  private bookmarkPrimaryPost(): void {
    const post: Post | undefined = this.readerPrimaryPost;
    if (post !== undefined) { void this.bookmark(post); }
  }

  private rebuild(): void {
    this.viewportAnchorNumber = 0;
    this.rows = topicTreeRows(this.posts, this.expanded, this.collapsed, this.treeView);
    const present: Set<number> = new Set<number>(this.rows.map((row: TopicTreeRow): number => row.post.postNumber));
    this.visibleReadPosts.forEach((number: number): void => {
      if (!present.has(number)) {
        this.readTracker?.setPostVisible(number, false, Date.now()); this.visibleReadPosts.delete(number);
      }
    });
    this.source.update(this.rows);
    if (this.pendingNumber > 0) {
      setTimeout((): void => { this.locatePending(); }, 30);
    }
  }

  private mergePosts(posts: Post[]): void {
    const byId: Map<number, Post> = new Map<number, Post>();
    this.posts.forEach((post: Post): void => { byId.set(post.id, post); });
    posts.forEach((post: Post): void => {
      const previous: Post | undefined = byId.get(post.id);
      if (post.bookmarked === undefined && post.bookmarkId === undefined && previous !== undefined) {
        post.bookmarked = previous.bookmarked;
        post.bookmarkId = previous.bookmarkId;
      }
      if (post.canViewEditHistory === undefined && post.version === undefined && previous !== undefined) {
        post.canViewEditHistory = previous.canViewEditHistory; post.version = previous.version;
      }
      if (post.displayName === undefined && previous !== undefined) { post.displayName = previous.displayName; }
      byId.set(post.id, post);
    });
    this.posts = Array.from(byId.values()).sort((left: Post, right: Post): number => left.postNumber - right.postNumber);
    this.rebuild();
  }

  private reveal(number: number): void {
    let post: Post | undefined = this.posts.find((item: Post): boolean => item.postNumber === number);
    const ancestors: number[] = [];
    while (post !== undefined) {
      const parent: Post | undefined = this.posts.find((item: Post): boolean => item.postNumber === parentNumber(post as Post));
      if (parent === undefined || parent.postNumber >= post.postNumber || ancestors.includes(parent.id)) { break; }
      ancestors.push(parent.id);
      post = parent;
    }
    this.expanded = Array.from(new Set<number>(this.expanded.concat(ancestors)));
    this.collapsed = this.collapsed.filter((id: number): boolean => !ancestors.includes(id));
    this.pendingNumber = number;
    this.rebuild();
  }

  private locatePending(): void {
    if (this.hidden || this.pendingNumber <= 0) { return; }
    const index: number = this.rows.findIndex((row: TopicTreeRow): boolean => row.post.postNumber === this.pendingNumber);
    if (index >= 0) {
      const firstPost: boolean = this.pendingNumber === 1;
      this.currentNumber = this.pendingNumber;
      this.preserveRequestedFloor = true;
      this.highlightedId = this.rows[index].post.id;
      this.pendingNumber = 0;
      this.scroller.scrollToIndex(firstPost ? 0 : index + 2, false, ScrollAlign.START);
    }
  }

  private viewportReadingAnchorChanged(centerIndex: number): void {
    // The native center is a viewport position, not a floor number. The two
    // leading ListItems are status/previous-page controls; rows can be threaded.
    if (!Number.isInteger(centerIndex) || centerIndex < 2 || centerIndex >= this.rows.length + 2) { return; }
    this.viewportAnchorNumber = this.rows[centerIndex - 2].post.postNumber;
    this.applyViewportReadingAnchor();
  }

  private applyViewportReadingAnchor(): void {
    if (this.preserveRequestedFloor || this.pendingNumber > 0 || this.hidden || this.loading || this.showPicture ||
      this.readerCovered || this.showJump || this.showTopicOptions || this.showFlag || this.showHistory || this.sharingPanelOpen) { return; }
    if (this.viewportAnchorNumber > 0 && this.rows.some((row: TopicTreeRow): boolean =>
      row.post.postNumber === this.viewportAnchorNumber)) { this.currentNumber = this.viewportAnchorNumber; }
  }

  private async reload(number: number = 1): Promise<void> {
    if (this.hidden) { return; }
    if (this.writeBusy) { this.pendingVisibleReload = number; this.refreshing = false; return; }
    if (this.loading) { this.refreshing = false; return; }
    this.pendingVisibleReload = 0;
    this.resetReaderControls();
    const request: number = ++this.generation;
    const owner: number = this.session.user?.id || 0;
    this.loading = true;
    this.error = '';
    try {
      const detail: TopicDetail = await forumApi.fetchTopic(this.topicId, number);
      if (request !== this.generation || this.hidden || (this.session.user?.id || 0) !== owner) { return; }
      this.topic = detail;
      this.topicCategory = undefined;
      void this.loadTopicCategory(detail.categoryId, request, owner);
      void this.loadReactionEmojis(request, owner);
      this.topicOwnerId = owner;
      this.posts = detail.postStream.posts;
      this.consumed = detail.postStream.posts.map((post: Post): number => post.id);
      const positions: number[] = detail.postStream.posts.filter((post: Post): boolean => number <= 1 || post.postNumber !== 1)
        .map((post: Post): number => detail.postStream.stream.indexOf(post.id)).filter((index: number): boolean => index >= 0);
      this.sliceStart = positions.length > 0 ? Math.min(...positions) : 0;
      this.sliceEnd = positions.length > 0 ? Math.max(...positions) : -1;
      this.expanded = [];
      this.collapsed = [];
      this.completedReplies = [];
      if (detail.postStream.stream.length > 0 && !this.consumed.includes(detail.postStream.stream[0])) {
        const original: Post[] = await forumApi.fetchPosts(this.topicId, [detail.postStream.stream[0]]);
        if (request !== this.generation || this.hidden) { return; }
        this.consumed = this.consumed.concat([detail.postStream.stream[0]]);
        this.mergePosts(original);
      }
      this.reveal(number);
      if (this.posts.length > 0 && !this.posts.some((post: Post): boolean => post.postNumber === number)) {
        this.error = `第 ${number} 楼未包含在返回内容中，可能已删除或无权访问。`;
      }
    } catch (error) {
      if (request === this.generation && !this.hidden) { this.error = failureMessage(error); }
    } finally {
      if (request === this.generation) { this.loading = false; this.refreshing = false; }
      this.rebuild();
    }
  }

  private async loadTopicCategory(categoryId: number, request: number, owner: number): Promise<void> {
    if (!(categoryId > 0)) { return; }
    try {
      const cached: Category | undefined = flattenCategories(forumApi.cachedCategories())
        .find((category: Category): boolean => category.id === categoryId);
      const category: Category | undefined = cached || flattenCategories(await forumApi.fetchCategories())
        .find((item: Category): boolean => item.id === categoryId);
      if (request !== this.generation || this.hidden || (this.session.user?.id || 0) !== owner ||
        this.topic?.categoryId !== categoryId) { return; }
      this.topicCategory = category;
    } catch {
      // Category metadata is optional; a failed lookup must not hide the readable topic.
    }
  }

  private async loadReactionEmojis(request: number, owner: number): Promise<void> {
    const generation: number = forumApi.getSessionGeneration();
    try {
      const urls: Map<string, string> = await forumApi.emojiUrls();
      if (request !== this.generation || this.hidden || (this.session.user?.id || 0) !== owner ||
        forumApi.getSessionGeneration() !== generation) { return; }
      this.reactionEmojiOwnerId = owner;
      this.reactionEmojiGeneration = generation;
      this.reactionEmojiUrls = urls;
    } catch { /* Reaction counts and actions remain available while the catalog is unavailable. */ }
  }

  private async loadSlice(previous: boolean): Promise<void> {
    if (this.loading || this.writeBusy || this.error.length > 0) { return; }
    const ids: number[] = previous ? this.previousIds.slice(-20) : this.nextIds.slice(0, 20);
    if (ids.length === 0) { return; }
    const request: number = this.generation;
    const anchor: number = this.currentNumber;
    this.loading = true;
    try {
      const result: Post[] = await forumApi.fetchPosts(this.topicId, ids);
      if (request !== this.generation || this.hidden) { return; }
      this.consumed = Array.from(new Set<number>(this.consumed.concat(ids)));
      if (previous) { this.sliceStart = this.stream.indexOf(ids[0]); this.pendingNumber = anchor; }
      else { this.sliceEnd = this.stream.indexOf(ids[ids.length - 1]); }
      this.mergePosts(result);
    } catch (error) {
      if (request === this.generation && !this.hidden) { this.error = failureMessage(error); }
    } finally {
      if (request === this.generation) { this.loading = false; }
    }
  }

  private jump(number: number): void {
    if (!Number.isInteger(number) || number <= 0 || this.loading) { return; }
    this.resetReaderControls();
    this.showJump = false;
    if (number === 1 && this.sliceStart > 0) { this.reload(1); }
    else if (this.posts.some((post: Post): boolean => post.postNumber === number)) { this.reveal(number); }
    else { this.reload(number); }
  }

  private async tail(): Promise<void> {
    if (this.loading || this.writeBusy || this.stream.length === 0) { return; }
    this.resetReaderControls();
    this.loading = true;
    this.error = '';
    const request: number = this.generation;
    const ids: number[] = this.stream.slice(-20);
    try {
      const result: Post[] = await forumApi.fetchPosts(this.topicId, ids);
      if (request !== this.generation || this.hidden) { return; }
      const root: Post | undefined = this.posts.find((post: Post): boolean => post.postNumber === 1);
      this.posts = root === undefined ? [] : [root];
      this.sliceStart = Math.max(0, this.stream.length - 20);
      this.sliceEnd = this.stream.length - 1;
      this.consumed = ids.concat(root === undefined ? [] : [root.id]);
      this.mergePosts(result);
      const last: Post | undefined = result.slice().sort((left: Post, right: Post): number => right.postNumber - left.postNumber)[0];
      if (last !== undefined) { this.reveal(last.postNumber); }
    } catch (error) {
      if (request === this.generation && !this.hidden) { this.error = failureMessage(error); }
    } finally {
      if (request === this.generation) { this.loading = false; }
    }
  }

  private async expandReplies(row: TopicTreeRow): Promise<void> {
    this.collapsed = this.collapsed.filter((id: number): boolean => id !== row.rootId);
    this.expanded = Array.from(new Set<number>(this.expanded.concat([row.rootId])));
    this.rebuild();
    const ids: number[] = row.unloadedIds.filter((id: number): boolean => !this.completedReplies.includes(id));
    for (const id of ids) {
      if (this.loadingReplies.includes(id) || this.hidden) { continue; }
      this.loadingReplies = this.loadingReplies.concat([id]);
      try {
        let after: number = 0;
        let more: boolean = true;
        while (more && !this.hidden) {
          const request: number = this.generation;
          const replies: Post[] = await forumApi.fetchReplies(id, after);
          if (request !== this.generation || this.hidden) { return; }
          this.mergePosts(replies);
          const next: number = replies.length === 0 ? after : Math.max(...replies.map((post: Post): number => post.postNumber));
          more = replies.length > 0 && next > after;
          after = next;
        }
        this.completedReplies = Array.from(new Set<number>(this.completedReplies.concat([id])));
      } catch (error) { this.error = failureMessage(error); }
      finally { this.loadingReplies = this.loadingReplies.filter((item: number): boolean => item !== id); }
    }
    this.rebuild();
  }

  private async quotePost(post: Post): Promise<void> {
    if (!this.signedIn() || !this.topic?.canReply || this.writeBusy || this.hidden) { return; }
    this.quoteRequest?.cancel();
    const cancellation: RequestCancellation = new RequestCancellation();
    this.quoteRequest = cancellation;
    const owner: number = this.session.user?.id || 0;
    const request: number = this.generation;
    try {
      const raw: string = post.raw || await forumApi.fetchPostRaw(post.id, cancellation);
      if (this.quoteRequest !== cancellation || cancellation.isCancelled || request !== this.generation || this.hidden ||
        (this.session.user?.id || 0) !== owner) { return; }
      if (!raw.trim()) { throw new Error('原帖没有可引用的正文。'); }
      const author: string = post.username.replace(/["\r\n,\[\]]/g, '');
      this.onQuote(this.topicId, post.postNumber,
        `[quote="${author}, post:${post.postNumber}, topic:${this.topicId}"]\n${raw}\n[/quote]\n\n`);
    } catch (error) {
      if (this.quoteRequest === cancellation && !cancellation.isCancelled && !this.hidden && request === this.generation) {
        this.getUIContext().getPromptAction().showToast({ message: failureMessage(error) });
      }
    } finally { if (this.quoteRequest === cancellation) { this.quoteRequest = undefined; } }
  }

  private async copyLink(post: Post): Promise<void> {
    if (this.hidden) { return; }
    const request: number = this.generation;
    try {
      await copyPostLink(this.topicId, post.postNumber);
      if (request === this.generation && !this.hidden) {
        this.getUIContext().getPromptAction().showToast({ message: '楼层链接已复制' });
      }
    } catch {
      if (request === this.generation && !this.hidden) {
        this.getUIContext().getPromptAction().showToast({ message: '复制链接未完成，请重试。' });
      }
    }
  }

  private async sharePost(post: Post, anchorId: string = ''): Promise<void> {
    if (this.hidden) { return; }
    const request: number = this.generation;
    this.sharingPanelOpen = true; this.syncReadingContext();
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await sharePostLink(context, this.topicId, post.postNumber, this.topic?.title || 'LINUX DO',
        anchorId || `post_more_${post.id}`, (): void => {
          if (request === this.generation) { this.sharingPanelOpen = false; this.syncReadingContext(); }
        });
    } catch {
      this.sharingPanelOpen = false; this.syncReadingContext();
      if (request === this.generation && !this.hidden) {
        this.getUIContext().getPromptAction().showToast({ message: '暂时无法打开分享面板，可以复制楼层链接。' });
      }
    }
  }

  private async bookmark(post: Post): Promise<void> {
    if (!this.signedIn() || this.writeBusy) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      let bookmarkId: number = 0;
      if (post.bookmarked) {
        if (!Number.isSafeInteger(post.bookmarkId) || (post.bookmarkId ?? 0) <= 0) {
          throw new Error('收藏信息不完整，请刷新帖子后再试。');
        }
        await forumApi.deleteBookmark(post.bookmarkId ?? 0, cancellation);
      } else {
        bookmarkId = await forumApi.createPostBookmark(post.id, cancellation);
      }
      if (request !== this.generation || this.hidden || cancellation.isCancelled) { return; }
      this.mergePosts([postWithBookmark(post, bookmarkId)]);
      this.getUIContext().getPromptAction().showToast({ message: bookmarkId > 0 ? '已收藏' : '已取消收藏' });
    } catch (error) {
      if (request === this.generation && !this.hidden && !cancellation.isCancelled &&
        !(error instanceof ForumApiError && error.kind === ForumErrorKind.Cancelled)) {
        this.error = failureMessage(error);
        this.getUIContext().getPromptAction().showToast({ message: this.error });
      }
    } finally { this.endWrite(cancellation); }
  }

  private async react(post: Post, reaction: string): Promise<void> {
    if (!this.signedIn() || this.writeBusy || post.yours || (post.currentUserReaction !== undefined && !post.currentUserReaction.canUndo)) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      const result: Post = await forumApi.toggleReaction(post.id, reaction, cancellation);
      if (request !== this.generation || this.hidden || cancellation.isCancelled) { return; }
      this.mergePosts([result]);
      const message: string = result.currentUserReaction === undefined ? '已取消回应' :
        (result.currentUserReaction.id === 'heart' ? '已喜欢' : '已添加回应');
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
    catch (error) {
      if (request === this.generation && !this.hidden && !cancellation.isCancelled &&
        !(error instanceof ForumApiError && error.kind === ForumErrorKind.Cancelled)) {
        this.error = failureMessage(error);
        this.getUIContext().getPromptAction().showToast({ message: this.error });
      }
    }
    finally { this.endWrite(cancellation); }
  }

  private async solution(post: Post): Promise<void> {
    if (!this.signedIn() || this.writeBusy || !(post.canAcceptAnswer || post.canUnacceptAnswer)) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      await forumApi.setSolution(post.id, !post.acceptedAnswer, cancellation);
      if (request !== this.generation) { return; }
      const affected: number[] = this.posts.filter((item: Post): boolean => item.id === post.id || item.acceptedAnswer)
        .map((item: Post): number => item.id);
      const result: Post[] = await forumApi.fetchPosts(this.topicId, affected.slice(0, 20), cancellation);
      if (request === this.generation) { this.mergePosts(result); }
    } catch (error) { if (request === this.generation) { this.error = failureMessage(error); } }
    finally { this.endWrite(cancellation); }
  }

  private async boost(post: Post, raw: string): Promise<boolean> {
    if (!this.signedIn() || this.writeBusy || !post.canBoost || !measureBoost(raw).submittable) { return false; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      const created: Boost = await forumApi.createBoost(post.id, raw, cancellation);
      if (request === this.generation) { this.mergePosts([postWithBoosts(post, post.boosts.concat([created]))]); }
      return true;
    } catch (error) { if (request === this.generation) { this.error = failureMessage(error); } return false; }
    finally { this.endWrite(cancellation); }
  }

  private confirmDelete(post: Post): void {
    if (!this.signedIn() || this.writeBusy || !post.canDelete) { return; }
    this.getUIContext().showAlertDialog({
      systemMaterial: materialFor(this.appearance), backgroundColor: $r('app.color.surface'),
      title: post.postNumber === 1 ? '删除整个话题？' : `删除第 ${post.postNumber} 楼？`,
      message: post.postNumber === 1 ? '这将删除话题及其回复。请确认后继续。' : '删除后其他用户将无法阅读这条内容。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.deletePost(post); } }
    });
  }

  private async deletePost(post: Post): Promise<void> {
    if (!this.signedIn() || this.writeBusy || !post.canDelete) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      await forumApi.deletePost(post.id, cancellation);
      if (request !== this.generation) { return; }
      this.posts = this.posts.filter((item: Post): boolean => item.id !== post.id);
      this.rebuild();
      if (post.postNumber === 1) { this.posts = []; this.topic = undefined; this.error = '话题已删除。'; this.rebuild(); }
    } catch (error) { if (request === this.generation) { this.error = failureMessage(error); } }
    finally { this.endWrite(cancellation); }
  }

  private confirmDeleteBoost(post: Post, boost: Boost): void {
    if (!this.signedIn() || this.writeBusy || !boost.canDelete) { return; }
    this.getUIContext().showAlertDialog({ title: '删除这条简评？', message: '确认后将删除这条简评。',
      systemMaterial: materialFor(this.appearance), backgroundColor: $r('app.color.surface'),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.deleteBoost(post, boost); } } });
  }

  private async deleteBoost(post: Post, boost: Boost): Promise<void> {
    if (!this.signedIn() || this.writeBusy || !boost.canDelete) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      await forumApi.deleteBoost(boost.id, cancellation);
      if (request === this.generation) {
        this.mergePosts([postWithBoosts(post, post.boosts.filter((item: Boost): boolean => item.id !== boost.id))]);
      }
    } catch (error) { if (request === this.generation) { this.error = failureMessage(error); } }
    finally { this.endWrite(cancellation); }
  }

  private openLink(raw: string): void {
    const url: string = postContentUrl(raw);
    if (!url.startsWith('https://')) { this.error = '仅支持打开安全的 HTTPS 链接。'; return; }
    const internal: TopicLink | undefined = parseTopicLink(url);
    if (internal !== undefined) { this.onOpenTopic(internal.id, internal.number); return; }
    if (isPostAttachmentUrl(url)) { this.saveAttachment(url); return; }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch((): void => {
      this.error = '无法打开链接，请确认设备已安装浏览器。';
    });
  }

  private picture(url: string, post?: Post): void {
    const safe: string = postContentUrl(url);
    if (!safe.startsWith('https://')) { this.error = '无法查看不安全的图片地址。'; return; }
    const urls: string[] = post === undefined ? [] : parsePostContent(post.cooked)
      .filter((block: PostBlock): boolean => block.kind === 'image' && block.url.startsWith('https://'))
      .map((block: PostBlock): string => block.url);
    this.pictureUrls = Array.from(new Set<string>(urls.concat([safe])));
    this.pictureInitialIndex = this.pictureUrls.indexOf(safe);
    this.pictureUrl = safe;
    this.pictureScrollOffset = this.scroller.currentOffset().yOffset;
    this.dismissEndFeedback();
    this.scrollPolicy.reset();
    this.showPicture = true;
  }

  private async mediaHeaders(url: string): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    const agent: string = forumApi.getUserAgent();
    if (agent) { headers['User-Agent'] = agent; }
    if (/^https:\/\/linux\.do(?:\/|$)/i.test(url)) {
      const cookies: string = await webview.WebCookieManager.fetchCookie(url, false, true);
      if (cookies) { headers['Cookie'] = cookies; }
    }
    return headers;
  }

  private async saveAttachment(url: string): Promise<void> {
    if (this.savingAttachment || !url.startsWith('https://')) { return; }
    this.savingAttachment = true;
    const owner: number = this.session.user?.id || 0;
    let request: http.HttpRequest | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      let name: string = decodeURIComponent(url.split('?')[0].split('#')[0].split('/').pop() || 'attachment');
      name = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').slice(0, 120) || 'attachment';
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) { return; }
      if ((this.session.user?.id || 0) !== owner) { throw new Error('账号已变化，本次保存已停止。'); }
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000, readTimeout: 30000, maxLimit: 50 * 1024 * 1024,
        header: await this.mediaHeaders(url), maxRedirects: 0
      });
      if (response.responseCode >= 300 && response.responseCode < 400) {
        throw new Error('附件地址发生跳转，请在浏览器中打开后下载。');
      }
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        throw new Error('附件下载失败，请确认登录状态或稍后重试。');
      }
      const bytes: ArrayBuffer = response.result;
      if ((this.session.user?.id || 0) !== owner) { throw new Error('账号已变化，本次保存已停止。'); }
      if (bytes.byteLength > 50 * 1024 * 1024) { throw new Error('附件超过本次下载的 50 MB 上限。'); }
      file = await fileIo.open(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const count: number = await fileIo.write(file.fd, bytes);
      if (count !== bytes.byteLength) { throw new Error('附件未完整保存，请重新下载。'); }
      this.getUIContext().getPromptAction().showToast({ message: '附件已保存到所选位置' });
    } catch (error) { this.getUIContext().getPromptAction().showToast({ message: failureMessage(error) }); }
    finally {
      if (file !== undefined) { try { await fileIo.close(file); } catch {} }
      try { request?.destroy(); } catch {}
      this.savingAttachment = false;
    }
  }

  private async savePicture(): Promise<void> {
    if (this.savingPicture || !this.pictureUrl.startsWith('https://')) { return; }
    this.savingPicture = true;
    const owner: number = this.session.user?.id || 0;
    const url: string = this.pictureUrl;
    const request: http.HttpRequest = http.createHttp();
    let file: fileIo.File | undefined = undefined;
    let helper: photoAccessHelper.PhotoAccessHelper | undefined = undefined;
    try {
      const headers: Record<string, string> = await this.mediaHeaders(url);
      if ((this.session.user?.id || 0) !== owner || !this.showPicture) { throw new Error('本次保存已停止。'); }
      headers['Accept'] = 'image/*';
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000, readTimeout: 20000, maxLimit: 20 * 1024 * 1024,
        header: headers, maxRedirects: 0
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) { throw new Error('图片下载失败。'); }
      if ((this.session.user?.id || 0) !== owner || !this.showPicture) { throw new Error('本次保存已停止。'); }
      const bytes: ArrayBuffer = response.result;
      const signature: Uint8Array = new Uint8Array(bytes);
      let extension: string = '';
      if (signature[0] === 0xff && signature[1] === 0xd8) { extension = 'jpg'; }
      else if (signature[0] === 0x89 && signature[1] === 0x50 && signature[2] === 0x4e) { extension = 'png'; }
      else if (signature[0] === 0x47 && signature[1] === 0x49 && signature[2] === 0x46) { extension = 'gif'; }
      else if (signature[0] === 0x52 && signature[1] === 0x49 && signature[8] === 0x57 && signature[9] === 0x45) { extension = 'webp'; }
      if (!extension) { throw new Error('此图片格式暂不支持保存到相册。'); }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, extension);
      file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE);
      const count: number = await fileIo.write(file.fd, bytes);
      if (count !== bytes.byteLength) { throw new Error('图片未完整保存，请重新保存。'); }
      this.getUIContext().getPromptAction().showToast({ message: '已保存到相册' });
    } catch (error) { this.getUIContext().getPromptAction().showToast({ message: failureMessage(error) }); }
    finally {
      if (file !== undefined) { try { await fileIo.close(file); } catch {} }
      if (helper !== undefined) { try { await helper.release(); } catch {} }
      try { request.destroy(); } catch {}
      this.savingPicture = false;
    }
  }

  @Builder
  jumpSheet() {
    Column({ space: 18 }) {
      Text('跳转到楼层').fontSize(23).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      TextInput({ text: this.jumpInput, placeholder: '输入楼层号' }).type(InputType.Number).height(52).id('jump_input')
        .onChange((value: string): void => { this.jumpInput = value; })
      Button('前往', { type: ButtonType.Capsule }).width('100%').height(48).id('jump_go')
        .enabled(Number(this.jumpInput) > 0 && Number.isInteger(Number(this.jumpInput)) && !this.loading)
        .onClick(() => { this.jump(Number(this.jumpInput)); })
      Row({ space: 12 }) {
        Button('首楼', { buttonStyle: ButtonStyleMode.TEXTUAL }).layoutWeight(1).onClick(() => { this.jump(1); })
        Button('最新回复', { buttonStyle: ButtonStyleMode.TEXTUAL }).layoutWeight(1)
          .onClick(() => { this.showJump = false; this.tail(); })
      }.width('100%')
      Button('回到话题顶部', { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').height(44).id('topic_back_to_top')
        .enabled(!this.loading && !this.writeBusy && this.posts.length > 0)
        .onClick((): void => { this.showJump = false; this.backToTopicTop(); })
      if (!this.appearance.reduceMotion && !this.appearance.highContrast) {
        Button('收起阅读工具栏', { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').height(44)
          .id('topic_toolbar_collapse').onClick((): void => { this.toggleReaderTools(); })
      }
    }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
  }


  @Builder
  historySheet() {
    PostRevisionSheet({ post: this.historyTarget, session: this.session, foreground: this.foreground,
      reduceMotion: this.appearance.reduceMotion,
      onClose: (): void => { this.showHistory = false; this.historyTarget = undefined; }, onLogin: this.onLogin,
      onOpenUser: (username: string): void => { this.showHistory = false; this.onOpenUser(username); },
      onOpenLink: (url: string): void => { this.showHistory = false; this.openLink(url); },
      onPicture: (url: string): void => { this.showHistory = false; this.picture(url); } })
  }

  @Builder
  flagSheet() {
    FlagPostSheet({ post: this.flagTarget, onClose: (): void => { this.showFlag = false; this.flagTarget = undefined; },
      onSubmitted: (updated: Post): void => { this.mergePosts([updated]); } })
  }

  @Builder
  topicOptionsSheet() {
    Scroll() {
      Column({ space: 16 }) {
        Text('话题操作').fontSize(23).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        TopicNotificationOptions({ topicId: this.topicId,
          currentLevel: this.topic?.details.notificationLevel ?? -1, onLogin: this.onLogin,
          onChanged: (level: number): void => {
            if (this.topic !== undefined) { this.topic.details.notificationLevel = level; }
          } })
        Divider().color($r('app.color.divider'))
        Button(this.readerPrimaryPost?.bookmarked ? '取消收藏话题首楼' : '收藏话题首楼',
          { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').height(48)
          .enabled(!this.loading && !this.writeBusy && this.readerPrimaryPost !== undefined)
          .onClick((): void => { this.bookmarkPrimaryPost(); })
        Button('复制话题链接', { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').height(48)
          .enabled(this.readerPrimaryPost !== undefined)
          .onClick((): void => { const post: Post | undefined = this.readerPrimaryPost; if (post !== undefined) { void this.copyLink(post); } })
        Button('分享话题', { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').height(48)
          .enabled(this.readerPrimaryPost !== undefined)
          .onClick((): void => { const post: Post | undefined = this.readerPrimaryPost; if (post !== undefined) { void this.sharePost(post, 'topic_more'); } })
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }

  @Builder
  readerTitle() {
    Column({ space: 2 }) {
      Text(this.topic?.title || '话题').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).maxLines(1).id('topic_title_author')
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.layoutWeight(1).height(56).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .id('topic_header_return_top').accessibilityDescription('双击标题区域回到话题顶部')
      .gesture(TapGesture({ count: 2 }).onAction((): void => { this.backToTopicTop(); }))
  }

  @LocalBuilder
  readerBackControl() {
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_primary')])
    }.width(48).height(48).accessibilityText('返回')
      .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
      .id('__NavdestinationField__BackButton__Back__').onClick(this.onBack)
  }

  @LocalBuilder
  readerHeaderActions() {
      Row({ space: 0 }) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(19).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).accessibilityText('在话题中搜索').id('topic_search')
          .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
          .onClick((): void => { this.onSearchTopic(this.topicId); })
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Image($r('app.media.ic_more_horiz')).width(23).height(23)
            .fillColor($r('app.color.text_primary')).accessibilityLevel('no')
        }.width(44).height(44).accessibilityText('话题更多操作').id('topic_more')
          .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
          .onClick((): void => { this.showTopicOptions = true; })
      }.width(88).height(44)
  }

  @Builder
  readerHeader() {
    Row({ space: 8 }) {
      ReaderGlassSurface({ appearance: this.appearance, content: this.readerBackControl,
        radiusVp: 24, lightId: 'reader_back_touch_light' }).width(48).height(48)
      this.readerTitle()
      ReaderGlassSurface({ appearance: this.appearance, content: this.readerHeaderActions,
        radiusVp: 22, lightId: 'reader_header_touch_light' }).width(88).height(44)
        .bindSheet($$this.showTopicOptions, this.topicOptionsSheet, { height: SheetSize.MEDIUM, dragBar: true,
          backgroundColor: $r('app.color.surface'), onDisappear: (): void => { this.showTopicOptions = false; } })
    }.width('100%').height(this.topInset + 56).padding({ left: 8, right: 8, top: this.topInset })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .backgroundColor(this.appearance.effectLevel === 0 || this.appearance.highContrast ?
        $r('app.color.surface') : $r('app.color.reading_glass_tint'))
      .backgroundEffect(readerBackdropFor(this.appearance))
      .id('topic_immersive_header').zIndex(3)
      .bindSheet($$this.showHistory, this.historySheet, { height: SheetSize.LARGE, dragBar: true,
        backgroundColor: $r('app.color.surface'), onDisappear: (): void => { this.showHistory = false; this.historyTarget = undefined; } })
  }

  @LocalBuilder
  readerUnifiedControls() {
    if (this.readerToolsVisible) {
      Row({ space: 0 }) {
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.message')).fontSize(20).fontColor([$r('app.color.text_primary')])
            Text(this.replyEnabled ? '回复话题' : this.replyLabel).fontSize(14).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          }.width('100%').justifyContent(FlexAlign.Start).padding({ left: 16, right: 4 })
        }.height(52).layoutWeight(1).id('topic_reply_entry')
          .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
          .enabled(this.replyEnabled).accessibilityText(this.replyLabel)
          .onClick((): void => { if (this.signedIn()) { this.onCompose(this.topicId, 0, 0); } })
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph(this.readerPrimaryPost?.bookmarked ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'))
            .fontSize(21).fontColor([this.readerPrimaryPost?.bookmarked ? $r('app.color.accent') : $r('app.color.text_primary')])
        }.width(48).height(52).id('topic_bookmark')
          .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
          .enabled(!this.loading && !this.writeBusy && this.readerPrimaryPost !== undefined)
          .accessibilityText(this.readerPrimaryPost?.bookmarked ? '取消收藏话题首楼' : '收藏话题首楼')
          .onClick((): void => { this.bookmarkPrimaryPost(); })
        Divider().vertical(true).height(22).color($r('app.color.divider')).margin({ left: 4, right: 4 })
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 7 }) {
            Column({ space: 5 }) {
              Text(`${this.visibleFloor} / ${this.totalFloors}`).fontSize(12).fontColor($r('app.color.text_primary'))
                .maxLines(1).minFontSize(10).maxFontSize(12).id('topic_floor_progress')
              Progress({ value: this.visibleFloor, total: this.totalFloors, type: ProgressType.Linear })
                .width(46).height(3).color($r('app.color.accent')).backgroundColor($r('app.color.divider'))
                .accessibilityLevel('no')
            }
            SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(18).fontColor([$r('app.color.text_primary')])
          }.width('100%').justifyContent(FlexAlign.Center)
        }.width(90).height(52).id('topic_jump')
          .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
          .enabled(this.topic !== undefined)
          .accessibilityText(`楼层导航，当前第 ${this.visibleFloor} 楼，共 ${this.totalFloors} 楼`)
          .onClick((): void => { this.openFloorNavigation(); })
      }.width('100%').height(52)
    } else {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.message')).fontSize(23).fontColor([$r('app.color.accent')])
      }.width(52).height(52).id('topic_toolbar_toggle').accessibilityText('展开阅读工具栏')
        .backgroundColor(Color.Transparent).stateEffect(false).systemMaterial(uiMaterial.Material.empty)
        .onClick((): void => { this.toggleReaderTools(); })
    }
  }

  @Builder
  readerToolbar() {
    Row() {
      ReaderGlassSurface({ appearance: this.appearance, content: this.readerUnifiedControls, nativeBar: true, radiusVp: 26 })
        .height(52).width(this.readerSurfaceWidth).id('topic_reader_toolbar')
        .animation({ duration: this.appearance.reduceMotion ? 0 : 220, curve: Curve.EaseInOut })
        .bindSheet($$this.showJump, this.jumpSheet, { height: SheetSize.MEDIUM, dragBar: true,
          backgroundColor: $r('app.color.surface'), onDisappear: (): void => { this.showJump = false; } })
    }.width('100%').height(76).padding({ left: 16, right: 16 })
      .justifyContent(this.readerToolsVisible ? FlexAlign.Center : FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_old: Area, next: Area): void => {
        const width: number = Number(next.width);
        if (width > 0 && Number.isFinite(width) && Math.abs(width - this.readerBarWidth) > 0.5) {
          this.readerBarWidth = width;
        }
      })
  }

  @Builder
  topicEndFeedback() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_up_2')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        .translate({ y: this.appearance.reduceMotion ? 0 : 4 * (1 - this.endFeedbackProgress) })
      Text('已到话题末尾').fontSize(13).fontColor($r('app.color.text_secondary'))
      Button('回到顶部', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(13)
        .fontColor($r('app.color.accent')).id('topic_end_back_to_top')
        .enabled(!this.loading && !this.writeBusy).onClick((): void => { this.backToTopicTop(); })
    }.padding({ left: 16, right: 6 }).height(52).borderRadius(28)
      .backgroundColor($r('app.color.surface')).systemMaterial(materialFor(this.appearance))
      .id('topic_end_feedback').opacity(this.endFeedbackProgress)
      .scale({ x: this.appearance.reduceMotion ? 1 : 0.94 + 0.06 * this.endFeedbackProgress,
        y: this.appearance.reduceMotion ? 1 : 0.94 + 0.06 * this.endFeedbackProgress })
      .translate({ y: this.appearance.reduceMotion ? 0 : 20 * (1 - this.endFeedbackProgress) })
      .visibility(this.endFeedbackVisible ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(this.endFeedbackProgress > 0.1 ? HitTestMode.Default : HitTestMode.None)
      .accessibilityLevel(this.endFeedbackProgress > 0.1 ? 'yes' : 'no-hide-descendants')
  }

  @LocalBuilder
  readerBarContent() {
    Column() {
      this.readerToolbar()
    }.width('100%').height(80 + this.bottomInset)
      .justifyContent(FlexAlign.End).padding({ bottom: 4 + this.bottomInset })
      .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ scroller: this.scroller, space: 0 }) {
            ListItem() {
              if (this.error) {
                Column({ space: 8 }) {
                  Text(this.error).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
                  Row({ space: 10 }) {
                    Button('重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40)
                      .enabled(!this.loading && !this.writeBusy).onClick(() => { this.reload(this.currentNumber); })
                    Button('登录 / 完成验证', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).onClick(this.onLogin)
                  }.width('100%')
                }.padding(16).backgroundColor($r('app.color.selected_background')).width('100%')
              } else if (this.topic === undefined) {
                Text(this.loading ? '正在打开帖子…' : '帖子').fontSize(18).fontColor($r('app.color.text_secondary')).padding(16)
              } else { Blank().height(1) }
            }

            ListItem() {
              if (this.previousIds.length > 0) {
                Button(`加载之前的楼层（${this.previousIds.length}）`, { buttonStyle: ButtonStyleMode.TEXTUAL })
                  .height(44).width('100%').enabled(!this.loading).onClick(() => { this.error = ''; this.loadSlice(true); })
              } else { Blank().height(1) }
            }
            LazyForEach(this.source, (row: ObservedTopicTreeRow) => {
              ListItem() {
                Column({ space: 0 }) {
                  TopicPostCard({ post: row.post, compact: row.depth > 0, topicTitle: this.topic?.title || '',
                    category: this.topicCategory, tags: this.topic?.tags || [], replyCount: this.topicReplyCount,
                    authorUsername: this.originalAuthor, topicState: this.topic?.archived ? '已归档' : this.topic?.closed ? '已关闭' : '', canReply: this.topic?.canReply || false,
                    busy: this.writeBusy, highlighted: row.post.postNumber > 1 && row.post.id === this.highlightedId,
                    reactions: this.topic?.validReactions || [], reactionEmojiUrls: this.reactionEmojiUrls,
                    reduceMotion: this.appearance.reduceMotion,
                    loggedIn: this.session.user !== undefined, onLogin: this.onLogin,
                    onReply: (post: Post): void => { this.onCompose(this.topicId, post.postNumber, 0); },
                    onEdit: (post: Post): void => { if (post.canEdit) { this.onCompose(this.topicId, post.postNumber, post.id); } },
                    onDelete: (post: Post): void => { this.confirmDelete(post); },
                    onReact: (post: Post, reaction: string): void => { this.react(post, reaction); },
                    onSolution: (post: Post): void => { this.solution(post); },
                    onBookmark: (post: Post): void => { void this.bookmark(post); },
                    onCopyLink: (post: Post): void => { void this.copyLink(post); },
                    onShare: (post: Post): void => { void this.sharePost(post); },
                    onQuote: (post: Post): void => { void this.quotePost(post); },
                    onFlag: (post: Post): void => { this.flagTarget = post; this.showFlag = true; },
                    onHistory: (post: Post): void => {
                      if (canReadPostHistory(post)) { this.historyTarget = post; this.showHistory = true; }
                    },
                    onBoost: (post: Post, raw: string): Promise<boolean> => this.boost(post, raw),
                    onDeleteBoost: (post: Post, boost: Boost): void => { this.confirmDeleteBoost(post, boost); },
                    onOpenLink: (url: string): void => { this.openLink(url); },
                    onOpenUser: this.onOpenUser,
                    onPicture: (url: string): void => { this.picture(url, row.post); },
                    onJump: (number: number): void => { this.jump(number); } })
                  if (this.treeView && row.lastInGroup && row.totalReplies > 0) {
                    Row() {
                      Button(this.loadingReplies.some((id: number): boolean => row.unloadedIds.includes(id)) ? '正在加载回复…' :
                        row.shownReplies >= row.loadedReplies && row.unloadedIds.every((id: number): boolean => this.completedReplies.includes(id)) ?
                          `已显示 ${row.shownReplies} 条楼中楼回复` : `共 ${row.totalReplies} 条回复 · 展开`,
                        { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).height(44).layoutWeight(1)
                        .enabled(!this.loadingReplies.some((id: number): boolean => row.unloadedIds.includes(id)))
                        .onClick(() => { this.expandReplies(row); })
                      if (row.shownReplies > 0) {
                        Button('收起', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(13)
                          .onClick(() => {
                            this.collapsed = Array.from(new Set<number>(this.collapsed.concat([row.rootId])));
                            this.expanded = this.expanded.filter((id: number): boolean => id !== row.rootId);
                            this.rebuild();
                          })
                      }
                    }.width('100%').padding({ left: 8, right: 8 }).backgroundColor($r('app.color.surface')).borderRadius(6)
                  }
                  if (row.post.postNumber === 1) {
                    Row({ space: 8 }) {
                      Text(`全部回复 · ${this.topicReplyCount}`).fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary')).layoutWeight(1)
                      Button(this.treeView ? '楼中楼' : '按楼层', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(12)
                        .fontColor($r('app.color.accent')).onClick(() => { this.appearance.treeView = !this.treeView; })
                    }.width('100%').padding({ left: 16, right: 12, top: 4 }).backgroundColor($r('app.color.page_background'))
                  } else if (row.depth === 0 && row.lastInGroup) {
                    Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
                  }
                }.width('100%').padding({ left: row.depth > 0 ? 48 : 0, right: row.depth > 0 ? 16 : 0 })
                  .backgroundColor($r('app.color.surface'))
              }.onVisibleAreaChange([0, 0.01], (visible: boolean, ratio: number): void => {
                this.postVisibilityChanged(row.post.postNumber, visible && ratio > 0);
              }).onDisAppear((): void => { this.postVisibilityChanged(row.post.postNumber, false); })
            }, (row: TopicTreeRow): string => `${row.post.id}-${row.rootId}-${row.depth}`)
            ListItem() {
              Column({ space: 12 }) {
                if (this.loading) { LoadingProgress().width(32).height(32) }
                else if (this.posts.length === 0 && !this.error) {
                  Text('暂无可阅读的内容').fontColor($r('app.color.text_secondary')).padding(24)
                } else if (this.nextIds.length > 0) {
                  Button('加载更多回复', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44)
                    .onClick(() => { this.error = ''; this.loadSlice(false); })
                } else { Blank().height(1) }
              }.width('100%')
            }
          }.width('100%').height('100%')
            .contentStartOffset(this.topInset + 56).contentEndOffset(84 + this.bottomInset).cachedCount(3)
            .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true, effectEdge: EffectEdge.END })
            .onWillScroll((offset: number, state: ScrollState, source: ScrollSource): void => {
              this.readScroll(offset, state, source);
            })
            .onScrollStop((): void => { this.settleReaderScroll(); })
            .onScrollIndex((_start: number, _end: number, center: number): void => {
              this.viewportReadingAnchorChanged(center);
            })
            .onReachEnd(() => { if (this.entered && !this.showPicture && !this.error) { this.loadSlice(false); } })
        }.height('100%')
          .layoutWeight(1).onRefreshing(() => { this.reload(this.currentNumber); })
      }.width('100%').height('100%')
      if (!this.showPicture) {
        this.readerHeader()
        Column() {
          this.topicEndFeedback()
        }.width('100%').height('100%').justifyContent(FlexAlign.End)
          .padding({ bottom: 90 + this.bottomInset }).zIndex(2)
          .hitTestBehavior(HitTestMode.Transparent)
        MaterialBarHost({ barHeight: 80 + this.bottomInset, barContent: this.readerBarContent })
          .width('100%').height('100%').zIndex(2)
          .hitTestBehavior(HitTestMode.Transparent)
      }
      if (this.showPicture) {
        ForumImageViewer({ urls: this.pictureUrls, initialIndex: this.pictureInitialIndex,
          topInset: this.topInset, bottomInset: this.bottomInset,
          ownerId: this.session.user?.id || 0, saving: this.savingPicture,
          onClose: (): void => { this.showPicture = false; },
          onSave: (url: string): void => { this.pictureUrl = url; void this.savePicture(); },
          onIndexChange: (index: number): void => { this.pictureUrl = this.pictureUrls[index] || ''; } })
          .width('100%').height('100%').zIndex(10)
      }
      }.width('100%').height('100%')
    }.hideTitleBar(true).backgroundColor($r('app.color.surface'))
      .bindSheet($$this.showFlag, this.flagSheet, { height: SheetSize.MEDIUM, dragBar: true,
        backgroundColor: $r('app.color.surface'), onDisappear: (): void => { this.showFlag = false; this.flagTarget = undefined; } })
      .onBackPressed((): boolean => { if (this.showPicture) { this.showPicture = false; return true; } return false; })
      .onShown(() => {
        this.hidden = false;
        this.loading = false;
        const number: number = !this.entered || this.postNumber !== this.lastInputNumber ||
          this.reloadSignal !== this.handledReloadSignal ? this.postNumber : this.currentNumber;
        this.lastInputNumber = this.postNumber;
        this.handledReloadSignal = this.reloadSignal;
        this.entered = true;
        this.sharingPanelOpen = false;
        this.startReadingTimer();
        this.reload(number);
      })
      .onHidden(() => { this.dismissEndFeedback(); this.scrollPolicy.reset(); this.showPicture = false;
        this.quoteRequest?.cancel(); this.quoteRequest = undefined; this.showFlag = false; this.flagTarget = undefined;
        this.showHistory = false; this.historyTarget = undefined;
        this.hidden = true; this.syncReadingContext(); void this.flushReadingTimings(true);
        if (this.readTimer !== 0) { clearInterval(this.readTimer); this.readTimer = 0; }
        this.sharingPanelOpen = false; this.showTopicOptions = false;
        this.pendingVisibleReload = 0; this.generation++; this.loading = false; this.refreshing = false; })
  }
}
