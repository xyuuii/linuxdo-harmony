import { Category, flattenCategories } from './ForumModels';

export enum DirectorySection { Categories = 'categories', Tags = 'tags', Badges = 'badges', Groups = 'groups' }
export interface DirectorySectionOption { value: DirectorySection; label: string; }
export const directorySections: DirectorySectionOption[] = [
  { value: DirectorySection.Categories, label: '分类' }, { value: DirectorySection.Tags, label: '标签' },
  { value: DirectorySection.Badges, label: '徽章' }, { value: DirectorySection.Groups, label: '群组' }
];
export interface DirectoryTag { id: number; name: string; slug: string; description: string; topicCount: number; }
export interface DirectoryTagPage { items: DirectoryTag[]; hasMore: boolean; total: number; }
export interface DirectoryBadge {
  id: number; name: string; description: string; longDescription: string;
  grantCount: number; hasBadge: boolean; badgeType: number; groupId: number; groupName: string;
}
export interface DirectoryGroup {
  id: number; name: string; displayName: string; description: string; userCount: number;
  automatic: boolean; joined: boolean; publicAdmission: boolean; allowMembershipRequests: boolean;
}
export interface DirectoryGroupPage { items: DirectoryGroup[]; hasMore: boolean; total: number; }
export interface DirectoryCategoryRow {
  category: Category; depth: number; childCount: number; totalTopicCount: number;
}

/** Keep hierarchy context when searching a child, without exposing hidden siblings. */
export function directoryCategoryRows(categories: Category[], query: string, expandedIds: number[]): DirectoryCategoryRow[] {
  const all: Category[] = flattenCategories(categories);
  const byId: Map<number, Category> = new Map<number, Category>();
  all.forEach((category: Category): void => { byId.set(category.id, category); });
  const children: Map<number, Category[]> = new Map<number, Category[]>();
  const roots: Category[] = [];
  byId.forEach((category: Category): void => {
    if (byId.has(category.parentCategoryId) && category.parentCategoryId !== category.id) {
      const siblings: Category[] = children.get(category.parentCategoryId) ?? [];
      siblings.push(category); children.set(category.parentCategoryId, siblings);
    } else { roots.push(category); }
  });
  const term: string = query.trim().toLocaleLowerCase();
  const included: Set<number> = new Set<number>();
  if (term) {
    byId.forEach((category: Category): void => {
      if (`${category.name} ${category.description}`.toLocaleLowerCase().indexOf(term) < 0) { return; }
      let current: Category | undefined = category;
      const ancestry: Set<number> = new Set<number>();
      while (current !== undefined && !ancestry.has(current.id)) {
        ancestry.add(current.id); included.add(current.id); current = byId.get(current.parentCategoryId);
      }
    });
  }
  const result: DirectoryCategoryRow[] = [];
  const visited: Set<number> = new Set<number>();
  const pending: DirectoryCategoryRow[] = roots.map((category: Category): DirectoryCategoryRow => {
    return { category: category, depth: 0, childCount: 0, totalTopicCount: 0 };
  }).reverse();
  while (pending.length > 0) {
    const row: DirectoryCategoryRow | undefined = pending.pop();
    if (row === undefined || visited.has(row.category.id) || row.depth > 16) { continue; }
    visited.add(row.category.id);
    if (term && !included.has(row.category.id)) { continue; }
    const descendants: Category[] = children.get(row.category.id) ?? [];
    row.childCount = descendants.length;
    const counted: Set<number> = new Set<number>();
    const countQueue: Category[] = [row.category];
    while (countQueue.length > 0) {
      const category: Category | undefined = countQueue.pop();
      if (category === undefined || counted.has(category.id)) { continue; }
      counted.add(category.id); row.totalTopicCount += Math.max(0, category.topicCount);
      const nested: Category[] = children.get(category.id) ?? [];
      nested.forEach((child: Category): void => { countQueue.push(child); });
    }
    result.push(row);
    if (term || expandedIds.indexOf(row.category.id) >= 0) {
      descendants.slice().reverse().forEach((category: Category): void => {
        pending.push({ category: category, depth: row.depth + 1, childCount: 0, totalTopicCount: 0 });
      });
    }
  }
  return result;
}

export function directoryTagPage(tags: DirectoryTag[], query: string, page: number, alphabetical: boolean = false): DirectoryTagPage {
  const term: string = query.trim().toLocaleLowerCase();
  const matches: DirectoryTag[] = tags.filter((tag: DirectoryTag): boolean => {
    return !term || `${tag.name} ${tag.description}`.toLocaleLowerCase().indexOf(term) >= 0;
  }).sort((first: DirectoryTag, second: DirectoryTag): number => {
    return alphabetical ? first.name.localeCompare(second.name) :
      second.topicCount - first.topicCount || first.name.localeCompare(second.name);
  });
  const end: number = (page + 1) * 100;
  return { items: matches.slice(page * 100, end), hasMore: end < matches.length, total: matches.length };
}
