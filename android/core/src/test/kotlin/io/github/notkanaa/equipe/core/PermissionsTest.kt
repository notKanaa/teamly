package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID

/** Port of ContractTests.swift › PermissionsTests. */
class PermissionsTest {
    private val admin = UUID.randomUUID()
    private val creator = UUID.randomUUID()
    private val assignee = UUID.randomUUID()
    private val other = UUID.randomUUID()

    private val task = TaskItem(
        id = UUID.randomUUID(),
        groupId = UUID.randomUUID(),
        title = "Acheter le pain",
        createdBy = creator,
        createdAt = Instant.now(),
        updatedAt = Instant.now(),
        assigneeIds = listOf(assignee),
    )

    private data class Case(
        val user: UUID,
        val role: MemberRole?,
        val edit: Boolean,
        val status: Boolean,
        val delete: Boolean,
    )

    @Test
    fun matrix() {
        // (user, role) -> (edit, status, delete)
        val cases = listOf(
            Case(admin, MemberRole.ADMIN, edit = true, status = true, delete = true),
            Case(creator, MemberRole.MEMBER, edit = true, status = true, delete = true),
            Case(assignee, MemberRole.MEMBER, edit = false, status = true, delete = false),
            Case(other, MemberRole.MEMBER, edit = false, status = false, delete = false),
            Case(creator, null, edit = false, status = false, delete = false), // creator who left the group
            Case(assignee, null, edit = false, status = false, delete = false),
        )
        for (case in cases) {
            assertEquals("$case edit", case.edit, TaskPermissions.canEdit(task, case.user, case.role))
            assertEquals("$case status", case.status, TaskPermissions.canChangeStatus(task, case.user, case.role))
            assertEquals("$case delete", case.delete, TaskPermissions.canDelete(task, case.user, case.role))
        }
    }

    @Test
    fun groupAdminOnlyActions() {
        assertTrue(GroupPermissions.canManageMembers(MemberRole.ADMIN))
        assertFalse(GroupPermissions.canManageMembers(MemberRole.MEMBER))
        assertFalse(GroupPermissions.canSeeInviteCode(MemberRole.MEMBER))
        assertTrue(GroupPermissions.canLeave(MemberRole.MEMBER))
        assertFalse(GroupPermissions.canLeave(null))
    }

    @Test
    fun viewAndCreateNeedMembership() {
        assertTrue(TaskPermissions.canView(MemberRole.MEMBER))
        assertTrue(TaskPermissions.canCreate(MemberRole.ADMIN))
        assertFalse(TaskPermissions.canView(null))
        assertFalse(TaskPermissions.canCreate(null))
        assertTrue(GroupPermissions.canRename(MemberRole.ADMIN))
        assertFalse(GroupPermissions.canRename(MemberRole.MEMBER))
        assertTrue(GroupPermissions.canDelete(MemberRole.ADMIN))
        assertFalse(GroupPermissions.canDelete(null))
    }
}
