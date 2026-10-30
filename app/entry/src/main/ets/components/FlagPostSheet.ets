import { Post } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { forumApi, ForumApiError, RequestCancellation } from '../services/ForumApi';

interface PostFlagOption { id: number; label: string; description: string; }
const POST_FLAG_OPTIONS: PostFlagOption[] = [
  { id: 3, label: '偏离话题', description: '与当前讨论无关。' },
  { id: 4, label: '不当内容', description: '不符合社区准则。' },
  { id: 7, label: '垃圾信息', description: '广告或无关的推广内容。' },
  { id: 8, label: '其他问题', description: '向版主说明需要处理的问题。' }
];

@ComponentV2
export struct FlagPostSheet {
  @Param post: Post | undefined = undefined;
  @Event onSubmitted: (post: Post) => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local reasonId: number = 0;
  @Local message: string = '';
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local succeeded: boolean = false;
  private visible: boolean = false;
  private token: RequestCancellation | undefined = undefined;

  @Computed
  get options(): PostFlagOption[] {
    return POST_FLAG_OPTIONS.filter((option: PostFlagOption): boolean => this.post?.flagTypes?.includes(option.id) === true);
  }

  private async submit(): Promise<void> {
    const post: Post | undefined = this.post;
    const ownerId: number = forumSession.user?.id ?? 0;
    if (!this.visible || !post || ownerId <= 0 || this.busy || this.succeeded || !post.flagTypes?.includes(this.reasonId)) { return; }
    const token: RequestCancellation = new RequestCancellation();
    this.token = token; this.busy = true; this.error = '';
    try {
      const updated: Post = await forumApi.flagPost(post.id, this.reasonId, this.message, token);
      if (!this.visible || this.token !== token || forumSession.user?.id !== ownerId) { return; }
      this.succeeded = true; this.onSubmitted(updated);
    } catch (error) {
      if (this.visible && this.token === token && forumSession.user?.id === ownerId) {
        this.error = error instanceof ForumApiError ? error.message : '举报暂时无法提交';
      }
    } finally { if (this.token === token) { this.busy = false; this.token = undefined; } }
  }

  build() {
    Column({ space: 12 }) {
      Text(`举报第 ${this.post?.postNumber ?? 0} 楼`).fontSize(22).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).width('100%').padding({ top: 16 })
      if (this.succeeded) {
        Text('举报已提交，社区将按规则处理。').fontSize(16).fontColor($r('app.color.text_primary')).lineHeight(24)
        Button('完成').width('100%').height(48).onClick(this.onClose)
      } else {
        ForEach(this.options, (option: PostFlagOption) => {
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text(option.label).fontSize(16).fontColor($r('app.color.text_primary'))
                Text(option.description).fontSize(12).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph(this.reasonId === option.id ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
                .fontSize(22).fontColor([$r('app.color.accent')])
            }.width('100%').padding({ top: 8, bottom: 8 })
          }.width('100%').backgroundColor(Color.Transparent).enabled(!this.busy)
            .accessibilitySelected(this.reasonId === option.id).onClick((): void => { this.reasonId = option.id; })
        }, (option: PostFlagOption): string => option.id.toString())
        TextArea({ text: this.message, placeholder: this.reasonId === 8 ? '请向版主说明问题' : '补充说明（可选）' })
          .height(120).maxLength(8000).fontSize(15).fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.page_background')).onChange((value: string): void => { this.message = value; })
        if (this.error) { Text(this.error).fontSize(13).fontColor($r('app.color.error')).width('100%') }
        Button(this.busy ? '正在提交' : '提交举报').width('100%').height(48)
          .enabled(!this.busy && this.reasonId > 0 && (this.reasonId !== 8 || this.message.trim().length > 0))
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).onClick((): void => { void this.submit(); })
      }
      Blank()
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 24 })
      .backgroundColor($r('app.color.surface'))
      .onAppear((): void => { this.visible = true; })
      .onDisAppear((): void => { this.visible = false; this.token?.cancel(); this.token = undefined; })
  }
}
