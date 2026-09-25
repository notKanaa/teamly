import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import type { AuthState } from '@/core/models';

import { authUser } from './api';
import { queryClient } from './queries';
import { supabase } from './supabase';

// The auth state of the app, from the session stored in AsyncStorage then every Supabase Auth event. A recovery code
// (password reset) opens a session flagged `recovering`: the app asks for the new password before anything else.

interface SessionValue {
  state: AuthState;
  recovering: boolean;
  setRecovering: (value: boolean) => void;
}

const SessionContext = createContext<SessionValue>({ state: { kind: 'unknown' }, recovering: false, setRecovering: () => {} });

export function SessionProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({ kind: supabase ? 'unknown' : 'signedOut' });
  const [recovering, setRecovering] = useState(false);

  useEffect(() => {
    if (supabase === null) return;
    let lastUserId: string | null = null;
    const apply = (session: { user: { id: string; email?: string | null } } | null) => {
      const userId = session?.user.id.toLowerCase() ?? null;
      if (userId !== lastUserId) queryClient.clear();
      lastUserId = userId;
      setState(session ? { kind: 'signedIn', user: authUser(session.user) } : { kind: 'signedOut' });
      if (!session) setRecovering(false);
    };
    void supabase.auth.getSession().then(({ data }) => apply(data.session));
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY') setRecovering(true);
      // Defer: calling Supabase inside the callback can deadlock the auth lock.
      setTimeout(() => apply(session), 0);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  return <SessionContext.Provider value={{ state, recovering, setRecovering }}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionValue {
  return useContext(SessionContext);
}

/** The signed-in user's id (screens under the signed-in stack only). */
export function useUserId(): string {
  const { state } = useSession();
  return state.kind === 'signedIn' ? state.user.id : '';
}
