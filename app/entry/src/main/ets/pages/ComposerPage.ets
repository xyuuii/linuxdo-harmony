import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { preferences } from '@kit.ArkData';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { Category, Post, TopicCreationResult, TopicDetail, UploadedFile, uploadedFileMarkdown } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation } from '../services/ForumApi';
import { materialFor } from '../services/MaterialPolicy';

interface DraftAttachment { id: string; uri: string; name: string; mime: string; size: number; }
interface NewTopicDraft { version: number; title: string; categoryId: number; tags: string; raw: string; }
interface ComposerTool {
  symbol: Resource;
  label: string;
  id: string;
  enabled: boolean;
  selected: boolean;
  action: () => void;
}

const ATTACHMENT_CAP: number = 4 * 1024 * 1024;
const ALLOWED_EXTENSIONS: string[] = [
  'jpg', 'jpeg', 'png', 'gif', 'heic', 'heif', 'webp', 'avif', 'svg', 'txt', 'pdf', 'doc', 'docx',
  'csv', 'zip', '7z', 'gz', 'xz', 'jxl', 'md'
];
const draftAttachments: Map<string, DraftAttachment[]> = new Map<string, DraftAttachment[]>();

function composerError(error: Object): string {
  return error instanceof Error && error.message ? error.message : '暂时无法完成请求，请稍后重试。';
}

function attachmentMime(name: string): string {
  const extension: string = name.split('.').pop()?.toLowerCase() || '';
  if (extension === 'jpg' || extension === 'jpeg') { return 'image/jpeg'; }
  if (['png', 'gif', 'webp', 'avif', 'heic', 'heif', 'jxl'].includes(extension)) { return `image/${extension}`; }
  if (extension === 'svg') { return 'image/svg+xml'; }
  if (extension === 'pdf') { return 'application/pdf'; }
  if (extension === 'txt' || extension === 'md' || extension === 'csv') { return 'text/plain'; }
  if (extension === 'zip') { return 'application/zip'; }
  return 'application/octet-stream';
}

@ComponentV2
export struct ComposerPage {
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param presentedAsSheet: boolean = false;
  @Param dismissSignal: number = 0;
  @Param topicId: number = 0;
  @Param replyTo: number = 0;
  @Param postId: number = 0;
  @Param creatingTopic: boolean = false;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param session: ForumSession = forumSession;
  @Event onDone: () => void = (): void => {};
  @Event onSubmitted: (postNumber: number) => void = (_number: number): void => {};
  @Event onTopicCreated: (topicId: number, postNumber: number) => void = (_topicId: number, _postNumber: number): void => {};
  @Event onDismissAllowedChange: (allowed: boolean) => void = (_allowed: boolean): void => {};
  @Local draft: string = '';
  @Local initialRaw: string = '';
  @Local topicTitle: string = '';
  @Local newTopicTitle: string = '';
  @Local categoryId: number = 0;
  @Local tagsText: string = '';
  @Local categories: Category[] = [];
  @Local error: string = '';
  @Local loading: boolean = false;
  @Local submitting: boolean = false;
  @Local picking: boolean = false;
  @Local permitted: boolean = false;
  @Local attachments: DraftAttachment[] = [];
  @Local showEmoji: boolean = false;
  @Local saveMessage: string = '';
  private initialized: boolean = false;
  private ownerId: number = 0;
  private draftKey: string = '';
  private store: preferences.Preferences | undefined = undefined;
  private saveTimer: number = -1;
  private prepareGeneration: number = 0;
  private writeRequest: RequestCancellation | undefined = undefined;
  private presentationActive: boolean = false;
  private submissionSucceeded: boolean = false;
  private discardedDraft: boolean = false;
  private draftLoaded: boolean = false;
  private textAreaController: TextAreaController | undefined = undefined;
  private titleController: TextInputController | undefined = undefined;
  private tagsController: TextInputController | undefined = undefined;
  private readonly emojis: string[] = ['😀', '😄', '😊', '👍', '❤️', '🎉', '🤝', '🤔', '🙏', '🚀', '✅', '💡'];

  aboutToAppear(): void {
    if (this.textAreaController === undefined) { this.textAreaController = new TextAreaController(); }
    if (this.titleController === undefined) { this.titleController = new TextInputController(); }
    if (this.tagsController === undefined) { this.tagsController = new TextInputController(); }
  }

  @Monitor('dismissSignal')
  dismissRequested(): void {
    if (this.presentedAsSheet && this.presentationActive && this.dismissSignal > 0) { this.requestClose(); }
  }

  @Monitor('picking', 'submitting')
  notifyDismissAvailability(): void {
    if (this.presentationActive) { this.onDismissAllowedChange(!this.picking && !this.submitting); }
  }

  private presentationShown(): void {
    this.presentationActive = true;
    if (!this.initialized) { this.submissionSucceeded = false; this.discardedDraft = false; }
    this.notifyDismissAvailability();
    void this.prepare();
  }

  private presentationHidden(): void {
    this.presentationActive = false;
    if (!this.submitting && !this.submissionSucceeded && !this.discardedDraft) { void this.saveDraft(); }
    if (!this.presentedAsSheet) { return; }
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1; }
    if (!this.submissionSucceeded) {
      this.prepareGeneration++;
      this.writeRequest?.cancel();
      this.writeRequest = undefined;
    }
    this.initialized = false;
    this.loading = false;
    this.permitted = false;
    this.showEmoji = false;
    this.draftLoaded = false;
  }

  private requestClose(): void {
    if (!this.leave()) { this.onDone(); }
  }

  @Monitor('session.revision')
  accountChanged(): void {
    if (this.ownerId > 0 && this.session.user?.id !== this.ownerId) {
      this.prepareGeneration++;
      this.writeRequest?.cancel();
      this.loading = false;
      if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1; }
      if (!this.submissionSucceeded) { void this.saveDraft(); }
      this.draftLoaded = false;
      this.draftKey = '';
      this.store = undefined;
      this.draft = '';
      this.initialRaw = '';
      this.newTopicTitle = '';
      this.categoryId = 0;
      this.tagsText = '';
      this.categories = [];
      this.attachments = [];
      this.permitted = false;
      this.error = '登录账号已变化，本次编辑已停止。若刚才已提交，请返回话题核对结果。';
    }
  }

  @Computed
  get title(): string {
    if (this.creatingTopic) { return '发表话题'; }
    return this.postId > 0 ? `编辑第 ${this.replyTo} 楼` : this.replyTo > 0 ? `回复第 ${this.replyTo} 楼` : '回复话题';
  }

  @Computed
  get canSubmit(): boolean {
    return this.permitted && !this.loading && !this.submitting && !this.picking &&
      this.ownerId > 0 && this.session.user?.id === this.ownerId &&
      (!this.creatingTopic || (this.newTopicTitle.trim().length > 0 && this.selectedCategory() !== undefined &&
        this.topicTags().length >= (this.selectedCategory()?.minimumRequiredTags || 0))) &&
      (this.draft.trim().length > 0 || this.attachments.length > 0);
  }

  private selectedCategory(): Category | undefined {
    return this.categories.find((category: Category): boolean => category.id === this.categoryId);
  }

  private tagPlaceholder(): string {
    const minimum: number = this.selectedCategory()?.minimumRequiredTags || 0;
    return minimum > 0 ? `标签（此分类至少 ${minimum} 个，用逗号分隔）` : '标签（可选，用逗号分隔）';
  }

  private topicTags(): string[] {
    const tags: string[] = [];
    for (const tag of this.tagsText.split(/[,，\s]+/)) {
      const value: string = tag.trim();
      if (value && !tags.includes(value)) { tags.push(value); }
    }
    return tags;
  }

  private validateCategorySelection(): void {
    if (this.categoryId > 0 && this.selectedCategory() === undefined) {
      this.categoryId = 0;
      this.error = '草稿原分类当前不可发帖，请重新选择分类。';
    }
    if (this.categories.length === 0) { this.error = '当前账号没有可发帖的分类，请稍后重新检查权限。'; }
  }

  private restoreTopicDraft(value: string): void {
    if (!value) { return; }
    const saved: NewTopicDraft = JSON.parse(value) as NewTopicDraft;
    if (saved === null || saved.version !== 1 || typeof saved.title !== 'string' ||
      typeof saved.categoryId !== 'number' || typeof saved.tags !== 'string' || typeof saved.raw !== 'string') {
      throw new Error('草稿格式无法读取。');
    }
    this.newTopicTitle = saved.title;
    this.categoryId = saved.categoryId;
    this.tagsText = saved.tags;
    this.draft = saved.raw;
  }

  private async prepare(): Promise<void> {
    if (this.initialized || this.loading) { return; }
    this.initialized = true;
    this.loading = true;
    this.error = '';
    const request: number = ++this.prepareGeneration;
    try {
      const userId: number = this.session.user?.id || 0;
      if (userId <= 0) { throw new Error(this.creatingTopic ? '请登录后再发表话题。' : '请登录后再回复或编辑。'); }
      const key: string = this.creatingTopic ? `draft_topic_${userId}` : `draft_${userId}_${this.topicId}_${this.replyTo}_${this.postId}`;
      const alreadyLoaded: boolean = this.draftLoaded && this.ownerId === userId && this.draftKey === key;
      if (!alreadyLoaded) { this.draftLoaded = false; }
      this.ownerId = userId;
      this.draftKey = key;
      if (this.creatingTopic) {
        const categories: Category[] = await forumApi.fetchCreateTopicCategories();
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        this.categories = categories;
        this.topicTitle = '分享见闻，开启新的讨论';
        this.permitted = categories.length > 0;
      } else {
        const topic: TopicDetail = await forumApi.fetchTopic(this.topicId, this.replyTo || 1);
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        this.topicTitle = topic.title;
        if (this.postId > 0) {
          const posts: Post[] = await forumApi.fetchPosts(this.topicId, [this.postId]);
          if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
          const post: Post | undefined = posts.find((item: Post): boolean => item.id === this.postId);
          if (post === undefined || post.topicId !== this.topicId || !post.canEdit) {
            throw new Error('当前账号没有编辑这条内容的权限。');
          }
          const raw: string = await forumApi.fetchPostRaw(this.postId);
          if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
          this.initialRaw = raw;
          this.permitted = true;
        } else {
          if (!topic.canReply) { throw new Error('该话题当前不开放回复，或当前账号没有回复权限。'); }
          this.permitted = true;
        }
      }
      if (alreadyLoaded) { if (this.creatingTopic) { this.validateCategorySelection(); } return; }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try {
        const store: preferences.Preferences = await preferences.getPreferences(context, { name: 'forum_composer_drafts_v1' });
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        this.store = store;
        const saved: preferences.ValueType = await store.get(this.draftKey, '');
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        if (this.creatingTopic) { this.restoreTopicDraft(typeof saved === 'string' ? saved : ''); }
        else { this.draft = typeof saved === 'string' && saved.length > 0 ? saved : this.initialRaw; }
        this.saveMessage = saved ? '已恢复本机草稿' : '';
      } catch {
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        this.store = undefined;
        this.draft = this.initialRaw;
        this.saveMessage = '当前草稿暂时无法保存到本机';
      }
      if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
      this.attachments = draftAttachments.get(this.draftKey) || [];
      this.draftLoaded = true;
      if (this.creatingTopic) { this.validateCategorySelection(); }
    } catch (error) {
      if (request === this.prepareGeneration) { this.error = composerError(error); this.permitted = false; }
    }
    finally { if (request === this.prepareGeneration) { this.loading = false; } }
  }

  private changeDraft(value: string): void {
    this.draft = value;
    this.scheduleDraftSave();
  }

  private changeTopicTitle(value: string): void {
    this.newTopicTitle = value;
    this.scheduleDraftSave();
  }

  private changeTags(value: string): void {
    this.tagsText = value;
    this.scheduleDraftSave();
  }

  private changeCategory(index: number): void {
    if (index < 0 || index >= this.categories.length) { return; }
    this.categoryId = this.categories[index].id;
    this.error = '';
    this.scheduleDraftSave();
  }

  private scheduleDraftSave(): void {
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); }
    this.saveTimer = setTimeout((): void => { this.saveDraft(); }, 450);
  }

  private async saveDraft(): Promise<void> {
    if (!this.draftLoaded || !this.draftKey || this.store === undefined ||
      this.submissionSucceeded || this.discardedDraft) { return; }
    const key: string = this.draftKey;
    const topicDraft: NewTopicDraft = { version: 1, title: this.newTopicTitle, categoryId: this.categoryId,
      tags: this.tagsText, raw: this.draft };
    const value: string = this.creatingTopic ? JSON.stringify(topicDraft) : this.draft;
    const store: preferences.Preferences = this.store;
    try {
      if (this.creatingTopic && !this.newTopicTitle.trim() && !this.draft.trim() &&
        !this.tagsText.trim() && this.categoryId === 0 && this.attachments.length === 0) {
        await store.delete(key);
        await store.flush();
        if (key === this.draftKey) { this.saveMessage = ''; }
        return;
      }
      await store.put(key, value);
      await store.flush();
      if (key === this.draftKey) { this.saveMessage = '草稿已保存在本机'; }
    } catch { if (key === this.draftKey) { this.saveMessage = '当前草稿暂时无法保存到本机'; } }
  }

  private insert(value: string): void {
    this.changeDraft(`${this.draft}${this.draft.length > 0 ? '\n' : ''}${value}`);
  }

  private toggleEmoji(): void {
    const visible: boolean = !this.showEmoji;
    if (visible) {
      this.titleController?.stopEditing();
      this.tagsController?.stopEditing();
      this.textAreaController?.stopEditing();
    }
    this.showEmoji = visible;
  }

  private async chooseAttachment(image: boolean): Promise<void> {
    if (this.submitting || this.picking || !this.permitted) { return; }
    this.picking = true;
    this.notifyDismissAvailability();
    this.error = '';
    const owner: number = this.ownerId;
    const generation: number = this.prepareGeneration;
    try {
      let uris: string[] = [];
      if (image) {
        const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
        options.maxSelectNumber = 1;
        const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
        const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(options);
        uris = result.photoUris;
      } else {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
        const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
        options.maxSelectNumber = 1;
        uris = await documentPicker.select(options);
      }
      if (uris.length === 0) { return; }
      if (this.session.user?.id !== owner || this.ownerId !== owner ||
        generation !== this.prepareGeneration || !this.permitted) { return; }
      const uri: string = uris[0];
      let file: fileIo.File | undefined = undefined;
      try {
        file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        const stat: fileIo.Stat = await fileIo.stat(file.fd);
        if (this.session.user?.id !== owner || generation !== this.prepareGeneration || !this.permitted) { return; }
        if (stat.size <= 0) { throw new Error('文件为空，无法添加。'); }
        if (stat.size > ATTACHMENT_CAP) { throw new Error('文件超过 4 MB 上限，请先压缩后再选择。'); }
        const decoded: string = decodeURIComponent(uri.split('?')[0]);
        const name: string = decoded.split('/').pop() || `attachment_${Date.now()}`;
        const extension: string = name.split('.').pop()?.toLowerCase() || '';
        if (!ALLOWED_EXTENSIONS.includes(extension)) { throw new Error(`不支持此文件类型 .${extension || '未知'}。`); }
        const selected: DraftAttachment = { id: `${Date.now()}_${this.attachments.length}`, uri: uri,
          name: name, mime: attachmentMime(name), size: stat.size };
        this.attachments = this.attachments.concat([selected]);
        draftAttachments.set(this.draftKey, this.attachments);
      } finally { if (file !== undefined) { await fileIo.close(file); } }
    } catch (error) { this.error = composerError(error); }
    finally { this.picking = false; this.notifyDismissAvailability(); }
  }

  private removeAttachment(id: string): void {
    this.attachments = this.attachments.filter((item: DraftAttachment): boolean => item.id !== id);
    draftAttachments.set(this.draftKey, this.attachments);
  }

  private async attachmentBytes(attachment: DraftAttachment): Promise<ArrayBuffer> {
    const file: fileIo.File = await fileIo.open(attachment.uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      if (stat.size <= 0 || stat.size > ATTACHMENT_CAP) { throw new Error('附件为空或超过 4 MB 上限。'); }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const count: number = await fileIo.read(file.fd, buffer);
      if (count !== stat.size) { throw new Error('未能完整读取附件，请重新选择。'); }
      return buffer;
    } finally { await fileIo.close(file); }
  }

  private async submit(): Promise<void> {
    if (!this.canSubmit) { return; }
    this.submitting = true;
    this.notifyDismissAvailability();
    this.error = '';
    const owner: number = this.ownerId;
    const generation: number = this.prepareGeneration;
    const cancellation: RequestCancellation = new RequestCancellation();
    this.writeRequest = cancellation;
    const ensureOwner = (): void => {
      if (cancellation.isCancelled || this.session.user?.id !== owner || this.ownerId !== owner ||
        generation !== this.prepareGeneration) {
        cancellation.cancel();
        throw new Error('登录账号已变化，本次提交已停止。请返回话题核对结果。');
      }
    };
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1; }
    try {
      // Re-check permissions immediately before sending; they may have changed while drafting.
      ensureOwner();
      if (this.creatingTopic) {
        const categories: Category[] = await forumApi.fetchCreateTopicCategories(cancellation);
        ensureOwner();
        this.categories = categories;
        this.permitted = categories.length > 0;
        if (this.selectedCategory() === undefined) {
          this.categoryId = 0;
          throw new Error('所选分类当前不可发帖，请重新选择分类。');
        }
        const minimumTags: number = this.selectedCategory()?.minimumRequiredTags || 0;
        if (this.topicTags().length < minimumTags) { throw new Error(`所选分类至少需要 ${minimumTags} 个不同标签。`); }
      } else {
        const topic: TopicDetail = await forumApi.fetchTopic(this.topicId, this.replyTo || 1, cancellation);
        ensureOwner();
        if (this.postId > 0) {
          const posts: Post[] = await forumApi.fetchPosts(this.topicId, [this.postId], cancellation);
          ensureOwner();
          if (!posts.some((post: Post): boolean => post.id === this.postId && post.topicId === this.topicId && post.canEdit)) {
            throw new Error('当前账号已无权编辑此内容。');
          }
        } else if (!topic.canReply) { throw new Error('该话题已关闭，或当前账号已无回复权限。'); }
      }
      // Attachments remain local until the user explicitly presses this submit button.
      for (const attachment of this.attachments.slice()) {
        ensureOwner();
        const bytes: ArrayBuffer = await this.attachmentBytes(attachment);
        ensureOwner();
        const uploaded: UploadedFile = await forumApi.uploadFile(attachment.name, attachment.mime, bytes, cancellation);
        ensureOwner();
        this.draft = `${this.draft}\n\n${uploadedFileMarkdown(uploaded)}`.trim();
        this.removeAttachment(attachment.id);
        await this.saveDraft();
        ensureOwner();
      }
      ensureOwner();
      let created: TopicCreationResult | undefined = undefined;
      let submittedPostNumber: number = 0;
      if (this.creatingTopic) {
        created = await forumApi.createTopic(this.newTopicTitle.trim(), this.draft, this.categoryId, this.topicTags(), cancellation);
      } else {
        const post: Post = this.postId > 0 ? await forumApi.updatePost(this.postId, this.draft, cancellation) :
          await forumApi.createPost(this.topicId, this.draft, this.replyTo > 0 ? this.replyTo : undefined, cancellation);
        submittedPostNumber = post.postNumber;
      }
      ensureOwner();
      this.submissionSucceeded = true;
      this.permitted = false;
      // Server success remains success even if local draft cleanup cannot be flushed.
      const completedDraftKey: string = this.draftKey;
      const completedStore: preferences.Preferences | undefined = this.store;
      if (completedStore !== undefined) {
        try { await completedStore.delete(completedDraftKey); await completedStore.flush(); } catch {}
      }
      draftAttachments.delete(completedDraftKey);
      // Local cleanup may outlive the originating account or sheet. Keep the
      // confirmed server result without reviving that presentation or its draft.
      if (cancellation.isCancelled || this.session.user?.id !== owner || this.ownerId !== owner ||
        generation !== this.prepareGeneration || !this.presentationActive) { return; }
      this.draft = '';
      this.initialRaw = '';
      this.newTopicTitle = '';
      this.categoryId = 0;
      this.tagsText = '';
      if (created !== undefined) {
        this.getUIContext().getPromptAction().showToast({ message: created.queued ? '话题已提交，等待审核后显示' : '话题已发表' });
        if (!created.queued) { this.onTopicCreated(created.topicId, created.postNumber); }
      } else {
        this.getUIContext().getPromptAction().showToast({ message: this.postId > 0 ? '修改已保存' : '回复已发表' });
        this.onSubmitted(submittedPostNumber);
      }
      this.onDone();
    } catch (error) {
      if (generation === this.prepareGeneration) {
        this.error = composerError(error);
        await this.saveDraft();
      }
    } finally {
      if (this.writeRequest === cancellation) { this.writeRequest = undefined; }
      this.submitting = false;
      this.notifyDismissAvailability();
    }
  }

  private leave(): boolean {
    if (this.submitting || this.picking) {
      this.getUIContext().getPromptAction().showToast({ message: this.submitting ? '正在提交，请稍候' : '请先完成文件选择' });
      return true;
    }
    if (!this.draftLoaded) { return false; }
    if (this.draft !== this.initialRaw || this.attachments.length > 0 ||
      (this.creatingTopic && (this.newTopicTitle.length > 0 || this.categoryId > 0 || this.tagsText.length > 0))) {
      this.getUIContext().showAlertDialog({ title: '离开编辑器？', message: '可以保留草稿，稍后继续编辑。',
        primaryButton: { value: '保留草稿返回', action: (): void => { this.saveDraft().then((): void => { this.onDone(); }); } },
        secondaryButton: { value: '丢弃草稿', action: (): void => { this.discard(); } } });
      return true;
    }
    return false;
  }

  private async discard(): Promise<void> {
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1; }
    if (this.store !== undefined && this.draftKey) { await this.store.delete(this.draftKey); await this.store.flush(); }
    draftAttachments.delete(this.draftKey);
    this.draft = this.initialRaw;
    this.newTopicTitle = '';
    this.categoryId = 0;
    this.tagsText = '';
    this.attachments = [];
    this.discardedDraft = true;
    this.onDone();
  }

  @Builder
  emojiPalette() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.emojis, (emoji: string) => {
        Button(emoji, { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(24).width(48).height(44).padding(0)
          .enabled(this.permitted && !this.loading && !this.submitting && !this.picking).accessibilityText(`插入表情 ${emoji}`)
          .onClick(() => { this.changeDraft(this.draft + emoji); this.showEmoji = false; })
      }, (emoji: string): string => emoji)
    }.width('100%').padding({ top: 4, bottom: 4 })
      .backgroundColor($r('app.color.selected_background')).borderRadius(12).id('composer_emoji_palette')
  }

  @Builder
  toolButton(tool: ComposerTool) {
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      SymbolGlyph(tool.symbol).fontSize(22).fontColor([tool.selected ? $r('app.color.accent') : $r('app.color.text_primary')])
    }.width(this.creatingTopic ? 44 : 48).height(48).enabled(tool.enabled).accessibilityText(tool.label)
      .accessibilitySelected(tool.selected).id(tool.id)
      .backgroundColor(tool.selected ? $r('app.color.selected_background') : Color.Transparent)
      .onClick(tool.action)
  }

  @Builder
  topicFields() {
    Column() {
      TextInput({ text: this.newTopicTitle, placeholder: this.selectedCategory()?.topicTitlePlaceholder || '写个标题',
        controller: this.titleController })
        .height(58).fontSize(21).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
        .borderRadius(0).padding({ left: 0, right: 0 }).maxLength(255)
        .enabled(this.permitted && !this.loading && !this.submitting && !this.picking)
        .onFocus((): void => { this.showEmoji = false; })
        .onChange((value: string): void => { this.changeTopicTitle(value); }).id('composer_topic_title')
      Divider().color($r('app.color.divider')).strokeWidth(0.5)
      Row({ space: 8 }) {
        Text('分类').fontSize(13).fontColor($r('app.color.text_secondary'))
        Select(this.categories.map((category: Category): SelectOption => { return { value: category.name }; }))
          .selected(this.categories.findIndex((category: Category): boolean => category.id === this.categoryId))
          .value(this.selectedCategory()?.name || '选择分类').font({ size: 14 })
          .fontColor($r('app.color.text_primary')).backgroundColor(Color.Transparent).layoutWeight(1)
          .enabled(this.permitted && !this.loading && !this.submitting && !this.picking)
          .onSelect((index: number): void => { this.changeCategory(index); }).id('composer_topic_category')
      }.width('100%').height(44)
      TextInput({ text: this.tagsText, placeholder: this.tagPlaceholder(), controller: this.tagsController })
        .height(40).fontSize(13).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent).borderRadius(0).padding({ left: 0, right: 0 }).maxLength(512)
        .enabled(this.permitted && !this.loading && !this.submitting && !this.picking)
        .onFocus((): void => { this.showEmoji = false; })
        .onChange((value: string): void => { this.changeTags(value); }).id('composer_topic_tags')
      Divider().color($r('app.color.divider')).strokeWidth(0.5)
    }.width('100%')
  }

  @Builder
  topicEditorHeader() {
    Row() {
      Row() {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).enabled(!this.submitting && !this.picking).accessibilityText('关闭编辑器')
          .id('composer_sheet_close').onClick((): void => { this.requestClose(); })
      }.width(72)
      Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .maxLines(1).textAlign(TextAlign.Center).layoutWeight(1).id('composer_sheet_title')
      Button(this.submitting ? '发布中' : '发布', { type: ButtonType.Capsule }).width(72).height(40).fontSize(15)
        .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).enabled(this.canSubmit)
        .onClick(() => { void this.submit(); }).id('composer_submit')
    }.width('100%').height(52)
  }

  @Builder
  editorFeedback() {
    if (this.loading) { LoadingProgress().width(24).height(24) }
    if (this.error) {
      Column({ space: 6 }) {
        Text(this.error).fontSize(13).fontColor($r('app.color.text_primary')).width('100%').maxLines(this.creatingTopic ? 3 : 2)
        if (!this.permitted) {
            Button('重新检查权限', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).enabled(!this.loading && !this.submitting)
            .onClick(() => { this.initialized = false; void this.prepare(); })
        }
      }.width('100%').padding(12).backgroundColor($r('app.color.selected_background')).borderRadius(12)
    }
  }

  @Builder
  attachmentList() {
    if (this.attachments.length > 0) {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.attachments, (attachment: DraftAttachment) => {
            Row({ space: 8 }) {
              Text(`${attachment.name} · ${Math.ceil(attachment.size / 1024)} KB`).fontSize(12)
                .fontColor($r('app.color.text_secondary')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([$r('app.color.text_secondary')])
              }.width(44).height(44).enabled(!this.loading && !this.submitting).accessibilityText(`移除附件 ${attachment.name}`)
                .onClick(() => { this.removeAttachment(attachment.id); })
            }.width('100%')
          }, (attachment: DraftAttachment): string => attachment.id)
        }.width('100%').padding({ left: 8, right: 8 })
      }.width('100%').constraintSize({ maxHeight: this.presentedAsSheet ? 72 : 144 }).scrollBar(BarState.Off)
    }
  }

  @Builder
  editorContent() {
    Column({ space: this.presentedAsSheet ? 8 : 12 }) {
      if (this.creatingTopic) {
        this.topicEditorHeader()
      } else if (this.presentedAsSheet) {
        Row({ space: 8 }) {
          Column({ space: 3 }) {
            Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              .maxLines(1).id('composer_sheet_title')
            Text(this.topicTitle || (this.loading ? '正在准备编辑器…' : 'LINUX DO'))
              .fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          }.width(44).height(44).enabled(!this.submitting && !this.picking).accessibilityText('关闭编辑器')
            .id('composer_sheet_close').onClick((): void => { this.requestClose(); })
        }.width('100%').height(48)
      } else {
        Text(this.topicTitle).fontSize(16).fontColor($r('app.color.text_secondary')).maxLines(2).width('100%')
      }
      if (this.creatingTopic) {
        Scroll() {
          Column({ space: 8 }) {
            this.editorFeedback()
            this.topicFields()
            TextArea({ text: this.draft, placeholder: '分享你的想法…', controller: this.textAreaController })
              .fontSize(16).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
              .backgroundColor(Color.Transparent).borderRadius(0).padding({ top: 10, bottom: 10, left: 0, right: 0 })
              .height(320).width('100%')
              .maxLength(65536).enabled(this.permitted && !this.loading && !this.submitting)
              .onFocus((): void => { this.showEmoji = false; })
              .onChange((value: string): void => { this.changeDraft(value); }).id('composer_text_area')
            this.attachmentList()
            if (this.saveMessage) {
              Text(this.saveMessage).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).align(Alignment.TopStart).id('composer_topic_form')
      } else {
        this.editorFeedback()
        TextArea({ text: this.draft, placeholder: '写下你的回复…\n支持 Markdown 格式', controller: this.textAreaController })
          .fontSize(16).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface')).borderRadius(16).padding(12).layoutWeight(1).width('100%')
          .maxLength(65536).enabled(this.permitted && !this.loading && !this.submitting)
          .onChange((value: string): void => { this.changeDraft(value); }).id('composer_text_area')
        this.attachmentList()
      }
      if (this.showEmoji) { this.emojiPalette() }
      if (this.creatingTopic) { Divider().color($r('app.color.divider')).strokeWidth(0.5) }
      Row({ space: 4 }) {
        this.toolButton({ symbol: $r('sys.symbol.picture'), label: '选择图片', id: 'composer_add_image',
          enabled: this.permitted && !this.loading && !this.submitting && !this.picking, selected: false,
          action: (): void => { void this.chooseAttachment(true); } })
        this.toolButton({ symbol: $r('sys.symbol.paperclip'), label: '选择附件', id: 'composer_add_attachment',
          enabled: this.permitted && !this.loading && !this.submitting && !this.picking, selected: false,
          action: (): void => { void this.chooseAttachment(false); } })
        this.toolButton({ symbol: $r('sys.symbol.face_smiling'), label: this.showEmoji ? '收起表情' : '插入表情', id: 'composer_show_emoji',
          enabled: this.permitted && !this.loading && !this.submitting && !this.picking, selected: this.showEmoji,
          action: (): void => { this.toggleEmoji(); } })
        this.toolButton({ symbol: $r('sys.symbol.bold'), label: '插入粗体', id: 'composer_insert_bold',
          enabled: this.permitted && !this.loading && !this.submitting && !this.picking, selected: false,
          action: (): void => { this.insert('**内容**'); } })
        this.toolButton({ symbol: $r('sys.symbol.link'), label: '插入链接', id: 'composer_insert_link',
          enabled: this.permitted && !this.loading && !this.submitting && !this.picking, selected: false,
          action: (): void => { this.insert('[链接文字](https://)'); } })
        if (this.creatingTopic) {
          Text(`${this.draft.length} 字`).fontSize(11).fontColor($r('app.color.text_secondary'))
            .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
        }
      }.width('100%').height(48).justifyContent(this.creatingTopic ? FlexAlign.Start : FlexAlign.SpaceBetween)
      if (!this.creatingTopic) {
        Row() {
        Text(this.submitting ? '正在提交…' : `${this.draft.length} 字${this.saveMessage ? ` · ${this.saveMessage}` : ''}`)
          .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button(this.postId > 0 ? '保存修改' : '发表回复', { type: ButtonType.Capsule }).height(48).fontSize(15)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).enabled(this.canSubmit)
          .onClick(() => { void this.submit(); }).id('composer_submit')
        }.width('100%').padding({ top: 2, bottom: 2 }).systemMaterial(materialFor(this.appearance))
      }
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: this.presentedAsSheet ? 4 : 16,
      bottom: 12 + (this.presentedAsSheet ? this.bottomInset : 0) })
  }

  build() {
    if (this.presentedAsSheet) {
      Column() { this.editorContent() }
        .width('100%').height('100%').backgroundColor(this.creatingTopic ? $r('app.color.surface') : $r('app.color.page_background'))
        .onAppear((): void => { this.presentationShown(); })
        .onDisAppear((): void => { this.presentationHidden(); })
    } else {
      NavDestination() { this.editorContent() }
        .title(this.title).padding({ top: this.topInset, bottom: this.bottomInset })
        .backgroundColor($r('app.color.page_background')).onShown(() => { this.presentationShown(); })
        .onHidden(() => { this.presentationHidden(); })
        .onBackPressed((): boolean => this.leave())
    }
  }
}
