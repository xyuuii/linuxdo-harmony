import { TopicListItem } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { NativeForumImage } from './NativeForumImage';
import { formatCount } from '../services/ForumPresentation';
import { PINNED_PREVIEW_COUNT, visiblePinnedTopics, topicMetadata, compactTopicTime } from '../services/TopicFeedPresentation';

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
      Column({ space: 7 }) {
        Row({ space: 6 }) {
          if (this.item.topic.pinned) {
            SymbolGlyph($r('sys.symbol.pin')).fontSize(12).fontColor([$r('app.color.accent')])
          } else if (this.item.topic.unseen) {
            Row().width(5).height(5).borderRadius(3).backgroundColor($r('app.color.accent'))
          }
          Text(this.item.topic.title).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).lineHeight(23).layoutWeight(1).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').alignItems(VerticalAlign.Center)
        if (this.excerpt.length > 0) {
          Text(this.excerpt).fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(19).maxLines(2)
            .width('100%').textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 5 }) {
          if (this.item.category !== undefined) {
            Row().width(6).height(6).borderRadius(2)
              .backgroundColor(/^#?[0-9A-Fa-f]{6}$/.test(this.item.category.color) ?
                '#' + this.item.category.color.replace('#', '') : $r('app.color.accent'))
          }
          Text(topicMetadata(this.item)).fontSize(11).fontColor($r('app.color.text_secondary'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          ForumAvatar({ name: this.item.authorUsername, url: this.item.avatarUrl, avatarSize: 18 })
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.message')).fontSize(11).fontColor([$r('app.color.text_secondary')])
            Text(formatCount(this.item.topic.replyCount)).fontSize(11).fontColor($r('app.color.text_secondary'))
          }
          Text(compactTopicTime(this.item.topic.lastPostedAt || this.item.topic.createdAt))
            .fontSize(11).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.End)
            .constraintSize({ minWidth: 31 })
        }.width('100%')
      }.width('100%').padding({ left: 3, right: 3, top: 12, bottom: 12 }).alignItems(HorizontalAlign.Start)
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        .id(`topic_${this.item.topic.id}`).accessibilityText(this.item.topic.title)
        .onClick(() => { if (this.item !== undefined) { this.onOpen(this.item.topic.id); } })
    }
  }
}

@ComponentV2
export struct PinnedTopicsBlock {
  @Param items: TopicListItem[] = [];
  @Event onOpen: (id: number) => void = (): void => {};
  @Local expanded: boolean = false;

  build() {
    Column({ space: 0 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.pin')).fontSize(13).fontColor([$r('app.color.accent')])
        Text(`置顶 · ${this.items.length}`).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        if (this.items.length > PINNED_PREVIEW_COUNT) {
          Button(this.expanded ? '收起' : `展开 ${this.items.length} 条`, { type: ButtonType.Normal })
            .fontSize(12).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
            .height(36).padding({ left: 8, right: 0 }).id('pinned_topics_toggle')
            .accessibilityText(this.expanded ? '收起置顶话题' : `展开全部 ${this.items.length} 条置顶话题`)
            .onClick(() => { this.expanded = !this.expanded; })
        }
      }.width('100%').constraintSize({ minHeight: 32 })
      ForEach(visiblePinnedTopics(this.items, this.expanded), (item: TopicListItem) => {
        Column({ space: 4 }) {
          Text(item.topic.title).fontSize(14).fontWeight(FontWeight.Medium).lineHeight(20)
            .fontColor($r('app.color.text_primary')).width('100%').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 5 }) {
            Text(topicMetadata(item)).fontSize(11).fontColor($r('app.color.text_secondary'))
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            SymbolGlyph($r('sys.symbol.message')).fontSize(10).fontColor([$r('app.color.text_secondary')])
            Text(formatCount(item.topic.replyCount)).fontSize(11).fontColor($r('app.color.text_secondary'))
            Text(compactTopicTime(item.topic.lastPostedAt || item.topic.createdAt))
              .fontSize(11).fontColor($r('app.color.text_secondary'))
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 48 }).padding({ top: 7, bottom: 8 })
          .alignItems(HorizontalAlign.Start).border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
          .id(`pinned_topic_${item.topic.id}`).accessibilityText(`置顶话题，${item.topic.title}`)
          .onClick(() => { this.onOpen(item.topic.id); })
      }, (item: TopicListItem): string => JSON.stringify(item))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 3, right: 3 })
      .id('pinned_topics_block')
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
