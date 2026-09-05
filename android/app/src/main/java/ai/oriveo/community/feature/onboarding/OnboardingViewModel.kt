package ai.oriveo.community.feature.onboarding

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class OnboardingViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
) : ViewModel() {

    val hasCompletedOnboarding: StateFlow<Boolean> = appPreferencesRepository
        .hasCompletedOnboarding
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    fun completeOnboarding() {
        viewModelScope.launch { appPreferencesRepository.completeOnboarding() }
    }
}
