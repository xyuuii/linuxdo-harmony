import { Boost } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { NativeForumImage } from './NativeForumImage';
import { RichPostContent, parsePostContent, PostBlock, PostInline } from './RichPostContent';

/** The forum displays boosts as compact avatar-and-content pills, without a separate name column. */
@ComponentV2
export struct BoostBubble {
  @Param boost: Boost = {} as Boost;
  @Param busy: boolean = false;
  @Param reduceMotion: boolean = false;
  @Event onDelete: (boost: Boost) => void = (_boost: Boost): void => {};
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Local showManage: boolean = false;

  @Computed
  get username(): string { return this.boost.user?.username || '用户'; }

  @Computed
  get accessibleLabel(): string {
    const cookedText: string = parsePostContent(this.boost.cooked)
      .flatMap((block: PostBlock): string[] => block.runs.map((run: PostInline): string => run.text))
      .join(' ').replace(/\s+/g, ' ').trim();
    return `${this.username} 的简评：${cookedText}${this.boost.canDelete ? '，点按管理简评' : ''}`;
  }

  @Builder
  private manageMenu() {
    Menu() {
      if (this.boost.canDelete) {
        MenuItem({ content: '删除简评' }).enabled(!this.busy)
          .onClick((): void => {
            if (!this.busy && this.boost.canDelete) { this.onDelete(this.boost); }
          })
      }
    }
  }

  build() {
    Row({ space: 4 }) {
      if (this.boost.user?.avatarUrl) {
        NativeForumImage({ url: this.boost.user.avatarUrl, fit: ImageFit.Cover,
          ownerId: forumSession.user?.id || 0, accessibleLabel: `${this.username} 的头像` })
          .width(24).height(24).borderRadius(12).clip(true).flexShrink(0)
      } else {
        Text(this.username.slice(0, 1).toUpperCase()).fontSize(12)
          .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          .width(24).height(24).backgroundColor($r('app.color.divider')).borderRadius(12).flexShrink(0)
      }
      RichPostContent({ cooked: this.boost.cooked, compact: true, inlineContent: true,
        reduceMotion: this.reduceMotion, onOpenLink: this.onOpenLink, onPicture: this.onPicture })
        .flexShrink(1)
    }.width('auto').constraintSize({ maxWidth: '100%', minHeight: 32 })
      .padding({ left: 4, right: 8, top: 4, bottom: 4 }).borderRadius(20)
      .backgroundColor(this.showManage ? $r('app.color.selected_background') : $r('app.color.boost_background'))
      .id(`boost_${this.boost.id}`).accessibilityGroup(true).accessibilityText(this.accessibleLabel)
      .onClick((): void => {
        if (this.boost.canDelete && !this.busy) { this.showManage = true; }
      })
      .bindMenu(this.showManage, this.manageMenu, { onDisappear: (): void => { this.showManage = false; } })
  }
}
