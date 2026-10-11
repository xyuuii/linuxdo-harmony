import { TopicListItem } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { NativeForumImage } from './NativeForumImage';
import { formatCount, relativeTime } from '../services/ForumPresentation';

@ComponentV2
export struct ForumAvatar {
  @Param name: string = '';
  @Param url: string = '';
  @Param avatarSize: number = 34;
  build() {
    Stack() {
      Text(this.name.length > 0 ? this.name.substring(0, 1).toUpperCase() : 'L')
        .fontSize(this.avatarSize * 0.4).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
      if (this.url.startsWith('https://')) {
        NativeForumImage({ url: this.url, fit: ImageFit.Cover, previewImageAspectRatio: 0,
          ownerId: forumSession.user?.id || 0, accessibleLabel: this.name }).width('100%').height('100%')
      }
    }.width(this.avatarSize).height(this.avatarSize).backgroundColor($r('app.color.selected_background'))
      .borderRadius(this.avatarSize / 2).clip(true).accessibilityText(this.name)
  }
}

@ComponentV2
export struct TopicRow {
  @Param item: TopicListItem | undefined = undefined;
  @Param excerpt: string = '';
  @Event onOpen: (id: number) => void = (): void => {};
  build() {
    if (this.item !== undefined) {
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          ForumAvatar({ name: this.item.authorUsername, url: this.item.avatarUrl, avatarSize: 20 })
          Text(this.item.authorUsername || this.item.topic.lastPosterUsername).fontSize(12)
            .fontColor($r('app.color.text_secondary')).layoutWeight(1).maxLines(1)
          if (this.item.topic.pinned) {
            SymbolGlyph($r('sys.symbol.pin')).fontSize(12).fontColor([$r('app.color.accent')])
          }
          Text(relativeTime(this.item.topic.lastPostedAt || this.item.topic.createdAt))
            .fontSize(11).fontColor($r('app.color.text_secondary'))
        }
        Text(this.item.topic.title).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).lineHeight(22).width('100%').maxLines(2)
        if (this.excerpt.length > 0) {
          Text(this.excerpt).fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(19).maxLines(1)
            .width('100%')
        }
        Row({ space: 6 }) {
          if (this.item.category !== undefined) {
            Text(this.item.category.name).fontSize(11).fontColor($r('app.color.accent'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.selected_background')).borderRadius(5).maxLines(1)
              .constraintSize({ maxWidth: 160 })
          }
          Blank()
          SymbolGlyph($r('sys.symbol.message')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          Text(formatCount(this.item.topic.replyCount)).fontSize(12).fontColor($r('app.color.text_secondary'))
          SymbolGlyph($r('sys.symbol.eye')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          Text(formatCount(this.item.topic.views)).fontSize(12).fontColor($r('app.color.text_secondary'))
        }.width('100%')
      }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 }).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface')).borderRadius(14)
        .id(`topic_${this.item.topic.id}`).accessibilityText(this.item.topic.title)
        .onClick(() => { if (this.item !== undefined) { this.onOpen(this.item.topic.id); } })
    }
  }
}

@ComponentV2
export struct ForumErrorView {
  @Param message: string = '';
  @Param needsVerification: boolean = false;
  @Event onRetry: () => void = (): void => {};
  @Event onVerify: () => void = (): void => {};
  build() {
    Column({ space: 16 }) {
      SymbolGlyph($r('sys.symbol.wifi')).fontSize(32).fontColor([$r('app.color.text_secondary')])
      Text(this.message).fontSize(15).fontColor($r('app.color.text_secondary'))
        .lineHeight(24).textAlign(TextAlign.Center)
      Button(this.needsVerification ? '打开网页登录或验证' : '重试', { type: ButtonType.Capsule })
        .fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).height(48)
        .onClick(() => { if (this.needsVerification) { this.onVerify(); } else { this.onRetry(); } })
    }.width('100%').padding(28).constraintSize({ minHeight: 220 })
  }
}
