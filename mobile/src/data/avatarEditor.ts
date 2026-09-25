import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';

import { automaticColor, type ColorKey } from '@/core/colorKey';
import { initialsOf } from '@/core/frenchText';
import type { UserProfile } from '@/core/models';
import type { AvatarAppearance } from '@/core/presentation';

import { profiles } from './api';
import { mergedProfile } from './onboarding';
import { keys } from './queries';

// The avatar picker (Swift `AvatarEditorViewModel`): a color among the palette, and the initials or an emoji, for the
// onboarding's « Choisis ton avatar » and the « Ton avatar » sheet of « Réglages ».

export interface AvatarEditor {
  /** The avatar as it will look. */
  appearance: AvatarAppearance;
  selectColor: (key: ColorKey) => void;
  /** null: the initials. */
  selectEmoji: (emoji: string | null) => void;
  hasChanges: boolean;
  saving: boolean;
  /** Saves a change (true at once without one); every screen then reloads. Throws on failure, keeping the choice. */
  save: () => Promise<boolean>;
  /** Back to the saved avatar. */
  reset: () => void;
}

export function useAvatarEditor(profile: UserProfile): AvatarEditor {
  const client = useQueryClient();
  const [color, setColor] = useState<ColorKey | null>(profile.avatarColor);
  const [emoji, setEmoji] = useState<string | null>(profile.avatarEmoji);
  const [saving, setSaving] = useState(false);
  const hasChanges = color !== profile.avatarColor || emoji !== profile.avatarEmoji;

  const save = async () => {
    if (!hasChanges) return true;
    setSaving(true);
    try {
      const updated = await profiles.updateAvatar(color, emoji);
      client.setQueryData<UserProfile>(keys.profile, (previous) => mergedProfile(updated, previous ?? profile));
      // Avatars are everywhere.
      void client.invalidateQueries({ queryKey: ['group'] });
      void client.invalidateQueries({ queryKey: ['overviews'] });
      return true;
    } finally {
      setSaving(false);
    }
  };

  return {
    appearance: { color: color ?? automaticColor(profile.id), emoji, initials: initialsOf(profile.displayName) },
    // The automatic color of a user whose saved color is automatic stays automatic.
    selectColor: (key) => setColor(profile.avatarColor === null && key === automaticColor(profile.id) ? null : key),
    selectEmoji: setEmoji,
    hasChanges,
    saving,
    save,
    reset: () => {
      setColor(profile.avatarColor);
      setEmoji(profile.avatarEmoji);
    },
  };
}
