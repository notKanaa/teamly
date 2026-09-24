package io.github.notkanaa.equipe.core.viewmodel

import app.cash.turbine.test
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale
import java.util.UUID

/** Port of the DeepLinkTests suite of ViewModels/RouterTests.swift. */
class DeepLinkTest {
    private val groupId: UUID = UUID.fromString("A0000000-0000-4000-8000-000000000001")
    private val taskId: UUID = UUID.fromString("B0000000-0000-4000-8000-000000000003")

    @Test
    fun parsesTaskLinks() {
        assertEquals(DeepLink.Task(groupId, taskId), DeepLink.parse("equipe://task/${groupId.uuidString}/${taskId.uuidString}"))

        // Case-insensitive scheme and host, lowercase UUIDs, trailing slash.
        val loose = "EQUIPE://Task/${groupId.uuidString.lowercase(Locale.ROOT)}/${taskId.uuidString.lowercase(Locale.ROOT)}/"
        assertEquals(DeepLink.Task(groupId, taskId), DeepLink.parse(loose))
    }

    @Test
    fun parsesGroupAndMyTasksLinks() {
        assertEquals(DeepLink.Group(groupId), DeepLink.parse("equipe://group/${groupId.uuidString}"))
        assertEquals(DeepLink.MyTasks, DeepLink.parse("equipe://mytasks"))
    }

    @Test
    fun rejectsForeignOrMalformedLinks() {
        val g = groupId.uuidString
        val t = taskId.uuidString
        val rejected = listOf(
            "https://task/$g/$t",
            "equipe://task/$g",
            "equipe://task/$g/$t/extra",
            "equipe://task/not-a-uuid/$t",
            "equipe://other/$g/$t",
            "equipe://group/$g/$t",
            "equipe://mytasks/$g",
            // Kotlin additions: Java's lenient UUID forms and non-URLs are refused like Swift's `UUID(uuidString:)`.
            "equipe://group/1-1-1-1-1",
            "equipe://task/$g/{$t}",
            "pas une url",
            "",
        )
        for (string in rejected) {
            assertNull(string, DeepLink.parse(string))
        }
    }

    @Test
    fun urlRoundTrips() {
        for (link in listOf(DeepLink.Task(groupId, taskId), DeepLink.Group(groupId), DeepLink.MyTasks)) {
            assertEquals(link, DeepLink.parse(link.url))
        }
        assertEquals("equipe://task/${groupId.uuidString}/${taskId.uuidString}", DeepLink.Task(groupId, taskId).url)
    }

    @Test
    fun notificationUserInfo() {
        val both: Map<String, Any?> = mapOf("taskId" to taskId.uuidString, "groupId" to groupId.uuidString, "other" to 3)
        assertEquals(DeepLink.Task(groupId, taskId), DeepLink.fromNotification(both))
        assertEquals(DeepLink.Group(groupId), DeepLink.fromNotification(mapOf("groupId" to groupId.uuidString)))
        assertEquals(DeepLink.MyTasks, DeepLink.fromNotification(emptyMap()))
        assertEquals(DeepLink.MyTasks, DeepLink.fromNotification(mapOf("taskId" to taskId.uuidString)))
        assertEquals(DeepLink.MyTasks, DeepLink.fromNotification(mapOf("taskId" to "x", "groupId" to "y")))
        assertEquals(
            DeepLink.Group(groupId),
            DeepLink.fromNotification(mapOf("taskId" to 12, "groupId" to groupId.uuidString)),
        )
    }
}

/** Port of the RouterTests suite of ViewModels/RouterTests.swift (plus the Android back stack helpers). */
class RouterTest {
    private val groupId: UUID = UUID.fromString("A0000000-0000-4000-8000-000000000001")
    private val otherGroupId: UUID = UUID.fromString("A0000000-0000-4000-8000-000000000002")
    private val taskId: UUID = UUID.fromString("B0000000-0000-4000-8000-000000000003")

    @Test
    fun startsOnGroupsTabWithEmptyPaths() {
        val router = Router()
        assertEquals(AppTab.GROUPS, router.selectedTab)
        assertTrue(router.groupsPath.isEmpty())
        assertTrue(router.myTasksPath.isEmpty())
        assertFalse(router.isActive)
        assertNull(router.pendingDeepLink)
        assertEquals(listOf("Groupes", "Mes tâches", "Réglages"), AppTab.entries.map { it.title })
    }

    @Test
    fun deepLinkWaitsForASession() {
        val router = Router()
        router.selectedTab = AppTab.SETTINGS
        router.open(DeepLink.Task(groupId, taskId))
        assertEquals(DeepLink.Task(groupId, taskId), router.pendingDeepLink)
        assertEquals(AppTab.SETTINGS, router.selectedTab)
        assertTrue(router.groupsPath.isEmpty())

        router.activate()
        assertTrue(router.isActive)
        assertNull(router.pendingDeepLink)
        assertEquals(AppTab.GROUPS, router.selectedTab)
        assertEquals(listOf(AppRoute.Group(groupId), AppRoute.Task(groupId, taskId)), router.groupsPath)
    }

    @Test
    fun activeRouterAppliesLinksImmediately() {
        val router = Router()
        router.activate()
        router.selectedTab = AppTab.MY_TASKS

        assertTrue(router.open("equipe://task/${groupId.uuidString}/${taskId.uuidString}"))
        assertEquals(AppTab.GROUPS, router.selectedTab)
        assertEquals(listOf(AppRoute.Group(groupId), AppRoute.Task(groupId, taskId)), router.groupsPath)

        assertFalse(router.open("https://example.com"))
        assertEquals(2, router.groupsPath.size)

        router.openNotification(mapOf("groupId" to otherGroupId.uuidString))
        assertEquals(listOf(AppRoute.Group(otherGroupId)), router.groupsPath)

        router.openNotification(emptyMap())
        assertEquals(AppTab.MY_TASKS, router.selectedTab)
        assertTrue(router.myTasksPath.isEmpty())
    }

    @Test
    fun navigationHelpers() {
        val router = Router()
        router.showMembers(groupId)
        assertEquals(listOf(AppRoute.Group(groupId), AppRoute.Members(groupId)), router.groupsPath)
        router.showGroup(otherGroupId)
        assertEquals(listOf(AppRoute.Group(otherGroupId)), router.groupsPath)
        router.myTasksPath = listOf(AppRoute.Task(groupId, taskId))
        router.selectedTab = AppTab.MY_TASKS
        router.popToRoot()
        assertTrue(router.myTasksPath.isEmpty())
        assertEquals(listOf(AppRoute.Group(otherGroupId)), router.groupsPath)
        router.popToRoot(AppTab.GROUPS)
        assertTrue(router.groupsPath.isEmpty())
    }

    @Test
    fun removesRoutesOfAGoneGroupOrTask() {
        val router = Router()
        router.groupsPath = listOf(
            AppRoute.Group(otherGroupId),
            AppRoute.Group(groupId),
            AppRoute.Task(groupId, taskId),
            AppRoute.Members(groupId),
        )
        router.myTasksPath = listOf(AppRoute.Task(groupId, taskId))
        router.removeRoutesForGroup(groupId)
        assertEquals(listOf(AppRoute.Group(otherGroupId)), router.groupsPath)
        assertTrue(router.myTasksPath.isEmpty())

        router.groupsPath = listOf(AppRoute.Group(groupId), AppRoute.Task(groupId, taskId), AppRoute.Members(groupId))
        router.removeRoutesForTask(taskId)
        assertEquals(listOf(AppRoute.Group(groupId)), router.groupsPath)
    }

    @Test
    fun deactivateResetsNavigation() {
        val router = Router()
        router.activate()
        router.showTask(groupId, taskId)
        router.myTasksPath = listOf(AppRoute.Task(groupId, taskId))
        router.selectedTab = AppTab.SETTINGS
        router.deactivate()
        assertFalse(router.isActive)
        assertEquals(AppTab.GROUPS, router.selectedTab)
        assertTrue(router.groupsPath.isEmpty())
        assertTrue(router.myTasksPath.isEmpty())

        router.open(DeepLink.Group(groupId))
        assertEquals(DeepLink.Group(groupId), router.pendingDeepLink)
    }

    @Test
    fun routesKnowTheirGroup() {
        assertEquals(groupId, AppRoute.Group(groupId).groupId)
        assertEquals(groupId, AppRoute.Task(groupId, taskId).groupId)
        assertEquals(groupId, AppRoute.Members(groupId).groupId)
    }

    // region Android additions

    @Test
    fun pushAndPopEditTheSelectedTabsBackStack() {
        val router = Router()
        router.push(AppRoute.Group(groupId))
        router.push(AppRoute.Task(groupId, taskId))
        assertEquals(listOf(AppRoute.Group(groupId), AppRoute.Task(groupId, taskId)), router.groupsPath)
        assertEquals(AppRoute.Task(groupId, taskId), router.state.value.currentRoute)

        router.selectedTab = AppTab.MY_TASKS
        router.push(AppRoute.Task(groupId, taskId))
        assertEquals(listOf(AppRoute.Task(groupId, taskId)), router.path(AppTab.MY_TASKS))
        assertTrue(router.pop())
        assertFalse(router.pop())
        assertEquals(2, router.groupsPath.size)

        assertTrue(router.pop(AppTab.GROUPS))
        assertEquals(listOf(AppRoute.Group(groupId)), router.groupsPath)

        // « Réglages » has no destinations.
        router.selectedTab = AppTab.SETTINGS
        router.push(AppRoute.Group(otherGroupId))
        assertTrue(router.path(AppTab.SETTINGS).isEmpty())
        assertFalse(router.pop())
        assertNull(router.state.value.currentRoute)

        router.setPath(AppTab.GROUPS, listOf(AppRoute.Members(otherGroupId)))
        assertEquals(listOf(AppRoute.Members(otherGroupId)), router.groupsPath)
    }

    @Test
    fun stateIsObservable() = runTest {
        val router = Router()
        router.state.test {
            assertEquals(RouterState(), awaitItem())
            router.open(DeepLink.MyTasks)
            assertEquals(DeepLink.MyTasks, awaitItem().pendingDeepLink)
            router.activate()
            val active = awaitItem()
            assertTrue(active.isActive)
            assertEquals(AppTab.MY_TASKS, active.selectedTab)
            assertNull(active.pendingDeepLink)
            router.showGroup(groupId)
            assertEquals(listOf(AppRoute.Group(groupId)), awaitItem().groupsPath)
            expectNoEvents()
        }
    }

    // endregion
}
