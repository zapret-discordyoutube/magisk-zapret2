package com.zapret2.app.viewmodel

import com.zapret2.app.R
import com.zapret2.app.data.ProtectedAccessException
import com.zapret2.app.data.ProtectedAccessFailure
import com.zapret2.app.ui.UiText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProtectedAccessUiTest {

    @Test
    fun missingRootHasOneExplicitMessageAcrossConfigurationScreens() {
        val error = ProtectedAccessException(
            ProtectedAccessFailure.ROOT_UNAVAILABLE,
            "root shell unavailable",
        )

        assertEquals(
            UiText.Resource(R.string.root_access_unavailable_body),
            error.rootAccessUiErrorOrNull(),
        )
        assertEquals(
            ConfigurationLoadFailure.ROOT_ACCESS_UNAVAILABLE,
            error.toConfigurationLoadFailure(),
        )
        assertEquals(
            ConfigurationLoadFailure.READ_FAILED,
            IllegalStateException("invalid catalog").toConfigurationLoadFailure(),
        )
        assertNull(IllegalStateException("invalid catalog").rootAccessUiErrorOrNull())
    }
}
