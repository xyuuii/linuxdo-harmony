import { Post } from './ForumModels';

export interface PostRevisionMetadataChange { label: string; previous: string; current: string; }
export interface PostRevisionRecord {
  postId: number;
  currentRevision: number;
  firstRevision: number;
  lastRevision: number;
  previousRevision?: number;
  nextRevision?: number;
  currentVersion: number;
  versionCount: number;
  createdAt: string;
  editorUsername: string;
  editorName: string;
  avatarUrl: string;
  editReason: string;
  bodyDiffHtml: string;
  titleDiffHtml: string;
  previousHidden: boolean;
  currentHidden: boolean;
  diffError: boolean;
  metadataChanges: PostRevisionMetadataChange[];
}

/** Public version and explicit permission must both come from the current post receipt. */
export function canReadPostHistory(post: Post | undefined): boolean {
  return post !== undefined && post.canViewEditHistory === true && Number.isSafeInteger(post.version) &&
    (post.version ?? 0) > 1;
}
