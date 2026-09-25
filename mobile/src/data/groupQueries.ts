import { useQuery } from '@tanstack/react-query';

import { FrenchCalendar } from '@/core/calendar';
import type { Uuid } from '@/core/uuid';
import { recapReadStart } from '@/core/weeklyRecap';

import { groups, tasks } from './api';
import { keys } from './queries';

// Reads of the group screens that `queries.ts` does not have: the invite code (admins) and the recap's completions.

export const groupKeys = {
  inviteCode: (groupId: Uuid) => ['group', groupId, 'inviteCode'] as const,
};

/** The raw 8-character invite code; only admins can read it (`enabled`). */
export function useInviteCode(groupId: Uuid, enabled: boolean) {
  return useQuery({ queryKey: groupKeys.inviteCode(groupId), queryFn: () => groups.inviteCode(groupId), enabled });
}

/** The group's done tasks since `recapReadStart` (docs/CONTRACTS-V2.md §8). */
export function useCompletions(groupId: Uuid, enabled = true) {
  return useQuery({
    queryKey: keys.completions(groupId),
    queryFn: () => tasks.completions(groupId, recapReadStart(Date.now(), FrenchCalendar.device())),
    enabled,
  });
}
