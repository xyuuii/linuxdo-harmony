import { forumApi, ForumApiError, RequestCancellation } from '../services/ForumApi';
import { forumSession } from '../models/ForumSession';

interface TopicNotificationOption { level: number; title: string; description: string; }
const TOPIC_NOTIFICATION_OPTIONS: TopicNotificationOption[] = [
  { level: 3, title: '关注', description: '新回复时通知，并显示未读数量。' },
  { level: 2, title: '跟踪', description: '显示未读数量，回复和提及时通知。' },
  { level: 1, title: '常规', description: '仅在回复和提及时通知。' },
  { level: 0, title: '静音', description: '不接收通知，并从最新列表隐藏。' }
];

@ComponentV2
export struct TopicNotificationOptions {
  @Param topicId: number = 0;
  @Param currentLevel: number = -1;
  @Event onChanged: (level: number) => void = (): void => {};
  @Event onLogin: () => void = (): void => {};
  @Local selectedLevel: number = -1;
  @Local busy: boolean = false;
  @Local error: string = '';
  private token: RequestCancellation | undefined = undefined;
  private visible: boolean = false;

  private async select(level: number): Promise<void> {
    if (this.busy || level === this.selectedLevel || !this.visible) { return; }
    const ownerId: number = forumSession.user?.id ?? 0;
    if (ownerId <= 0) { this.onLogin(); return; }
    const token: RequestCancellation = new RequestCancellation();
    this.token = token; this.busy = true; this.error = '';
    try {
      await forumApi.setTopicNotificationLevel(this.topicId, level, token);
      if (!this.visible || this.token !== token || forumSession.user?.id !== ownerId) { return; }
      this.selectedLevel = level; this.onChanged(level);
    } catch (error) {
      if (this.visible && this.token === token && forumSession.user?.id === ownerId) {
        this.error = error instanceof ForumApiError ? error.message : '通知设置暂时无法更新';
      }
    } finally { if (this.token === token) { this.busy = false; this.token = undefined; } }
  }

  build() {
    Column({ space: 0 }) {
      Text('通知级别').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
        .width('100%').padding({ top: 16, bottom: 8 })
      ForEach(TOPIC_NOTIFICATION_OPTIONS, (option: TopicNotificationOption) => {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(option.title).fontSize(16).fontColor($r('app.color.text_primary'))
              Text(option.description).fontSize(12).fontColor($r('app.color.text_secondary')).lineHeight(18)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.selectedLevel === option.level) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.accent')])
            }
          }.width('100%').padding({ top: 12, bottom: 12 })
        }.width('100%').backgroundColor(Color.Transparent).enabled(!this.busy)
          .accessibilitySelected(this.selectedLevel === option.level).id(`topic_notification_${option.level}`)
          .onClick((): void => { void this.select(option.level); })
      }, (option: TopicNotificationOption): string => option.level.toString())
      if (this.busy) { LoadingProgress().width(24).height(24).margin(8) }
      if (this.error) {
        Text(this.error).fontSize(13).lineHeight(20).fontColor($r('app.color.error')).width('100%').padding(8)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onAppear((): void => { this.visible = true; this.selectedLevel = this.currentLevel; })
      .onDisAppear((): void => { this.visible = false; this.token?.cancel(); this.token = undefined; })
  }
}
