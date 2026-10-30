import { preferences } from '@kit.ArkData';

export const LOCAL_DRAFT_STORE: string = 'forum_composer_drafts_v1';
export interface DraftTarget {
  key: string;
  ownerId: number;
  creatingTopic: boolean;
  topicId: number;
  replyTo: number;
  postId: number;
}
export interface LocalDraftEntry {
  target: DraftTarget;
  title: string;
  context: string;
  excerpt: string;
  updatedAt: number;
  readable: boolean;
}
export interface LocalDraftAttachment { id: string; uri: string; name: string; mime: string; size: number; }
// Selection URIs remain process-local, as before. Deleting a draft also clears
// its in-memory selections; no URI is persisted as a promise of future access.
export const localDraftAttachments: Map<string, LocalDraftAttachment[]> = new Map<string, LocalDraftAttachment[]>();
interface LocalDraftMetadata { version: number; topicTitle: string; updatedAt: number; }
interface StoredTopicDraft { version: number; title: string; categoryId: number; tags: string; raw: string; }

export function draftMetadataKey(key: string): string { return `draft_metadata_v1_${key}`; }

export function parseDraftTarget(key: string, ownerId: number): DraftTarget | undefined {
  if (!Number.isSafeInteger(ownerId) || ownerId <= 0) { return undefined; }
  if (key === `draft_topic_${ownerId}`) {
    return { key: key, ownerId: ownerId, creatingTopic: true, topicId: 0, replyTo: 0, postId: 0 };
  }
  const match: RegExpMatchArray | null = key.match(/^draft_([1-9][0-9]*)_([1-9][0-9]*)_([0-9]+)_([0-9]+)$/);
  if (match === null || Number(match[1]) !== ownerId) { return undefined; }
  const topicId: number = Number(match[2]); const replyTo: number = Number(match[3]); const postId: number = Number(match[4]);
  if (!Number.isSafeInteger(topicId) || !Number.isSafeInteger(replyTo) || !Number.isSafeInteger(postId) ||
    (postId > 0 && replyTo <= 0)) { return undefined; }
  return { key: key, ownerId: ownerId, creatingTopic: false, topicId: topicId, replyTo: replyTo, postId: postId };
}

export async function recordLocalDraftMetadata(store: preferences.Preferences, target: DraftTarget,
  topicTitle: string, updatedAt: number): Promise<void> {
  if (parseDraftTarget(target.key, target.ownerId) === undefined || !Number.isSafeInteger(updatedAt) || updatedAt <= 0) { return; }
  const metadata: LocalDraftMetadata = { version: 1, topicTitle: topicTitle.slice(0, 500), updatedAt: updatedAt };
  await store.put(draftMetadataKey(target.key), JSON.stringify(metadata));
}

function draftMetadata(value: preferences.ValueType | undefined): LocalDraftMetadata | undefined {
  if (typeof value !== 'string' || !value) { return undefined; }
  try {
    const metadata: LocalDraftMetadata = JSON.parse(value) as LocalDraftMetadata;
    if (metadata !== null && metadata.version === 1 && typeof metadata.topicTitle === 'string' &&
      Number.isSafeInteger(metadata.updatedAt) && metadata.updatedAt > 0) { return metadata; }
  } catch {}
  return undefined;
}

export async function listLocalDrafts(store: preferences.Preferences, ownerId: number): Promise<LocalDraftEntry[]> {
  if (!Number.isSafeInteger(ownerId) || ownerId <= 0) { return []; }
  const snapshot: Record<string, preferences.ValueType> = await store.getAll() as Record<string, preferences.ValueType>;
  const entries: LocalDraftEntry[] = [];
  Object.keys(snapshot).forEach((key: string): void => {
    const target: DraftTarget | undefined = parseDraftTarget(key, ownerId);
    const stored: preferences.ValueType = snapshot[key];
    if (target === undefined || typeof stored !== 'string' || !stored.trim()) { return; }
    const metadata: LocalDraftMetadata | undefined = draftMetadata(snapshot[draftMetadataKey(key)]);
    let title: string = metadata?.topicTitle || `话题 #${target.topicId}`;
    let context: string = target.postId > 0 ? `编辑第 ${target.replyTo} 楼` : target.replyTo > 0 ? `回复第 ${target.replyTo} 楼` : '回复话题';
    let raw: string = stored;
    let readable: boolean = true;
    if (target.creatingTopic) {
      context = '新话题';
      try {
        const draft: StoredTopicDraft = JSON.parse(stored) as StoredTopicDraft;
        if (draft === null || draft.version !== 1 || typeof draft.title !== 'string' || typeof draft.raw !== 'string' ||
          typeof draft.tags !== 'string' || !Number.isSafeInteger(draft.categoryId) || draft.categoryId < 0) { throw new Error('Invalid draft'); }
        if (!draft.title.trim() && !draft.raw.trim() && !draft.tags.trim() && draft.categoryId === 0 &&
          (localDraftAttachments.get(key)?.length || 0) === 0) { return; }
        title = draft.title.trim() || '未命名话题'; raw = draft.raw;
        if (draft.categoryId > 0) { context += ` · 分类 #${draft.categoryId}`; }
      } catch { title = '无法读取的草稿'; raw = '草稿格式异常，原始数据已保留。'; readable = false; }
    }
    entries.push({ target: target, title: title, context: context, excerpt: raw.replace(/\s+/g, ' ').trim().slice(0, 180),
      updatedAt: metadata?.updatedAt || 0, readable: readable });
  });
  entries.sort((first: LocalDraftEntry, second: LocalDraftEntry): number => second.updatedAt - first.updatedAt || first.target.key.localeCompare(second.target.key));
  return entries;
}

export async function removeLocalDraft(store: preferences.Preferences, target: DraftTarget, ownerId: number): Promise<void> {
  const parsed: DraftTarget | undefined = parseDraftTarget(target.key, ownerId);
  if (parsed === undefined || target.ownerId !== ownerId || parsed.topicId !== target.topicId || parsed.replyTo !== target.replyTo ||
    parsed.postId !== target.postId || parsed.creatingTopic !== target.creatingTopic) { throw new Error('草稿不属于当前账号'); }
  await store.delete(target.key);
  try { await store.delete(draftMetadataKey(target.key)); } catch {}
  await store.flush();
  localDraftAttachments.delete(target.key);
}
