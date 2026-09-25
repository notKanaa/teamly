import { Limits } from './limits';
import type { Uuid } from './uuid';

/**
 * Who takes the turn of a rotating task (« à tour de rôle », docs/CONTRACTS-V2.md §6), decided like the server (Swift
 * `RotationHandover`): at a spawn, and at the handover when the turn holder of a pending occurrence leaves.
 */
export interface RotationHandover {
  /** The listed users who are still members, in order; empty when fewer than 2 remain (the rotation is dropped). */
  rotation: Uuid[];
  /** Whose turn the next occurrence is; null when the rotation is dropped. */
  turnUserId: Uuid | null;
  /** The only assignee: the turn holder, or the single member left of a dropped rotation. */
  assigneeId: Uuid | null;
}

/**
 * The handover after `turnUserId`'s turn: the next turn holder is the first member found cyclically after
 * `turnUserId`'s position in `rotation` (someone who left still has a position); when `turnUserId` is not listed (or
 * null), the first member listed.
 */
export function rotationHandover(
  rotation: readonly Uuid[],
  turnUserId: Uuid | null,
  isMember: (userId: Uuid) => boolean,
): RotationHandover {
  const members = rotation.filter((userId) => isMember(userId));
  let turn: Uuid | null = null;
  const position = turnUserId === null ? -1 : rotation.indexOf(turnUserId);
  if (position >= 0) {
    for (let offset = 1; offset <= rotation.length; offset += 1) {
      const candidate = rotation[(position + offset) % rotation.length]!;
      if (members.includes(candidate)) {
        turn = candidate;
        break;
      }
    }
  } else {
    turn = members[0] ?? null;
  }
  if (members.length >= Limits.rotationMin) {
    return { rotation: members, turnUserId: turn, assigneeId: turn };
  }
  return { rotation: [], turnUserId: null, assigneeId: members[0] ?? null };
}
