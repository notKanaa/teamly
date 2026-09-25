/** Input limits. They match the SQL check constraints (docs/CONTRACTS.md §1, docs/CONTRACTS-V2.md §3). */
export const Limits = {
  displayName: { min: 1, max: 50 },
  groupName: { min: 1, max: 60 },
  taskTitle: { min: 1, max: 200 },
  taskDetailsMax: 5000,
  passwordMinLength: 8,
  /** Supabase Auth hashes passwords with bcrypt, which reads at most 72 bytes. */
  passwordMaxBytes: 72,
  /** Supabase Auth refuses longer e-mail addresses. */
  emailMaxBytes: 255,
  maxAssignees: 20,
  /** Done tasks completed more than this many days ago are hidden unless explicitly requested. */
  oldDoneTaskDays: 30,
  checklistItemsMax: 30,
  checklistItemTitleMax: 200,
  rotationMin: 2,
  rotationMax: 20,
  repeatIntervalMax: 52,
  emojiCodePointsMax: 16,
  /** Events of one activity feed read, newest first (`limit=50`). */
  activityFeedMax: 50,
  /** The server deletes a group's events older than this many days when it writes a new one. */
  activityRetentionDays: 90,
  /** Rows of one PostgREST answer (`max_rows`): longer results are truncated without error. */
  readRowsMax: 1000,
} as const;
