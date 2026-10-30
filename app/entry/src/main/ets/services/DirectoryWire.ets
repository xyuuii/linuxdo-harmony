import { DirectoryTag, DirectoryBadge, DirectoryGroup, DirectoryGroupPage } from '../models/DirectoryModels';
import { text, numberValue, bool, list, plainText } from './ForumWire';

export interface DirectoryTagWire { id?: number; name?: string; text?: string; slug?: string; description?: string; count?: number; }
export interface DirectoryTagOwnerWire { tags?: DirectoryTagWire[]; }
export interface DirectoryTagExtrasWire { tag_groups?: DirectoryTagOwnerWire[]; categories?: DirectoryTagOwnerWire[]; }
export interface DirectoryTagsResponseWire { tags?: DirectoryTagWire[]; extras?: DirectoryTagExtrasWire; }
export interface DirectoryBadgeWire {
  id?: number; name?: string; description?: string; long_description?: string; grant_count?: number;
  has_badge?: boolean; badge_type_id?: number; badge_grouping_id?: number;
}
export interface DirectoryBadgeGroupingWire { id?: number; name?: string; }
export interface DirectoryBadgesResponseWire { badges?: DirectoryBadgeWire[]; badge_groupings?: DirectoryBadgeGroupingWire[]; }
export interface DirectoryGroupWire {
  id?: number; name?: string; display_name?: string; full_name?: string; bio_excerpt?: string; bio_cooked?: string;
  user_count?: number; automatic?: boolean; is_group_user?: boolean; public_admission?: boolean; allow_membership_requests?: boolean;
}
export interface DirectoryGroupsResponseWire { groups?: DirectoryGroupWire[]; total_rows_groups?: number; load_more_groups?: string; }

export function directoryTagsFromWire(response: DirectoryTagsResponseWire): DirectoryTag[] {
  const byName: Map<string, DirectoryTag> = new Map<string, DirectoryTag>();
  const add: (wire: DirectoryTagWire) => void = (wire: DirectoryTagWire): void => {
    const name: string = text(wire.name) || text(wire.text);
    if (!name || name.length > 200) { return; }
    const tag: DirectoryTag = { id: numberValue(wire.id), name: name, slug: text(wire.slug),
      description: plainText(text(wire.description)), topicCount: numberValue(wire.count) };
    byName.set(name, tag);
  };
  list(response.tags).forEach(add);
  list(response.extras?.tag_groups).forEach((group: DirectoryTagOwnerWire): void => { list(group.tags).forEach(add); });
  list(response.extras?.categories).forEach((category: DirectoryTagOwnerWire): void => { list(category.tags).forEach(add); });
  return Array.from(byName.values());
}

export function directoryBadgesFromWire(response: DirectoryBadgesResponseWire): DirectoryBadge[] {
  const groupNames: Map<number, string> = new Map<number, string>();
  list(response.badge_groupings).forEach((group: DirectoryBadgeGroupingWire): void => {
    groupNames.set(numberValue(group.id), plainText(text(group.name)));
  });
  return list(response.badges).filter((wire: DirectoryBadgeWire): boolean => numberValue(wire.id) > 0)
    .map((wire: DirectoryBadgeWire): DirectoryBadge => {
      const groupId: number = numberValue(wire.badge_grouping_id);
      return { id: numberValue(wire.id), name: plainText(text(wire.name)), description: plainText(text(wire.description)),
        longDescription: plainText(text(wire.long_description)), grantCount: numberValue(wire.grant_count),
        hasBadge: bool(wire.has_badge), badgeType: numberValue(wire.badge_type_id), groupId: groupId,
        groupName: groupNames.get(groupId) ?? '' };
    });
}

export function directoryGroupsFromWire(response: DirectoryGroupsResponseWire): DirectoryGroupPage {
  const items: DirectoryGroup[] = list(response.groups).filter((wire: DirectoryGroupWire): boolean => {
    return numberValue(wire.id) > 0 && text(wire.name).length > 0;
  }).map((wire: DirectoryGroupWire): DirectoryGroup => {
    return { id: numberValue(wire.id), name: text(wire.name),
      displayName: plainText(text(wire.full_name) || text(wire.display_name) || text(wire.name)),
      description: plainText(text(wire.bio_excerpt) || text(wire.bio_cooked)),
      userCount: typeof wire.user_count === 'number' && Number.isFinite(wire.user_count) ? wire.user_count : -1,
      automatic: bool(wire.automatic), joined: bool(wire.is_group_user), publicAdmission: bool(wire.public_admission),
      allowMembershipRequests: bool(wire.allow_membership_requests) };
  });
  return { items: items, hasMore: items.length > 0 && text(response.load_more_groups).length > 0,
    total: typeof response.total_rows_groups === 'number' ? numberValue(response.total_rows_groups) : -1 };
}
