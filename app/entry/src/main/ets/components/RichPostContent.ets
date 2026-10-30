import { common } from '@kit.AbilityKit';
import { ForumSession, forumSession } from '../models/ForumSession';
import { RequestCancellation } from '../services/ForumApi';
import { loadForumMedia } from '../services/ForumMedia';
import { NativeForumImage } from './NativeForumImage';

/** Discourse cooked HTML is interpreted as native text and images, never executed. */
export interface PostInline {
  key: string;
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  href: string;
  emojiUrl: string;
}

export interface PostBlock {
  key: string;
  kind: string;
  runs: PostInline[];
  quote: boolean;
  url: string;
  description: string;
  heading: boolean;
  imageWidth: number;
  imageHeight: number;
  imageDisplayWidth?: number;
  codeLanguage?: string;
  quoteGroupId?: string;
  quoteLevel?: number;
  quoteHeader?: PostQuoteHeader;
}

export interface PostQuoteHeader {
  key: string; username: string; avatarUrl: string; href: string; postNumber: number;
}
export interface PostContentGroup {
  key: string; quote: boolean; blocks: PostBlock[]; header?: PostQuoteHeader;
}
interface PostQuoteContext {
  tag: string; groupId: string; level: number; header: PostQuoteHeader; titleSeen: boolean;
}

function postQuoteHeaderVisible(header: PostQuoteHeader | undefined): boolean {
  return header !== undefined && (header.username.trim().length > 0 || header.avatarUrl.length > 0 ||
    header.href.length > 0 || header.postNumber > 0);
}

/** Preserve flat blocks for image/gallery consumers; only native presentation groups them. */
export function groupPostContent(blocks: PostBlock[]): PostContentGroup[] {
  const groups: PostContentGroup[] = [];
  blocks.forEach((block: PostBlock): void => {
    const key: string = block.quote ? block.quoteGroupId || `quote-${block.key}` : block.key;
    let group: PostContentGroup | undefined = groups[groups.length - 1];
    if (group === undefined || !block.quote || !group.quote || group.key !== key) {
      group = { key: key, quote: block.quote, blocks: [] }; groups.push(group);
    }
    if (block.kind === 'quote_header' && (block.quoteLevel ?? 1) <= 1) {
      if (postQuoteHeaderVisible(block.quoteHeader)) { group.header = block.quoteHeader; }
    } else if (block.kind !== 'quote_header' || postQuoteHeaderVisible(block.quoteHeader)) {
      group.blocks.push(block);
    }
  });
  return groups.filter((group: PostContentGroup): boolean => group.blocks.length > 0 || postQuoteHeaderVisible(group.header));
}

export function postQuoteCanCollapse(group: PostContentGroup): boolean {
  return group.quote && (postQuoteHeaderVisible(group.header) || group.blocks.length > 3 ||
    group.blocks.reduce((count: number, block: PostBlock): number => {
      return count + block.runs.reduce((length: number, run: PostInline): number => length + run.text.length, 0);
    }, 0) > 360);
}

export function visiblePostQuoteBlocks(group: PostContentGroup, collapsed: boolean): PostBlock[] {
  return collapsed ? [] : group.blocks;
}

function postQuoteTarget(topic: string, post: string, href: string = ''): string {
  const topicId: number = Number(topic);
  const postNumber: number = Number(post);
  if (Number.isSafeInteger(topicId) && topicId > 0 && Number.isSafeInteger(postNumber) && postNumber > 0) {
    return `https://linux.do/t/${topicId}/${postNumber}`;
  }
  const candidate: string = postContentUrl(href);
  return /^https:\/\/linux\.do\/t\/(?:[^/?#]+\/)?[1-9][0-9]*(?:\/[1-9][0-9]*)?\/?$/.test(candidate) ? candidate : '';
}

function emptyPostBlock(): PostBlock {
  return { key: '', kind: 'paragraph', runs: [], quote: false, url: '', description: '', heading: false,
    imageWidth: 0, imageHeight: 0 };
}

function emptyPostQuoteHeader(): PostQuoteHeader {
  return { key: '', username: '', avatarUrl: '', href: '', postNumber: 0 };
}

interface InlineStyle {
  tag: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  href: string;
}

interface NumberedList {
  tag: string;
  next: number;
}

/** Reject local, executable and credential-bearing URLs. */
export function postContentUrl(value: string): string {
  const trimmed: string = decodePostEntities(value).trim();
  if (!trimmed || /[\u0000-\u0020\u007f\\]/.test(trimmed)) {
    return '';
  }
  let candidate: string = trimmed;
  if (candidate.startsWith('//')) {
    candidate = `https:${candidate}`;
  } else if (candidate.startsWith('/')) {
    candidate = `https://linux.do${candidate}`;
  } else if (!/^[a-z][a-z0-9+.-]*:/i.test(candidate)) {
    candidate = `https://linux.do/${candidate}`;
  }
  if (!/^https?:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?(?:[/?#]|$)/i.test(candidate)) {
    return '';
  }
  return candidate.replace(/^https:/i, 'https:').replace(/^http:/i, 'http:');
}

export function decodePostEntities(value: string): string {
  return value.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/gi,
    (entity: string): string => {
      const body: string = entity.slice(1, -1).toLowerCase();
      if (body === 'amp') { return '&'; }
      if (body === 'lt') { return '<'; }
      if (body === 'gt') { return '>'; }
      if (body === 'quot') { return '"'; }
      if (body === 'apos') { return "'"; }
      if (body === 'nbsp') { return ' '; }
      const numeric: number = body.startsWith('#x') ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return Number.isFinite(numeric) && numeric > 0 && numeric <= 0x10ffff &&
        !(numeric >= 0xd800 && numeric <= 0xdfff) ? String.fromCodePoint(numeric) : '';
    });
}

function attribute(tag: string, name: string): string {
  const matcher: RegExp = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i');
  const match: RegExpExecArray | null = matcher.exec(tag);
  return match === null ? '' : (match[1] || match[2] || match[3] || '');
}

function emptyStyle(tag: string): InlineStyle {
  return { tag: tag, bold: false, italic: false, code: false, href: '' };
}

/** A bounded, tolerant scanner. Only allowlisted presentation semantics are retained. */
export function parsePostContent(cooked: string): PostBlock[] {
  const source: string = cooked.slice(0, 262144);
  const tokens: string[] = source.match(/<!--[\s\S]*?-->|<[^>]*>|[^<]+|</g) || [];
  const blocks: PostBlock[] = [];
  const styles: InlineStyle[] = [emptyStyle('')];
  const lists: NumberedList[] = [];
  const excluded: string[] = [];
  let runs: PostInline[] = [];
  let quoteDepth: number = 0;
  const quoteTags: PostQuoteContext[] = [];
  let nextQuoteId: number = 0;
  let titleContext: PostQuoteContext | undefined = undefined;
  let titleDivDepth: number = 0;
  let titleText: string = '';
  let preDepth: number = 0;
  let codeLanguage: string = '';
  let heading: boolean = false;
  let runIndex: number = 0;
  let listPrefix: string = '';
  const flush = (): void => {
    if (runs.some((run: PostInline): boolean => run.text.trim().length > 0 || run.emojiUrl.length > 0)) {
      blocks.push({ key: `block-${blocks.length}`, kind: preDepth > 0 ? 'code' : 'paragraph',
        runs: runs, quote: quoteDepth > 0, url: '', description: '', heading: heading, imageWidth: 0, imageHeight: 0,
        quoteGroupId: quoteTags[0]?.groupId ?? '', quoteLevel: quoteTags[quoteTags.length - 1]?.level ?? 0,
        codeLanguage: preDepth > 0 ? codeLanguage : '' });
    }
    runs = [];
  };
  const finishQuoteTitle = (): void => {
    if (titleContext !== undefined) {
      const label: string = titleText.replace(/\s+/g, ' ').trim().replace(/[:：]\s*$/, '');
      if (label) { titleContext.header.username = label; }
    }
    titleContext = undefined; titleDivDepth = 0; titleText = '';
  };
  const append = (text: string, emojiUrl: string = ''): void => {
    const current: InlineStyle = styles[styles.length - 1];
    if (listPrefix && (text.trim().length > 0 || emojiUrl.length > 0)) {
      runs.push({ key: `run-${runIndex++}`, text: listPrefix, bold: current.bold, italic: current.italic,
        code: current.code || preDepth > 0, href: '', emojiUrl: '' });
      listPrefix = '';
    }
    runs.push({ key: `run-${runIndex++}`, text: text, bold: current.bold, italic: current.italic,
      code: current.code || preDepth > 0, href: current.href, emojiUrl: emojiUrl });
  };
  for (const token of tokens) {
    if (token.startsWith('<!--')) { continue; }
    if (!token.startsWith('<') || token === '<') {
      if (excluded.length === 0) {
        const text: string = decodePostEntities(token);
        if (titleContext !== undefined) { titleText += text; }
        else { append(preDepth > 0 ? text : text.replace(/[\t\r\n ]+/g, ' ')); }
      }
      continue;
    }
    const match: RegExpExecArray | null = /^<\s*(\/?)\s*([a-z0-9]+)/i.exec(token);
    if (match === null) { continue; }
    const closing: boolean = match[1] === '/';
    const tag: string = match[2].toLowerCase();
    const voidTag: boolean = /^(img|br|hr|input|meta|link|source|wbr)$/.test(tag) || /\/\s*>$/.test(token);
    const forbidden: boolean = /^(script|style|noscript|iframe|object|embed|svg|math|form|button|input|textarea)$/.test(tag);
    const hidden: boolean = /(^|\s)(meta|filename|informations)(\s|$)/.test(attribute(token, 'class')) ||
      (titleContext !== undefined && /(^|\s)quote-controls(\s|$)/.test(attribute(token, 'class')));
    if (excluded.length > 0) {
      if (closing && tag === excluded[excluded.length - 1]) { excluded.pop(); }
      else if (!closing && !voidTag && (forbidden || tag === excluded[excluded.length - 1])) { excluded.push(tag); }
      continue;
    }
    if (!closing && (forbidden || hidden)) {
      if (!voidTag) { excluded.push(tag); }
      continue;
    }
    // A Discourse quote title is one semantic header, not body paragraphs or a gallery image.
    // A malformed missing </div> must not consume the following blockquote body.
    if (titleContext !== undefined && ((!closing && tag === 'blockquote') || (closing && tag === 'aside'))) {
      finishQuoteTitle();
    }
    if (titleContext !== undefined) {
      if (tag === 'div') {
        titleDivDepth += closing ? -1 : 1;
        if (titleDivDepth <= 0) { finishQuoteTitle(); }
      } else if (tag === 'img' && !closing) {
        const image: string = postContentUrl(attribute(token, 'src'));
        const classes: string = attribute(token, 'class').toLowerCase();
        if (!titleContext.header.avatarUrl && !/(^|\s)emoji(?:-custom)?(\s|$)/.test(classes) && image.startsWith('https://')) {
          titleContext.header.avatarUrl = image;
        }
      } else if (tag === 'a' && !closing && !titleContext.header.href) {
        titleContext.header.href = postQuoteTarget('', '', attribute(token, 'href'));
      }
      continue;
    }
    const activeQuote: PostQuoteContext | undefined = quoteTags[quoteTags.length - 1];
    if (!closing && tag === 'div' && activeQuote?.tag === 'aside' && !activeQuote.titleSeen &&
      /(^|\s)title(\s|$)/.test(attribute(token, 'class'))) {
      flush(); activeQuote.titleSeen = true; titleContext = activeQuote; titleDivDepth = 1; titleText = '';
      continue;
    }
    if (tag === 'br') { append('\n'); continue; }
    if (tag === 'hr') {
      flush();
      blocks.push({ key: `block-${blocks.length}`, kind: 'divider', runs: [], quote: quoteDepth > 0,
        quoteGroupId: quoteTags[0]?.groupId ?? '', quoteLevel: quoteTags[quoteTags.length - 1]?.level ?? 0,
        url: '', description: '', heading: false, imageWidth: 0, imageHeight: 0 });
      continue;
    }
    if (tag === 'img' && !closing) {
      const sourceUrl: string = postContentUrl(attribute(token, 'src'));
      let imageUrl: string = sourceUrl;
      const srcset: string[] = attribute(token, 'srcset').split(',');
      if (srcset.length > 0) {
        const last: string = postContentUrl(srcset[srcset.length - 1].trim().split(/\s+/)[0]);
        if (last) { imageUrl = last; }
      }
      const classes: string[] = decodePostEntities(attribute(token, 'class')).toLowerCase().split(/\s+/);
      // Some cooked/imported posts omit the class on built-in emoji. Recognize
      // the forum's dedicated path, never a filename or an arbitrary small image.
      const emoji: boolean = classes.includes('emoji') || classes.includes('emoji-custom') ||
        /^https:\/\/(?:www\.)?linux\.do(?::443)?\/images\/emoji\//i.test(sourceUrl);
      const width: number = Number(attribute(token, 'width'));
      const height: number = Number(attribute(token, 'height'));
      // Discourse onebox headers use a 32 px site icon, separate from their large thumbnail.
      const siteIcon: boolean = classes.includes('site-icon') && width > 0 && width <= 40 && height > 0 && height <= 40;
      const alt: string = decodePostEntities(attribute(token, 'alt')) || (siteIcon ? '链接图标' : emoji ? '表情' : '');
      if (emoji || siteIcon) {
        append(alt, imageUrl);
      } else if (imageUrl) {
        flush();
        const href: string = styles[styles.length - 1].href;
        const original: string = /\/(?:uploads|user_avatar)\//.test(href) || /\.(?:jpe?g|png|gif|webp|avif|heic)(?:[?#]|$)/i.test(href) ? href : imageUrl;
        const originalWidth: number = Number(attribute(token, 'data-orig-width'));
        const originalHeight: number = Number(attribute(token, 'data-orig-height'));
        const hasOriginalSize: boolean = originalWidth > 0 && originalHeight > 0 &&
          Number.isFinite(originalWidth) && Number.isFinite(originalHeight);
        blocks.push({ key: `block-${blocks.length}`, kind: 'image', runs: [], quote: quoteDepth > 0,
          quoteGroupId: quoteTags[0]?.groupId ?? '', quoteLevel: quoteTags[quoteTags.length - 1]?.level ?? 0,
          url: original, description: alt, heading: false,
          imageWidth: hasOriginalSize ? originalWidth : Number.isFinite(width) && width > 0 ? width : 0,
          imageHeight: hasOriginalSize ? originalHeight : Number.isFinite(height) && height > 0 ? height : 0,
          imageDisplayWidth: Number.isFinite(width) && width > 0 ? width : 0 });
      } else { append(alt); }
      continue;
    }
    const blockTag: boolean = /^(p|div|section|article|details|summary|figure|figcaption|h[1-6]|blockquote|aside|pre|ul|ol|li|tr|table)$/.test(tag);
    if (blockTag) { flush(); }
    if (!closing && (tag === 'blockquote' || (tag === 'aside' && /(^|\s)quote(\s|$)/.test(attribute(token, 'class').toLowerCase())))) {
      const parent: PostQuoteContext | undefined = quoteTags[quoteTags.length - 1];
      const quoteKey: string = `quote-${nextQuoteId++}`;
      const level: number = parent === undefined ? 1 : tag === 'blockquote' && parent.tag === 'aside' ? parent.level : parent.level + 1;
      const topic: string = attribute(token, 'data-topic');
      const post: string = attribute(token, 'data-post');
      const number: number = Number(post);
      const header: PostQuoteHeader = { key: quoteKey, username: decodePostEntities(attribute(token, 'data-username')),
        avatarUrl: '', href: postQuoteTarget(topic, post), postNumber: Number.isSafeInteger(number) && number > 0 ? number : 0 };
      const context: PostQuoteContext = { tag: tag, groupId: quoteTags[0]?.groupId ?? quoteKey,
        level: level, header: header, titleSeen: false };
      quoteTags.push(context);
      quoteDepth++;
      if (tag === 'aside') {
        blocks.push({ key: `quote-header-${quoteKey}`, kind: 'quote_header', runs: [], quote: true,
          quoteGroupId: context.groupId, quoteLevel: level, quoteHeader: header,
          url: '', description: '', heading: false, imageWidth: 0, imageHeight: 0 });
      }
    } else if (closing && quoteTags[quoteTags.length - 1]?.tag === tag) {
      quoteTags.pop();
      quoteDepth = Math.max(0, quoteDepth - 1);
    }
    if (tag === 'pre') {
      preDepth = Math.max(0, preDepth + (closing ? -1 : 1));
      if (preDepth === 0 || !closing) { codeLanguage = ''; }
    }
    if (tag === 'code' && !closing && preDepth > 0) {
      const language: RegExpExecArray | null = /(?:^|\s)(?:language|lang)-([a-z0-9_+#.-]{1,32})(?:\s|$)/i
        .exec(attribute(token, 'class'));
      codeLanguage = language === null ? '' : language[1];
    }
    if (/^h[1-6]$/.test(tag)) { heading = !closing; }
    if (tag === 'ul' || tag === 'ol') {
      if (closing) { lists.pop(); }
      else { lists.push({ tag: tag, next: Math.max(1, parseInt(attribute(token, 'start'), 10) || 1) }); }
    }
    if (tag === 'li' && !closing) {
      const list: NumberedList | undefined = lists[lists.length - 1];
      listPrefix = list !== undefined && list.tag === 'ol' ? `${list.next++}. ` : '• ';
    }
    if (tag === 'li' && closing) { listPrefix = ''; }
    if ((tag === 'td' || tag === 'th') && closing) { append('  |  '); }
    if (/^(b|strong|em|i|code|a)$/.test(tag)) {
      if (closing) {
        let index: number = styles.length - 1;
        while (index > 0 && styles[index].tag !== tag) { index--; }
        if (index > 0) { styles.splice(index); }
      } else {
        const previous: InlineStyle = styles[styles.length - 1];
        styles.push({ tag: tag, bold: previous.bold || tag === 'b' || tag === 'strong',
          italic: previous.italic || tag === 'em' || tag === 'i', code: previous.code || tag === 'code',
          href: tag === 'a' ? postContentUrl(attribute(token, 'href')) : previous.href });
      }
    }
  }
  finishQuoteTitle();
  flush();
  return blocks;
}

export interface PostImageLayout {
  previewWidth: number;
  previewHeight: number;
  imageHeight: number;
  cropped: boolean;
}

/** Fit large pictures to the body while preserving the author's small image size. */
export function postImageLayout(width: number, height: number, availableWidth: number, compact: boolean,
  displayWidth: number = 0): PostImageLayout {
  const bodyWidth: number = Number.isFinite(availableWidth) && availableWidth > 0 ? availableWidth : 320;
  const ratio: number = Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0 ? width / height : 4 / 3;
  const preferredWidth: number = Number.isFinite(displayWidth) && displayWidth > 0 ? displayWidth :
    Number.isFinite(width) && width > 0 ? width : bodyWidth;
  const previewWidth: number = Math.min(bodyWidth, preferredWidth);
  const imageHeight: number = previewWidth / ratio;
  const limit: number = bodyWidth * (compact ? 1 : 2);
  return { previewWidth: previewWidth, previewHeight: Math.min(imageHeight, limit),
    imageHeight: imageHeight, cropped: imageHeight > limit };
}

@ComponentV2
struct PostContentImage {
  @Param url: string = '';
  @Param description: string = '';
  @Param sourceWidth: number = 0;
  @Param sourceHeight: number = 0;
  @Param displayWidth: number = 0;
  @Param compact: boolean = false;
  @Param ownerId: number = 0;
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Local bodyWidth: number = 320;
  @Local naturalWidth: number = 0;
  @Local naturalHeight: number = 0;

  @Monitor('url', 'ownerId')
  imageChanged(): void {
    this.naturalWidth = 0;
    this.naturalHeight = 0;
  }
  @Computed
  get imageLayout(): PostImageLayout {
    return postImageLayout(this.naturalWidth || this.sourceWidth, this.naturalHeight || this.sourceHeight,
      this.bodyWidth, this.compact, this.displayWidth);
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        NativeForumImage({ url: this.url, fit: ImageFit.Contain, previewImageAspectRatio: 0,
          accessibleLabel: this.description || '帖子图片', ownerId: this.ownerId,
          onNaturalSize: (width: number, height: number): void => {
            if (this.naturalWidth !== width || this.naturalHeight !== height) {
              this.naturalWidth = width;
              this.naturalHeight = height;
            }
          } })
          .width('100%').height(this.imageLayout.imageHeight)
        if (this.imageLayout.cropped) {
          Row() {
            Text('长图 · 点击查看完整图片').fontSize(12).fontColor(Color.White).padding({ left: 12, right: 12 })
          }.width('100%').height(30).backgroundColor('#99000000')
            .position({ x: 0, y: this.imageLayout.previewHeight - 30 })
        }
      }.width(this.imageLayout.previewWidth).height(this.imageLayout.previewHeight).clip(true).borderRadius(8)
        .backgroundColor($r('app.color.selected_background'))
        .accessibilityText((this.description ? this.description + '，' : '') + '点击查看大图')
        .onClick((): void => this.onPicture(this.url))
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const width: number = Number(newArea.width);
        if (Number.isFinite(width) && width > 0 && Math.abs(this.bodyWidth - width) > 0.5) { this.bodyWidth = width; }
      })
  }
}

@ComponentV2
struct PostContentQuoteHeader {
  @Param quoteHeader: PostQuoteHeader = emptyPostQuoteHeader();
  @Param ownerId: number = 0;
  @Param canCollapse: boolean = false;
  @Param quoteCollapsed: boolean = false;
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onToggleQuote: () => void = (): void => {};

  build() {
    Row({ space: 6 }) {
      Row({ space: 8 }) {
        if (this.quoteHeader.avatarUrl) {
          NativeForumImage({ url: this.quoteHeader.avatarUrl, fit: ImageFit.Cover, previewImageAspectRatio: 0,
            ownerId: this.ownerId, accessibleLabel: `${this.quoteHeader.username || '引用作者'}的头像` })
            .width(20).height(20).borderRadius(10).clip(true)
        }
        Text(this.quoteHeader.username || '引用').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.quoteHeader.postNumber > 0) {
          Text(`#${this.quoteHeader.postNumber}`).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).constraintSize({ minHeight: 32 })
        .onClick((): void => { if (this.quoteHeader.href) { this.onOpenLink(this.quoteHeader.href); } })
      if (this.quoteHeader.href) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.link')).fontSize(17).fontColor([$r('app.color.text_secondary')])
        }.width(32).height(32).backgroundColor(Color.Transparent).accessibilityText('查看引用原楼')
          .onClick((): void => { this.onOpenLink(this.quoteHeader.href); })
      }
      if (this.canCollapse) {
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Row({ space: 5 }) {
            SymbolGlyph(this.quoteCollapsed ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
              .fontSize(12).fontColor([$r('app.color.text_secondary')])
            Text(this.quoteCollapsed ? '展开' : '收起').fontSize(12).fontColor($r('app.color.text_secondary'))
          }
        }.height(32).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
          .accessibilityText(this.quoteCollapsed ? '展开引用内容' : '收起引用内容').onClick(this.onToggleQuote)
      }
    }.width('100%').constraintSize({ minHeight: 32 })
  }
}

@ComponentV2
struct PostContentBlockView {
  @Param postBlock: PostBlock = emptyPostBlock();
  @Param quoted: boolean = false;
  @Param compact: boolean = false;
  @Param inlineContent: boolean = false;
  @Param ownerId: number = 0;
  @Param emojiUris: Map<string, string> = new Map<string, string>();
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};

  build() {
    Column() {
      if (this.postBlock.kind === 'quote_header') {
        PostContentQuoteHeader({ quoteHeader: this.postBlock.quoteHeader ?? emptyPostQuoteHeader(),
          ownerId: this.ownerId, onOpenLink: this.onOpenLink })
      } else if (this.postBlock.kind === 'divider') {
        Divider().color($r('app.color.divider')).margin({ top: 8, bottom: 8 })
      } else if (this.postBlock.kind === 'image') {
        PostContentImage({ url: this.postBlock.url, description: this.postBlock.description,
          sourceWidth: this.postBlock.imageWidth, sourceHeight: this.postBlock.imageHeight,
          displayWidth: this.postBlock.imageDisplayWidth || 0,
          compact: this.compact, ownerId: this.ownerId,
          onPicture: this.onPicture }).width('100%')
      } else {
        Column({ space: 0 }) {
          if (this.postBlock.kind === 'code') {
            Text(this.postBlock.codeLanguage || '代码').fontSize(11).fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 11, bottom: 11 }).width('100%')
            Divider().color($r('app.color.divider'))
          }
          Text() {
            ForEach(this.postBlock.runs, (run: PostInline) => {
              if (run.emojiUrl && this.emojiUris.has(run.emojiUrl)) {
                ImageSpan(this.emojiUris.get(run.emojiUrl) || '')
                  .width(this.inlineContent ? 16 : this.compact ? 18 : 22)
                  .height(this.inlineContent ? 16 : this.compact ? 18 : 22)
                  .objectFit(ImageFit.Contain).verticalAlign(ImageSpanAlignment.CENTER)
              } else {
                Span(run.text)
                  .fontWeight(run.bold || this.postBlock.heading ? FontWeight.Medium : FontWeight.Normal)
                  .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
                  .fontFamily(run.code || this.postBlock.kind === 'code' ? 'monospace' : 'HarmonyOS Sans')
                  .fontColor(run.href ? $r('app.color.accent') : $r('app.color.text_primary'))
                  .decoration({ type: run.href ? TextDecorationType.Underline : TextDecorationType.None })
                  .onClick((): void => { if (run.href) { this.onOpenLink(run.href); } })
              }
            }, (run: PostInline): string => run.key)
          }.fontSize(this.inlineContent ? 13 : this.postBlock.kind === 'code' ? 14 : this.quoted ? 16 : this.postBlock.heading ? 21 : this.compact ? 14 : 17)
            .lineHeight(this.inlineContent ? 20 : this.postBlock.kind === 'code' || this.quoted ? 24 : this.compact ? 22 : 28)
            .textAlign(TextAlign.Start).width(this.inlineContent ? 'auto' : '100%').copyOption(CopyOptions.InApp)
            .padding(this.postBlock.kind === 'code' ? 12 : 0)
        }.width(this.inlineContent ? 'auto' : '100%').alignItems(HorizontalAlign.Start)
          .backgroundColor(this.postBlock.kind === 'code' ? $r('app.color.selected_background') : Color.Transparent)
          .borderRadius(this.postBlock.kind === 'code' ? 10 : 0).clip(this.postBlock.kind === 'code')
      }
    }.width(this.inlineContent ? 'auto' : '100%').alignItems(HorizontalAlign.Start)
      .padding({ left: this.quoted ? Math.min(3, Math.max(0, (this.postBlock.quoteLevel ?? 1) - 1)) * 10 : 0 })
  }
}

@ComponentV2
struct PostContentQuoteGroup {
  @Param contentGroup: PostContentGroup = { key: '', quote: true, blocks: [] };
  @Param compact: boolean = false;
  @Param ownerId: number = 0;
  @Param emojiUris: Map<string, string> = new Map<string, string>();
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Local quoteCollapsed: boolean = false;

  @Monitor('contentGroup')
  quoteChanged(): void { this.quoteCollapsed = false; }

  @Computed
  get visibleBlocks(): PostBlock[] { return visiblePostQuoteBlocks(this.contentGroup, this.quoteCollapsed); }

  build() {
    Column({ space: 8 }) {
      if (postQuoteCanCollapse(this.contentGroup)) {
        PostContentQuoteHeader({ quoteHeader: this.contentGroup.header ?? emptyPostQuoteHeader(), ownerId: this.ownerId,
          canCollapse: true, quoteCollapsed: this.quoteCollapsed, onOpenLink: this.onOpenLink,
          onToggleQuote: (): void => { this.quoteCollapsed = !this.quoteCollapsed; } })
      }
      ForEach(this.visibleBlocks, (block: PostBlock) => {
        PostContentBlockView({ postBlock: block, quoted: true, compact: this.compact, ownerId: this.ownerId,
          emojiUris: this.emojiUris, onOpenLink: this.onOpenLink, onPicture: this.onPicture })
      }, (block: PostBlock): string => block.key)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
      .backgroundColor($r('app.color.boost_background')).borderRadius(8)
      .border({ width: { left: 3 }, color: $r('app.color.divider') })
  }
}

@ComponentV2
export struct RichPostContent {
  @Param cooked: string = '';
  @Param compact: boolean = false;
  @Param inlineContent: boolean = false;
  @Param reduceMotion: boolean = false;
  @Param session: ForumSession = forumSession;
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};
  @Event onPicture: (url: string) => void = (_url: string): void => {};
  @Local emojiUris: Map<string, string> = new Map<string, string>();
  private emojiRequest: RequestCancellation | undefined = undefined;
  private visible: boolean = false;

  @Monitor('cooked', 'session.revision')
  contentChanged(): void {
    this.emojiRequest?.cancel();
    this.emojiRequest = undefined;
    this.emojiUris = new Map<string, string>();
    if (this.visible) { this.loadEmojis(); }
  }

  aboutToDisappear(): void {
    this.emojiRequest?.cancel();
    this.emojiRequest = undefined;
  }

  private async loadEmojis(): Promise<void> {
    if (this.emojiRequest !== undefined) { return; }
    const urls: string[] = Array.from(new Set<string>(this.blocks.flatMap((block: PostBlock): string[] =>
      block.runs.map((run: PostInline): string => run.emojiUrl)).filter((url: string): boolean =>
        url.startsWith('https://') && !this.emojiUris.has(url))));
    if (urls.length === 0) { return; }
    const owner: number = this.session.user?.id || 0;
    const revision: number = this.session.revision;
    const cancellation: RequestCancellation = new RequestCancellation();
    this.emojiRequest = cancellation;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      for (const url of urls) {
        let uri: string = '';
        try { uri = await loadForumMedia(url, context, cancellation); }
        catch { /* Keep this alt readable and continue loading the other emoji. */ }
        if (this.emojiRequest !== cancellation || cancellation.isCancelled ||
          owner !== (this.session.user?.id || 0) || revision !== this.session.revision) { return; }
        if (!uri) { continue; }
        const updated: Map<string, string> = new Map<string, string>(this.emojiUris);
        updated.set(url, uri);
        this.emojiUris = updated;
      }
    } finally { if (this.emojiRequest === cancellation) { this.emojiRequest = undefined; } }
  }

  @Computed
  get blocks(): PostBlock[] { return parsePostContent(this.cooked); }

  @Computed
  get groups(): PostContentGroup[] { return groupPostContent(this.blocks); }

  build() {
    Column({ space: this.inlineContent ? 0 : this.compact ? 6 : 8 }) {
      ForEach(this.groups, (group: PostContentGroup) => {
        if (group.quote) {
          PostContentQuoteGroup({ contentGroup: group, compact: this.compact,
            ownerId: this.session.user?.id || 0, emojiUris: this.emojiUris,
            onOpenLink: this.onOpenLink, onPicture: this.onPicture })
        } else {
          ForEach(group.blocks, (block: PostBlock) => {
            PostContentBlockView({ postBlock: block, compact: this.compact, inlineContent: this.inlineContent,
              ownerId: this.session.user?.id || 0, emojiUris: this.emojiUris,
              onOpenLink: this.onOpenLink, onPicture: this.onPicture })
          }, (block: PostBlock): string => block.key)
        }
      }, (group: PostContentGroup): string => group.key)
    }.width(this.inlineContent ? 'auto' : '100%').alignItems(HorizontalAlign.Start)
      .onVisibleAreaChange([0.01], (visible: boolean): void => {
        this.visible = visible;
        if (visible) { this.loadEmojis(); }
        else { this.emojiRequest?.cancel(); this.emojiRequest = undefined; }
      })
  }
}
