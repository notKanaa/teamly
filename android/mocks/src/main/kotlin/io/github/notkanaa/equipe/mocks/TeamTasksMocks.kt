package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppServices

/**
 * Placeholder of the in-memory backend (Android port of TeamTasksMocks: `InMemoryBackend`, `DemoData` copied from
 * `supabase/seed.sql`, scenarios `populated` / `emptyGroups`). Its services implement the :core interfaces and
 * must behave exactly like the Supabase adapters (docs/CONTRACTS.md).
 */
object TeamTasksMocks {
    /** Replaced by a factory of [AppServices] backed by the in-memory backend. */
    const val PLACEHOLDER: String = "mocks"
}
