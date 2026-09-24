package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of ContractTests.swift › BackendErrorMapperTests. */
class BackendErrorMapperTest {
    @Test
    fun mapsBusinessMessagesFirst() {
        assertEquals(AppError.LastAdmin, BackendErrorMapper.map(code = "P0001", message = "last_admin"))
        assertEquals(AppError.ForbiddenFields, BackendErrorMapper.map(code = "42501", message = "forbidden_fields"))
        assertEquals(AppError.NotFound, BackendErrorMapper.map(code = "P0001", message = "task_not_found"))
    }

    @Test
    fun fallsBackToSQLState() {
        assertEquals(
            AppError.Forbidden,
            BackendErrorMapper.map(code = "42501", message = "new row violates row-level security policy"),
        )
        assertEquals(AppError.Conflict, BackendErrorMapper.map(code = "23505", message = "duplicate key"))
        assertEquals(AppError.InvalidInput, BackendErrorMapper.map(code = "23514", message = "check constraint"))
        assertEquals(AppError.NotFound, BackendErrorMapper.map(code = "PGRST116", message = "0 rows"))
    }

    @Test
    fun fallsBackToHTTPStatus() {
        assertEquals(AppError.NotAuthenticated, BackendErrorMapper.map(code = null, message = null, httpStatus = 401))
        assertEquals(AppError.Unknown("boom"), BackendErrorMapper.map(code = null, message = "boom", httpStatus = 500))
    }

    /** CORE-401: PostgREST answers a call without a user JWT with HTTP 401 `{"code":"42501","message":"permission denied for …"}`. */
    @Test
    fun signedOutPermissionErrorMapsToNotAuthenticated() {
        assertEquals(
            AppError.NotAuthenticated,
            BackendErrorMapper.map("42501", "permission denied for table group_members", httpStatus = 401),
        )
        assertEquals(
            AppError.NotAuthenticated,
            BackendErrorMapper.map("42501", "permission denied for function create_group", httpStatus = 401),
        )
        // Our own permission errors keep their meaning.
        assertEquals(AppError.Forbidden, BackendErrorMapper.map("42501", "forbidden", httpStatus = 403))
        assertEquals(AppError.ForbiddenFields, BackendErrorMapper.map("42501", "forbidden_fields", httpStatus = 403))
    }

    @Test
    fun mapsValidationErrorsAddedByTheReview() {
        assertEquals(AppError.InvalidInput, BackendErrorMapper.map("P0001", "invalid_due_at", httpStatus = 400))
        assertEquals(AppError.InvalidInput, BackendErrorMapper.map("23502", "invalid_input", httpStatus = 400))
        assertEquals(
            AppError.InvalidInput,
            BackendErrorMapper.map("22P05", "unsupported Unicode escape sequence", httpStatus = 400),
        )
    }

    @Test
    fun everyCaseHasAFrenchMessage() {
        for (error in BackendErrorMapper.messageCodes.values) {
            assertTrue("$error", error.messageFR.isNotEmpty())
        }
    }

    // Android-only checks of the same rules.

    @Test
    fun messagesAreTrimmedLikeFoundation() {
        assertEquals(AppError.LastAdmin, BackendErrorMapper.map("P0001", " last_admin\n"))
        assertEquals(AppError.LastAdmin, BackendErrorMapper.map("P0001", " last_admin "))
    }

    @Test
    fun remainingCodesAndStatuses() {
        assertEquals(AppError.RateLimited, BackendErrorMapper.map("P0001", "rate_limited", httpStatus = 400))
        assertEquals(AppError.Forbidden, BackendErrorMapper.map("42501", "immutable_field", httpStatus = 403))
        assertEquals(AppError.NotFound, BackendErrorMapper.map("P0001", "group_not_found"))
        for (code in listOf("22001", "22P02")) {
            assertEquals(code, AppError.InvalidInput, BackendErrorMapper.map(code, "x"))
        }
        assertEquals(AppError.NotFound, BackendErrorMapper.map("23503", "fk"))
        assertEquals(AppError.NotAuthenticated, BackendErrorMapper.map("PGRST301", "jwt"))
        assertEquals(AppError.NotAuthenticated, BackendErrorMapper.map("PGRST302", "jwt"))
        assertEquals(AppError.Forbidden, BackendErrorMapper.map(null, null, httpStatus = 403))
        assertEquals(AppError.NotFound, BackendErrorMapper.map(null, null, httpStatus = 404))
        assertEquals(AppError.Conflict, BackendErrorMapper.map(null, null, httpStatus = 409))
        assertEquals(AppError.Unknown("XX000 boom"), BackendErrorMapper.map("XX000", "boom", httpStatus = 500))
        assertEquals(AppError.Unknown(""), BackendErrorMapper.map(null, null))
    }
}
