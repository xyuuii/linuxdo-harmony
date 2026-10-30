import { Post } from '../models/ForumModels';
import { ForumSession, forumSession } from '../models/ForumSession';
import { PostRevisionRecord, PostRevisionMetadataChange, canReadPostHistory } from '../models/PostRevisionModels';
import { forumApi, ForumApiError, ForumErrorKind, RequestCancellation } from '../services/ForumApi';
import { revisionDiffForReading } from '../services/PostRevisionWire';
import { ForumAvatar } from './ForumComponents';
import { RichPostContent } from './RichPostContent';

@ComponentV2
export struct PostRevisionSheet {
  @Param post: Post | undefined = undefined;
  @Param session: ForumSession = forumSession;
  @Param foreground: boolean = true;
  @Param reduceMotion: boolean = false;
  @Event onClose: () => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Event onOpenUser: (username: string) => void = (_username: string): void => {};
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Local revision: PostRevisionRecord | undefined = undefined;
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local needsLogin: boolean = false;
  private visible: boolean = false;
  private requestedRevision: number = 0;
  private request: RequestCancellation | undefined = undefined;

  @Monitor('post')
  postChanged(): void {
    this.request?.cancel(); this.request = undefined; this.revision = undefined; this.busy = false; this.error = '';
    if (this.visible) { void this.load(0); }
  }

  @Monitor('session.revision')
  accountChanged(): void {
    this.request?.cancel(); this.request = undefined; this.revision = undefined; this.busy = false; this.error = '';
    if (this.visible) { this.onClose(); }
  }

  @Monitor('foreground')
  foregroundChanged(): void {
    if (!this.foreground) {
      if (this.request !== undefined) { this.error = '读取已暂停，请重新读取。'; }
      this.request?.cancel(); this.request = undefined; this.busy = false;
    }
  }

  @Computed
  get bodyDiff(): string { return revisionDiffForReading(this.revision?.bodyDiffHtml || ''); }

  @Computed
  get titleDiff(): string { return revisionDiffForReading(this.revision?.titleDiffHtml || ''); }

  @Computed
  get changedAt(): string {
    const date: Date = new Date(this.revision?.createdAt || '');
    return Number.isNaN(date.getTime()) ? '编辑时间未提供' : date.toLocaleString();
  }

  private async load(number: number = 0): Promise<void> {
    const post: Post | undefined = this.post;
    if (!this.visible || !this.foreground || !post || !canReadPostHistory(post)) { return; }
    this.request?.cancel();
    const cancellation: RequestCancellation = new RequestCancellation();
    const owner: number = this.session.user?.id || 0;
    const sessionGeneration: number = forumApi.getSessionGeneration();
    this.request = cancellation; this.requestedRevision = number;
    this.busy = true; this.error = ''; this.needsLogin = false; this.revision = undefined;
    try {
      const revision: PostRevisionRecord = await forumApi.fetchPostRevision(post.id, number, cancellation);
      if (this.request !== cancellation || cancellation.isCancelled || !this.visible || !this.foreground ||
        (this.session.user?.id || 0) !== owner || forumApi.getSessionGeneration() !== sessionGeneration || this.post?.id !== post.id) { return; }
      this.revision = revision;
    } catch (error) {
      if (this.request === cancellation && !cancellation.isCancelled && this.visible && this.foreground &&
        (this.session.user?.id || 0) === owner && forumApi.getSessionGeneration() === sessionGeneration) {
        this.error = error instanceof ForumApiError ? error.message : '编辑历史暂时无法读取';
        this.needsLogin = error instanceof ForumApiError && (error.kind === ForumErrorKind.AuthenticationRequired ||
          error.kind === ForumErrorKind.VerificationRequired);
      }
    } finally { if (this.request === cancellation) { this.request = undefined; this.busy = false; } }
  }

  private move(older: boolean): void {
    if (this.busy || !this.revision) { return; }
    const number: number | undefined = older ? this.revision.previousRevision : this.revision.nextRevision;
    // These pointers already skip revisions hidden from the current account.
    if (number !== undefined) { void this.load(number); }
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Text(`第 ${this.post?.postNumber ?? 0} 楼 · 编辑历史`).fontSize(21).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).accessibilityText('关闭编辑历史').onClick(this.onClose)
      }.width('100%').padding({ left: 20, right: 12, top: 6, bottom: 6 })
      Row({ space: 10 }) {
        Button('上一版', { buttonStyle: ButtonStyleMode.TEXTUAL }).layoutWeight(1).height(44)
          .enabled(!this.busy && this.foreground && this.revision?.previousRevision !== undefined)
          .onClick((): void => { this.move(true); }).id('post_revision_previous')
        Text(this.revision ? `第 ${this.revision.currentVersion} / ${this.revision.versionCount} 版` : '编辑历史')
          .fontSize(13).fontColor($r('app.color.text_secondary')).id('post_revision_position')
        Button('下一版', { buttonStyle: ButtonStyleMode.TEXTUAL }).layoutWeight(1).height(44)
          .enabled(!this.busy && this.foreground && this.revision?.nextRevision !== undefined)
          .onClick((): void => { this.move(false); }).id('post_revision_next')
      }.width('100%').padding({ left: 12, right: 12 })
      Divider().color($r('app.color.divider'))
      Scroll() {
        Column({ space: 18 }) {
          if (this.busy) {
            LoadingProgress().width(32).height(32).margin(24)
          } else if (!canReadPostHistory(this.post)) {
            Text('当前楼层没有可查看的编辑历史。').fontSize(15).fontColor($r('app.color.text_secondary'))
          } else if (this.error) {
            Text(this.error).fontSize(15).lineHeight(24).fontColor($r('app.color.text_primary')).width('100%')
            Button('重新读取', { buttonStyle: ButtonStyleMode.TEXTUAL }).height(44)
              .enabled(this.foreground).onClick((): void => { void this.load(this.requestedRevision); })
            if (this.needsLogin) { Button('登录 / 完成验证').height(44).onClick(this.onLogin) }
          } else if (this.revision) {
            Row({ space: 10 }) {
              ForumAvatar({ name: this.revision.editorUsername, url: this.revision.avatarUrl, avatarSize: 36 })
              Column({ space: 4 }) {
                Text(this.revision.editorName || this.revision.editorUsername || '编辑者未提供')
                  .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                Text(this.revision.editorUsername ? `@${this.revision.editorUsername}` : '')
                  .fontSize(12).fontColor($r('app.color.text_secondary'))
                Text(this.changedAt).fontSize(12).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').onClick((): void => { if (this.revision?.editorUsername) { this.onOpenUser(this.revision.editorUsername); } })
            Text(`编辑原因：${this.revision.editReason || '未提供'}`).fontSize(14).lineHeight(22)
              .fontColor($r('app.color.text_secondary')).width('100%')
            if (this.revision.previousHidden || this.revision.currentHidden) {
              Text('这条修订涉及隐藏版本，仅显示社区允许返回的内容。').fontSize(13).lineHeight(21)
                .fontColor($r('app.color.text_secondary')).width('100%')
            }
            if (this.revision.diffError) {
              Text('社区未能生成完整的差异比较。').fontSize(14).lineHeight(22)
                .fontColor($r('app.color.text_secondary')).width('100%')
            }
            if (this.revision.titleDiffHtml || this.revision.bodyDiffHtml) {
              Text('【新增】与【删除】标记包围本次修改的片段。').fontSize(12).lineHeight(20)
                .fontColor($r('app.color.text_secondary')).width('100%')
            }
            if (this.revision.titleDiffHtml) {
              Text('标题变化').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
              RichPostContent({ cooked: this.titleDiff, compact: true, reduceMotion: this.reduceMotion,
                onOpenLink: this.onOpenLink, onPicture: this.onPicture })
            }
            if (this.revision.bodyDiffHtml) {
              Text('正文变化').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
              RichPostContent({ cooked: this.bodyDiff, compact: true, reduceMotion: this.reduceMotion,
                onOpenLink: this.onOpenLink, onPicture: this.onPicture })
            }
            ForEach(this.revision.metadataChanges, (change: PostRevisionMetadataChange) => {
              Column({ space: 6 }) {
                Text(change.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                Text(`修改前：${change.previous || '未提供'}`).fontSize(14).fontColor($r('app.color.text_secondary'))
                Text(`修改后：${change.current || '未提供'}`).fontSize(14).fontColor($r('app.color.text_primary'))
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (change: PostRevisionMetadataChange): string => change.label)
            if (!this.revision.bodyDiffHtml && !this.revision.titleDiffHtml && this.revision.metadataChanges.length === 0) {
              Text('社区未提供可显示的差异内容。').fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
            }
            if (this.revision.bodyDiffHtml.length > 131072 || this.revision.titleDiffHtml.length > 131072) {
              Text('差异内容较长，当前仅展示开头部分。').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .onAppear((): void => { this.visible = true; void this.load(0); })
      .onDisAppear((): void => {
        this.visible = false; this.request?.cancel(); this.request = undefined; this.revision = undefined; this.busy = false;
      })
  }
}
