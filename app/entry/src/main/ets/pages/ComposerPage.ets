import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { preferences } from '@kit.ArkData';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { Post, TopicDetail, UploadedFile, uploadedFileMarkdown } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation } from '../services/ForumApi';
import { materialFor } from '../services/MaterialPolicy';

interface DraftAttachment { id: string; uri: string; name: string; mime: string; size: number; }

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
  @Param topicId: number = 0;
  @Param replyTo: number = 0;
  @Param postId: number = 0;
  @Param appearance: AppearanceSettings = loadAppearanceSettings();
  @Param session: ForumSession = forumSession;
  @Event onDone: () => void = (): void => {};
  @Event onSubmitted: (postNumber: number) => void = (_number: number): void => {};
  @Local draft: string = '';
  @Local initialRaw: string = '';
  @Local topicTitle: string = '';
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
  private readonly emojis: string[] = ['😀', '😄', '😊', '👍', '❤️', '🎉', '🤝', '🤔', '🙏', '🚀', '✅', '💡'];

  @Monitor('session.revision')
  accountChanged(): void {
    if (this.ownerId > 0 && this.session.user?.id !== this.ownerId) {
      this.prepareGeneration++;
      this.writeRequest?.cancel();
      this.loading = false;
      if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); this.saveTimer = -1; }
      this.saveDraft();
      this.draftKey = '';
      this.store = undefined;
      this.draft = '';
      this.initialRaw = '';
      this.attachments = [];
      this.permitted = false;
      this.error = '登录账号已变化，本次编辑已停止。若刚才已提交，请返回话题核对结果。';
    }
  }

  @Computed
  get title(): string {
    return this.postId > 0 ? `编辑第 ${this.replyTo} 楼` : this.replyTo > 0 ? `回复第 ${this.replyTo} 楼` : '回复话题';
  }

  @Computed
  get canSubmit(): boolean {
    return this.permitted && !this.loading && !this.submitting && !this.picking &&
      this.ownerId > 0 && this.session.user?.id === this.ownerId &&
      (this.draft.trim().length > 0 || this.attachments.length > 0);
  }

  private async prepare(): Promise<void> {
    if (this.initialized || this.loading) { return; }
    this.initialized = true;
    this.loading = true;
    this.error = '';
    const request: number = ++this.prepareGeneration;
    try {
      const userId: number = this.session.user?.id || 0;
      if (userId <= 0) { throw new Error('请登录后再回复或编辑。'); }
      this.ownerId = userId;
      this.draftKey = `draft_${userId}_${this.topicId}_${this.replyTo}_${this.postId}`;
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
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try {
        this.store = await preferences.getPreferences(context, { name: 'forum_composer_drafts_v1' });
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { this.store = undefined; return; }
        const saved: preferences.ValueType = await this.store.get(this.draftKey, '');
        if (request !== this.prepareGeneration || this.session.user?.id !== this.ownerId) { return; }
        this.draft = typeof saved === 'string' && saved.length > 0 ? saved : this.initialRaw;
        this.saveMessage = saved ? '已恢复本机草稿' : '';
      } catch {
        this.draft = this.initialRaw;
        this.saveMessage = '当前草稿暂时无法保存到本机';
      }
      this.attachments = draftAttachments.get(this.draftKey) || [];
    } catch (error) {
      if (request === this.prepareGeneration) { this.error = composerError(error); this.permitted = false; }
    }
    finally { if (request === this.prepareGeneration) { this.loading = false; } }
  }

  private changeDraft(value: string): void {
    this.draft = value;
    if (this.saveTimer >= 0) { clearTimeout(this.saveTimer); }
    this.saveTimer = setTimeout((): void => { this.saveDraft(); }, 450);
  }

  private async saveDraft(): Promise<void> {
    if (!this.draftKey || this.store === undefined) { return; }
    const key: string = this.draftKey;
    const value: string = this.draft;
    const store: preferences.Preferences = this.store;
    try {
      await store.put(key, value);
      await store.flush();
      if (key === this.draftKey) { this.saveMessage = '草稿已保存在本机'; }
    } catch { if (key === this.draftKey) { this.saveMessage = '当前草稿暂时无法保存到本机'; } }
  }

  private insert(value: string): void {
    this.changeDraft(`${this.draft}${this.draft.length > 0 ? '\n' : ''}${value}`);
  }

  private async chooseAttachment(image: boolean): Promise<void> {
    if (this.submitting || this.picking || !this.permitted) { return; }
    this.picking = true;
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
    finally { this.picking = false; }
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
      const topic: TopicDetail = await forumApi.fetchTopic(this.topicId, this.replyTo || 1, cancellation);
      ensureOwner();
      if (this.postId > 0) {
        const posts: Post[] = await forumApi.fetchPosts(this.topicId, [this.postId], cancellation);
        ensureOwner();
        if (!posts.some((post: Post): boolean => post.id === this.postId && post.topicId === this.topicId && post.canEdit)) {
          throw new Error('当前账号已无权编辑此内容。');
        }
      } else if (!topic.canReply) { throw new Error('该话题已关闭，或当前账号已无回复权限。'); }
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
      const post: Post = this.postId > 0 ? await forumApi.updatePost(this.postId, this.draft, cancellation) :
        await forumApi.createPost(this.topicId, this.draft, this.replyTo > 0 ? this.replyTo : undefined, cancellation);
      ensureOwner();
      this.permitted = false;
      // Server success remains success even if local draft cleanup cannot be flushed.
      if (this.store !== undefined) {
        try { await this.store.delete(this.draftKey); await this.store.flush(); } catch {}
      }
      draftAttachments.delete(this.draftKey);
      this.draft = '';
      this.initialRaw = '';
      this.getUIContext().getPromptAction().showToast({ message: this.postId > 0 ? '修改已保存' : '回复已发表' });
      this.onSubmitted(post.postNumber);
      this.onDone();
    } catch (error) {
      if (generation === this.prepareGeneration) {
        this.error = composerError(error);
        await this.saveDraft();
      }
    } finally { if (this.writeRequest === cancellation) { this.writeRequest = undefined; } this.submitting = false; }
  }

  private leave(): boolean {
    if (this.submitting || this.picking) {
      this.getUIContext().getPromptAction().showToast({ message: this.submitting ? '正在提交，请稍候' : '请先完成文件选择' });
      return true;
    }
    if (this.draft !== this.initialRaw || this.attachments.length > 0) {
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
    this.attachments = [];
    this.onDone();
  }

  @Builder
  emojiSheet() {
    Column({ space: 18 }) {
      Text('选择表情').fontSize(23).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.emojis, (emoji: string) => {
          Button(emoji, { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(27).width(64).height(56)
            .onClick(() => { this.changeDraft(this.draft + emoji); this.showEmoji = false; })
        }, (emoji: string): string => emoji)
      }.width('100%')
    }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Text(this.topicTitle).fontSize(16).fontColor($r('app.color.text_secondary')).maxLines(2).width('100%')
        if (this.loading) { LoadingProgress().width(36).height(36) }
        if (this.error) {
          Column({ space: 6 }) {
            Text(this.error).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
            if (!this.permitted) {
              Button('重新检查权限', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).enabled(!this.loading)
                .onClick(() => { this.initialized = false; this.prepare(); })
            }
          }.width('100%').padding(12).backgroundColor($r('app.color.selected_background')).borderRadius(12)
        }
        TextArea({ text: this.draft, placeholder: '写下你的回复…\n支持 Markdown 格式' })
          .fontSize(16).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface')).borderRadius(18).padding(16).layoutWeight(1).width('100%')
          .maxLength(65536).enabled(this.permitted && !this.submitting)
          .onChange((value: string): void => { this.changeDraft(value); })
        if (this.attachments.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.attachments, (attachment: DraftAttachment) => {
              Row({ space: 8 }) {
                Text(`${attachment.name} · ${Math.ceil(attachment.size / 1024)} KB`).fontSize(12)
                  .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                Button('移除', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(40).fontSize(12).enabled(!this.submitting)
                  .onClick(() => { this.removeAttachment(attachment.id); })
              }.width('100%')
            }, (attachment: DraftAttachment): string => attachment.id)
          }.width('100%').padding({ left: 8, right: 8 })
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('图片', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(14)
            .enabled(this.permitted && !this.submitting && !this.picking).onClick(() => { this.chooseAttachment(true); })
          Button('附件', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(14)
            .enabled(this.permitted && !this.submitting && !this.picking).onClick(() => { this.chooseAttachment(false); })
          Button('表情', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(14)
            .enabled(this.permitted && !this.submitting).onClick(() => { this.showEmoji = true; })
          Button('粗体', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(14)
            .enabled(this.permitted && !this.submitting).onClick(() => { this.insert('**内容**'); })
          Button('链接', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).fontSize(14)
            .enabled(this.permitted && !this.submitting).onClick(() => { this.insert('[链接文字](https://)'); })
        }.width('100%')
        Row() {
          Text(this.submitting ? '正在提交…' : `${this.draft.length} 字${this.saveMessage ? ` · ${this.saveMessage}` : ''}`)
            .fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.postId > 0 ? '保存修改' : '发表回复', { type: ButtonType.Capsule }).height(48).fontSize(16)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).enabled(this.canSubmit)
            .onClick(() => { this.submit(); })
        }.width('100%').padding({ top: 10, bottom: 10 }).systemMaterial(materialFor(this.appearance))
      }.width('100%').height('100%').padding({ left: 18, right: 18, top: 16, bottom: 14 })
        .bindSheet($$this.showEmoji, this.emojiSheet, { height: SheetSize.MEDIUM, dragBar: true,
          backgroundColor: $r('app.color.surface') })
    }.title(this.title).backgroundColor($r('app.color.page_background')).onShown(() => { this.prepare(); })
      .onHidden(() => { if (!this.submitting) { this.saveDraft(); } })
      .onBackPressed((): boolean => this.leave())
  }
}
