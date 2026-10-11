import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { Boost, Post, Reaction, TopicDetail, measureBoost } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation } from '../services/ForumApi';
import { materialFor } from '../services/MaterialPolicy';
import { RichPostContent, postContentUrl, parsePostContent, PostBlock } from '../components/RichPostContent';
import { NativeForumImage } from '../components/NativeForumImage';
import { ForumImageViewer } from '../components/ForumImageViewer';
import { relativeTime } from '../services/ForumPresentation';

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
  return { id: post.id, username: post.username, avatarTemplate: post.avatarTemplate, avatarUrl: post.avatarUrl,
    postNumber: post.postNumber, createdAt: post.createdAt, cooked: post.cooked, topicId: post.topicId, blurb: post.blurb,
    replyToPostNumber: post.replyToPostNumber, replyCount: post.replyCount, boosts: boosts, reactions: post.reactions,
    currentUserReaction: post.currentUserReaction, yours: post.yours, canBoost: post.canBoost,
    canAcceptAnswer: post.canAcceptAnswer, canUnacceptAnswer: post.canUnacceptAnswer,
    acceptedAnswer: post.acceptedAnswer, canEdit: post.canEdit, canDelete: post.canDelete, raw: post.raw };
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
  @Param authorUsername: string = '';
  @Param topicState: string = '';
  @Param canReply: boolean = false;
  @Param busy: boolean = false;
  @Param highlighted: boolean = false;
  @Param reactions: string[] = [];
  @Param reduceMotion: boolean = false;
  @Param loggedIn: boolean = false;
  @Event onReply: (post: Post) => void = (_post: Post): void => {};
  @Event onEdit: (post: Post) => void = (_post: Post): void => {};
  @Event onDelete: (post: Post) => void = (_post: Post): void => {};
  @Event onReact: (post: Post, reaction: string) => void = (_post: Post, _reaction: string): void => {};
  @Event onSolution: (post: Post) => void = (_post: Post): void => {};
  @Event onBoost: (post: Post, raw: string) => Promise<boolean> =
    async (_post: Post, _raw: string): Promise<boolean> => false;
  @Event onDeleteBoost: (post: Post, boost: Boost) => void = (_post: Post, _boost: Boost): void => {};
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Event onJump: (number: number) => void = (_number: number): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local boosting: boolean = false;
  @Local boostDraft: string = '';
  @Local expandedBoosts: boolean = false;

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
  get heartCount(): number {
    return this.post.reactions.find((reaction: Reaction): boolean => reaction.id === 'heart')?.count || 0;
  }

  @Computed
  get hasMoreActions(): boolean {
    return this.post.canEdit || this.post.canDelete || this.post.canBoost || this.post.canAcceptAnswer || this.post.canUnacceptAnswer;
  }

  @Builder
  reactionMenu() {
    Menu() {
      ForEach(this.reactionChoices, (reaction: string) => {
        MenuItem({ content: reaction === 'heart' ? '♡ 喜欢' : reaction })
          .enabled(this.canReact).onClick(() => { this.onReact(this.post, reaction); })
      }, (reaction: string): string => reaction)
    }
  }

  @Builder
  manageMenu() {
    Menu() {
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
    Column({ space: this.compact ? 6 : 10 }) {
      Row({ space: 8 }) {
        if (this.post.avatarUrl) {
          NativeForumImage({ url: this.post.avatarUrl, fit: ImageFit.Cover,
            ownerId: forumSession.user?.id || 0, accessibleLabel: `${this.post.username} 的头像` })
            .width(this.compact ? 22 : 32).height(this.compact ? 22 : 32)
            .borderRadius(19)
        } else {
          Text(this.post.username.slice(0, 1).toUpperCase()).fontSize(17).fontWeight(FontWeight.Medium)
            .width(this.compact ? 22 : 32).height(this.compact ? 22 : 32).textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.selected_background')).borderRadius(19)
        }
        Column({ space: 3 }) {
          Row({ space: 5 }) {
            Text(this.post.username).fontSize(this.compact ? 13 : 14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(1)
            if (this.isAuthor) {
              Text('楼主').fontSize(10).fontColor($r('app.color.accent')).padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .backgroundColor($r('app.color.selected_background')).borderRadius(4)
            }
          }

        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(`#${this.post.postNumber}`).fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.hasMoreActions) {
          Button('···', { type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }).width(40).height(40)
            .fontSize(20).fontColor($r('app.color.text_secondary')).accessibilityText(`管理第 ${this.post.postNumber} 楼`)
            .bindMenu(this.manageMenu)
        }
      }.width('100%')
      if (this.post.replyToPostNumber > 0) {
        Text(`回复 #${this.post.replyToPostNumber}`).fontSize(12).fontColor($r('app.color.accent'))
          .onClick(() => { this.onJump(this.post.replyToPostNumber); })
      }
      if (this.post.postNumber === 1 && this.topicTitle.length > 0) {
        Text(this.topicTitle).fontSize(24).lineHeight(32).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).width('100%').id('topic_main_title')
      }
      if (this.post.postNumber === 1 && this.topicState.length > 0) {
        Text(this.topicState).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      RichPostContent({ cooked: this.post.cooked, compact: this.compact, reduceMotion: this.reduceMotion,
        onOpenLink: this.onOpenLink, onPicture: this.onPicture })
      if (this.post.reactions.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.post.reactions.filter((reaction: Reaction): boolean => reaction.count > 0 && reaction.id !== 'heart'), (reaction: Reaction) => {
            Text(`${reaction.id === 'heart' ? '♥' : reaction.id} ${reaction.count}`).fontSize(12)
              .fontColor($r('app.color.text_secondary')).padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor($r('app.color.selected_background')).borderRadius(14).margin({ right: 6, bottom: 4 })
          }, (reaction: Reaction): string => reaction.id)
        }.width('100%')
      }
      Row({ space: 4 }) {
        Text(dateLabel(this.post.createdAt)).fontSize(11).fontColor($r('app.color.text_secondary'))
        if (this.post.acceptedAnswer) {
          Text('✓ 已解决').fontSize(11).fontColor($r('app.color.accent'))
        }
        Blank()
        Button(`${this.post.currentUserReaction?.id === 'heart' ? '♥' : '♡'} ${this.heartCount > 0 ? this.heartCount : '喜欢'}`,
          { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).fontSize(12).fontColor($r('app.color.text_secondary'))
          .enabled(this.canReact).onClick(() => { this.onReact(this.post, 'heart'); })
          .bindContextMenu(this.reactionMenu, ResponseType.LongPress)
          .accessibilityText('点按喜欢，长按选择回应表情')
        if (this.canReply || (!this.loggedIn && this.topicState.length === 0)) {
          Button('回复', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).fontSize(12)
            .fontColor($r('app.color.accent')).enabled(!this.busy)
            .onClick(() => { if (this.loggedIn) { this.onReply(this.post); } else { this.onLogin(); } })
        }
      }.width('100%')
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
      if (this.post.boosts.length > 0) {
        Column({ space: 8 }) {
          ForEach(this.expandedBoosts ? this.post.boosts : this.post.boosts.slice(0, 3), (boost: Boost) => {
            Row({ space: 6 }) {
              Text(boost.user?.username || '用户').fontSize(12).fontColor($r('app.color.text_secondary'))
              RichPostContent({ cooked: boost.cooked, compact: true, reduceMotion: this.reduceMotion,
                onOpenLink: this.onOpenLink, onPicture: this.onPicture }).layoutWeight(1)
              if (boost.canDelete) {
                Button('删除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(12).height(40).enabled(!this.busy)
                  .onClick(() => { this.onDeleteBoost(this.post, boost); })
              }
            }.padding({ left: 8, right: 8, top: 4, bottom: 4 })
          }, (boost: Boost): string => boost.id.toString())
          if (this.post.boosts.length > 3) {
            Button(this.expandedBoosts ? '收起简评' : `更多简评（${this.post.boosts.length - 3}）`,
              { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(12)
              .onClick(() => { this.expandedBoosts = !this.expandedBoosts; })
          }
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding(this.compact ? 10 : 16)
      .backgroundColor(this.highlighted ? $r('app.color.selected_background') :
        this.compact ? $r('app.color.page_background') : $r('app.color.surface'))
      .borderRadius(this.compact ? 6 : 0).id(`post_${this.post.postNumber}`)
  }
}

@ComponentV2
export struct TopicPage {
  @Param topicId: number = 0;
  @Param postNumber: number = 1;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param treeView: boolean = true;
  @Param session: ForumSession = forumSession;
  @Event onCompose: (topicId: number, replyTo: number, postId: number) => void =
    (_topicId: number, _replyTo: number, _postId: number): void => {};
  @Event onOpenTopic: (id: number, postNumber: number) => void = (_id: number, _number: number): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local topic: TopicDetail | undefined = undefined;
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
  @Local jumpInput: string = '';
  @Local showPicture: boolean = false;
  @Local pictureUrl: string = '';
  @Local savingPicture: boolean = false;
  @Local savingAttachment: boolean = false;
  @Local pictureUrls: string[] = [];
  @Local pictureInitialIndex: number = 0;
  private pictureScrollOffset: number = 0;
  private pendingNumber: number = 0;
  private generation: number = 0;
  private entered: boolean = false;
  private lastInputNumber: number = 1;
  private hidden: boolean = false;
  private topicOwnerId: number = 0;
  private writeRequest: RequestCancellation | undefined = undefined;
  private readonly source: TopicRowsSource = new TopicRowsSource();
  private readonly scroller: Scroller = new Scroller();

  @Computed
  get originalAuthor(): string { return this.posts.find((post: Post): boolean => post.postNumber === 1)?.username || ''; }

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
        const background: string = visible ? '#FF000000' :
          '#' + (context.resourceManager.getColorSync($r('app.color.page_background').id) >>> 0).toString(16).padStart(8, '0');
        const foreground: string = visible ? '#FFFFFFFF' :
          '#' + (context.resourceManager.getColorSync($r('app.color.text_primary').id) >>> 0).toString(16).padStart(8, '0');
        void main.setWindowSystemBarProperties({ statusBarColor: background, navigationBarColor: background,
          statusBarContentColor: foreground, navigationBarContentColor: foreground }).catch(() => {});
      }).catch(() => {});
    } catch { /* Viewing remains available without system bar customization. */ }
  }

  @Monitor('treeView')
  treeViewChanged(): void { this.rebuild(); }

  @Monitor('postNumber')
  targetNumberChanged(): void {
    if (this.entered && !this.hidden) {
      this.lastInputNumber = this.postNumber;
      this.jump(this.postNumber);
    }
  }

  @Monitor('session.revision')
  accountChanged(): void {
    this.writeRequest?.cancel();
    this.writeRequest = undefined;
    this.writeBusy = false;
    this.generation++;
    this.posts = [];
    this.topic = undefined;
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
    if (this.writeRequest === request) { this.writeRequest = undefined; this.writeBusy = false; }
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

  private rebuild(): void {
    this.rows = topicTreeRows(this.posts, this.expanded, this.collapsed, this.treeView);
    this.source.update(this.rows);
    if (this.pendingNumber > 0) {
      setTimeout((): void => { this.locatePending(); }, 30);
    }
  }

  private mergePosts(posts: Post[]): void {
    const byId: Map<number, Post> = new Map<number, Post>();
    this.posts.forEach((post: Post): void => { byId.set(post.id, post); });
    posts.forEach((post: Post): void => { byId.set(post.id, post); });
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
      this.highlightedId = this.rows[index].post.id;
      this.pendingNumber = 0;
      this.scroller.scrollToIndex(firstPost ? 0 : index + 2, false, ScrollAlign.START);
    }
  }

  private async reload(number: number = 1): Promise<void> {
    if (this.loading || this.writeBusy) { this.refreshing = false; return; }
    const request: number = ++this.generation;
    const owner: number = this.session.user?.id || 0;
    this.loading = true;
    this.error = '';
    try {
      const detail: TopicDetail = await forumApi.fetchTopic(this.topicId, number);
      if (request !== this.generation || this.hidden || (this.session.user?.id || 0) !== owner) { return; }
      this.topic = detail;
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
    this.showJump = false;
    if (number === 1 && this.sliceStart > 0) { this.reload(1); }
    else if (this.posts.some((post: Post): boolean => post.postNumber === number)) { this.reveal(number); }
    else { this.reload(number); }
  }

  private async tail(): Promise<void> {
    if (this.loading || this.writeBusy || this.stream.length === 0) { return; }
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

  private async react(post: Post, reaction: string): Promise<void> {
    if (!this.signedIn() || this.writeBusy || post.yours || (post.currentUserReaction !== undefined && !post.currentUserReaction.canUndo)) { return; }
    this.writeBusy = true;
    this.error = '';
    const request: number = this.generation;
    const cancellation: RequestCancellation = this.startWrite();
    try {
      const result: Post = await forumApi.toggleReaction(post.id, reaction, cancellation);
      if (request === this.generation) { this.mergePosts([result]); }
    }
    catch (error) { if (request === this.generation) { this.error = failureMessage(error); } }
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
    }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.error) {
          Column({ space: 8 }) {
            Text(this.error).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
            Row({ space: 10 }) {
              Button('重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40)
                .enabled(!this.loading && !this.writeBusy).onClick(() => { this.reload(this.currentNumber); })
              Button('登录 / 完成验证', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).onClick(this.onLogin)
            }.width('100%')
          }.padding(16).backgroundColor($r('app.color.selected_background')).width('100%')
        }
        Refresh({ refreshing: $$this.refreshing }) {
          List({ scroller: this.scroller, space: 0 }) {
            ListItem() {
              if (this.topic === undefined) {
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
                    authorUsername: this.originalAuthor, topicState: this.topic?.archived ? '已归档' : this.topic?.closed ? '已关闭' : '', canReply: this.topic?.canReply || false,
                    busy: this.writeBusy, highlighted: row.post.postNumber > 1 && row.post.id === this.highlightedId,
                    reactions: this.topic?.validReactions || [], reduceMotion: this.appearance.reduceMotion,
                    loggedIn: this.session.user !== undefined, onLogin: this.onLogin,
                    onReply: (post: Post): void => { this.onCompose(this.topicId, post.postNumber, 0); },
                    onEdit: (post: Post): void => { if (post.canEdit) { this.onCompose(this.topicId, post.postNumber, post.id); } },
                    onDelete: (post: Post): void => { this.confirmDelete(post); },
                    onReact: (post: Post, reaction: string): void => { this.react(post, reaction); },
                    onSolution: (post: Post): void => { this.solution(post); },
                    onBoost: (post: Post, raw: string): Promise<boolean> => this.boost(post, raw),
                    onDeleteBoost: (post: Post, boost: Boost): void => { this.confirmDeleteBoost(post, boost); },
                    onOpenLink: (url: string): void => { this.openLink(url); },
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
                    }.width('100%').padding({ left: 8, right: 8 }).backgroundColor($r('app.color.page_background')).borderRadius(6)
                  }
                  if (row.post.postNumber === 1) {
                    Row({ space: 8 }) {
                      Text(`全部回复 · ${Math.max(0, this.stream.length - 1)}`).fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary')).layoutWeight(1)
                      Button(this.treeView ? '楼中楼' : '按楼层', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(12)
                        .fontColor($r('app.color.accent')).onClick(() => { this.appearance.treeView = !this.treeView; })
                    }.width('100%').padding({ left: 16, right: 12, top: 4 }).backgroundColor($r('app.color.page_background'))
                  } else if (row.depth === 0 && row.lastInGroup) {
                    Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
                  }
                }.width('100%').padding({ left: row.depth > 0 ? 48 : 0, right: row.depth > 0 ? 16 : 0 })
                  .backgroundColor($r('app.color.surface'))
              }
            }, (row: TopicTreeRow): string => `${row.post.id}-${row.rootId}-${row.depth}`)
            ListItem() {
              Column({ space: 12 }) {
                if (this.loading) { LoadingProgress().width(32).height(32) }
                else if (this.posts.length === 0 && !this.error) {
                  Text('暂无可阅读的内容').fontColor($r('app.color.text_secondary')).padding(24)
                } else if (this.nextIds.length > 0) {
                  Button('加载更多回复', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44)
                    .onClick(() => { this.error = ''; this.loadSlice(false); })
                } else if (this.posts.length > 0) {
                  Text('已到话题末尾').fontSize(13).fontColor($r('app.color.text_secondary')).padding(24)
                }
              }.width('100%')
            }
          }.width('100%').height('100%').contentEndOffset(12).cachedCount(3)
            .scrollBar(BarState.Off)
            .onScrollIndex((_start: number, end: number): void => {
              const row: TopicTreeRow | undefined = this.rows[Math.min(this.rows.length - 1, Math.max(0, end - 2))];
              if (row !== undefined) { this.currentNumber = row.post.postNumber; }
            })
            .onReachEnd(() => { if (this.entered && !this.showPicture && !this.error) { this.loadSlice(false); } })
        }.layoutWeight(1).onRefreshing(() => { this.reload(this.currentNumber); })
        Row({ space: 10 }) {
          Button(this.topic?.archived ? '帖子已归档' : this.topic?.closed ? '帖子已关闭' : this.session.user === undefined ? '登录后参与讨论' : this.topic?.canReply ? '说点什么…' : '暂无回复权限', { type: ButtonType.Capsule })
            .height(44).layoutWeight(1).fontSize(14).fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.page_background')).id('topic_reply_entry')
            .enabled(!this.writeBusy && this.topic !== undefined && !this.topic.closed && !this.topic.archived && (this.session.user === undefined || this.topic.canReply))
            .onClick(() => { if (this.signedIn()) { this.onCompose(this.topicId, 0, 0); } })
          Button(`#${this.currentNumber}`, { buttonStyle: ButtonStyleMode.TEXTUAL })
            .id('topic_jump').height(44).width(68).fontSize(13).fontColor($r('app.color.text_secondary'))
            .accessibilityText(`楼层导航，当前第${this.currentNumber}楼，共${this.stream.length}条内容`)
            .onClick(() => { this.jumpInput = this.currentNumber.toString(); this.showJump = true; })
            .bindSheet(this.showJump, this.jumpSheet, { height: SheetSize.MEDIUM, dragBar: true,
              backgroundColor: $r('app.color.surface'), onDisappear: (): void => { this.showJump = false; } })
        }.width('100%').padding({ left: 14, right: 8, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.surface')).systemMaterial(materialFor(this.appearance))
      }.width('100%').height('100%')
      if (this.showPicture) {
        ForumImageViewer({ urls: this.pictureUrls, initialIndex: this.pictureInitialIndex,
          ownerId: this.session.user?.id || 0, saving: this.savingPicture,
          onClose: (): void => { this.showPicture = false; },
          onSave: (url: string): void => { this.pictureUrl = url; void this.savePicture(); },
          onIndexChange: (index: number): void => { this.pictureUrl = this.pictureUrls[index] || ''; } })
          .width('100%').height('100%').zIndex(10)
      }
      }.width('100%').height('100%')
    }.title('帖子').hideTitleBar(this.showPicture).backgroundColor($r('app.color.page_background'))
      .onBackPressed((): boolean => { if (this.showPicture) { this.showPicture = false; return true; } return false; })
      .onShown(() => {
        this.hidden = false;
        this.loading = false;
        const number: number = !this.entered || this.postNumber !== this.lastInputNumber ? this.postNumber : this.currentNumber;
        this.lastInputNumber = this.postNumber;
        this.entered = true;
        this.reload(number);
      })
      .onHidden(() => { this.showPicture = false; this.hidden = true; this.generation++; this.loading = false; this.refreshing = false; })
  }
}
