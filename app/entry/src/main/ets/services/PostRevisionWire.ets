import { avatarUrlOf } from '../models/ForumModels';
import { PostRevisionMetadataChange, PostRevisionRecord } from '../models/PostRevisionModels';

interface PostRevisionDiffWire { inline?: string; }
interface PostRevisionUserWire { username?: string; display_username?: string; }
interface PostRevisionChangeWire<T> { previous?: T; current?: T; }
export interface PostRevisionWire {
  post_id?: number; created_at?: string; username?: string; display_username?: string; acting_user_name?: string;
  avatar_template?: string; edit_reason?: string;
  first_revision?: number; previous_revision?: number; current_revision?: number; next_revision?: number; last_revision?: number;
  current_version?: number; version_count?: number; previous_hidden?: boolean; current_hidden?: boolean; diff_error?: boolean;
  body_changes?: PostRevisionDiffWire; title_changes?: PostRevisionDiffWire;
  tags_changes?: PostRevisionChangeWire<string[]>;
  wiki_changes?: PostRevisionChangeWire<boolean>;
  user_changes?: PostRevisionChangeWire<PostRevisionUserWire>;
  locale_changes?: PostRevisionChangeWire<string>;
}

function revisionNumber(value: number | undefined): number {
  if (!Number.isSafeInteger(value) || (value ?? 0) < 2) { throw new Error('Invalid revision'); }
  return value ?? 0;
}

function revisionText(value: string | undefined): string { return typeof value === 'string' ? value : ''; }
function revisionTags(values: string[] | undefined): string {
  return Array.isArray(values) ? values.filter((value: string): boolean => typeof value === 'string').join('、') : '';
}

export function postRevisionFromWire(wire: PostRevisionWire, postId: number, requestedRevision: number = 0): PostRevisionRecord {
  if (!Number.isSafeInteger(postId) || postId <= 0 || wire.post_id !== postId) { throw new Error('Invalid revision post'); }
  const current: number = revisionNumber(wire.current_revision);
  const first: number = revisionNumber(wire.first_revision);
  const last: number = revisionNumber(wire.last_revision);
  if (first > current || last < current || (requestedRevision > 0 && current !== requestedRevision) ||
    !Number.isSafeInteger(wire.current_version) || (wire.current_version ?? 0) < 2 ||
    !Number.isSafeInteger(wire.version_count) || (wire.version_count ?? 0) < (wire.current_version ?? 0)) {
    throw new Error('Invalid revision range');
  }
  let previous: number | undefined = undefined;
  let next: number | undefined = undefined;
  if (wire.previous_revision !== undefined && wire.previous_revision !== null) {
    previous = revisionNumber(wire.previous_revision);
    if (previous < first || previous >= current) { throw new Error('Invalid previous revision'); }
  }
  if (wire.next_revision !== undefined && wire.next_revision !== null) {
    next = revisionNumber(wire.next_revision);
    if (next > last || next <= current) { throw new Error('Invalid next revision'); }
  }
  const metadata: PostRevisionMetadataChange[] = [];
  if (wire.tags_changes !== undefined && wire.tags_changes !== null) {
    metadata.push({ label: '标签', previous: revisionTags(wire.tags_changes.previous), current: revisionTags(wire.tags_changes.current) });
  }
  if (wire.wiki_changes !== undefined && wire.wiki_changes !== null) {
    metadata.push({ label: '维基模式', previous: typeof wire.wiki_changes.previous !== 'boolean' ? '未提供' :
      wire.wiki_changes.previous ? '开启' : '关闭', current: typeof wire.wiki_changes.current !== 'boolean' ? '未提供' :
      wire.wiki_changes.current ? '开启' : '关闭' });
  }
  if (wire.user_changes !== undefined && wire.user_changes !== null) {
    metadata.push({ label: '作者', previous: revisionText(wire.user_changes.previous?.display_username || wire.user_changes.previous?.username),
      current: revisionText(wire.user_changes.current?.display_username || wire.user_changes.current?.username) });
  }
  if (wire.locale_changes !== undefined && wire.locale_changes !== null) {
    metadata.push({ label: '语言', previous: revisionText(wire.locale_changes.previous), current: revisionText(wire.locale_changes.current) });
  }
  return {
    postId: postId, currentRevision: current, firstRevision: first, lastRevision: last,
    previousRevision: previous, nextRevision: next, currentVersion: wire.current_version ?? 0, versionCount: wire.version_count ?? 0,
    createdAt: revisionText(wire.created_at), editorUsername: revisionText(wire.display_username || wire.username),
    editorName: revisionText(wire.acting_user_name), avatarUrl: avatarUrlOf(revisionText(wire.avatar_template)),
    editReason: revisionText(wire.edit_reason), bodyDiffHtml: revisionText(wire.body_changes?.inline),
    titleDiffHtml: revisionText(wire.title_changes?.inline), previousHidden: wire.previous_hidden === true,
    currentHidden: wire.current_hidden === true, diffError: wire.diff_error === true, metadataChanges: metadata
  };
}

interface RevisionDiffTag { tag: string; marker: string; }

/** Preserve the server comparison and make its additions/deletions readable in the existing native allowlist renderer. */
export function revisionDiffForReading(html: string): string {
  const tokens: string[] = html.slice(0, 131072).match(/<!--[\s\S]*?-->|<[^>]*>|[^<]+|</g) || [];
  const stack: RevisionDiffTag[] = [];
  const output: string[] = [];
  for (const token of tokens) {
    const match: RegExpExecArray | null = /^<\s*(\/?)\s*([a-z0-9]+)/i.exec(token);
    if (match === null || token.startsWith('<!--')) { output.push(token); continue; }
    const tag: string = match[2].toLowerCase();
    if (match[1] === '/') {
      let index: number = stack.length - 1;
      while (index >= 0 && stack[index].tag !== tag) { index--; }
      if (index >= 0) {
        for (let closed: number = stack.length - 1; closed >= index; closed--) {
          if (stack[closed].marker) { output.push(`<strong>【/${stack[closed].marker}】</strong>`); }
        }
        stack.splice(index);
      }
      output.push(token); continue;
    }
    const classes: RegExpExecArray | null = /\bclass\s*=\s*["']([^"']*)["']/i.exec(token);
    const classList: string[] = classes === null ? [] : classes[1].split(/\s+/);
    const marker: string = tag === 'ins' || classList.includes('diff-ins') ? '新增' :
      tag === 'del' || classList.includes('diff-del') ? '删除' : '';
    const voidTag: boolean = /^(img|br|hr|input|meta|link|source|wbr)$/.test(tag) || /\/\s*>$/.test(token);
    if (voidTag && marker) { output.push(`<strong>【${marker}】</strong>`); }
    output.push(token);
    if (!voidTag) {
      stack.push({ tag: tag, marker: marker });
      if (marker) { output.push(`<strong>【${marker}】</strong>`); }
    }
  }
  return output.join('');
}
