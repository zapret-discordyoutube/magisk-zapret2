package com.zapret2.app.viewmodel

import com.zapret2.app.R
import com.zapret2.app.data.ProtectedAccessFailure
import com.zapret2.app.data.hasProtectedAccessFailure
import com.zapret2.app.ui.UiText

enum class ConfigurationLoadFailure { ROOT_ACCESS_UNAVAILABLE, READ_FAILED }

internal fun Throwable?.toConfigurationLoadFailure(): ConfigurationLoadFailure =
    if (this?.hasProtectedAccessFailure(ProtectedAccessFailure.ROOT_UNAVAILABLE) == true) {
        ConfigurationLoadFailure.ROOT_ACCESS_UNAVAILABLE
    } else {
        ConfigurationLoadFailure.READ_FAILED
    }

/** One presentation projection for protected configuration reads on every screen. */
internal fun Throwable.rootAccessUiErrorOrNull(): UiText? =
    if (hasProtectedAccessFailure(ProtectedAccessFailure.ROOT_UNAVAILABLE)) {
        UiText.resource(R.string.root_access_unavailable_body)
    } else {
        null
    }
