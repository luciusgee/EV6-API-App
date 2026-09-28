package app.elroq.precondition.di

import app.elroq.precondition.api.RateBudget
import app.elroq.precondition.api.VehicleApi
import app.elroq.precondition.api.kia.KiaClient
import app.elroq.precondition.data.KiaSessionRepository
import app.elroq.precondition.data.SettingsRepository
import app.elroq.precondition.engine.ApiMonitor
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import java.time.Clock
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object VehicleModule {
    @Provides @Singleton
    fun vehicleApi(
        http: OkHttpClient,
        budget: RateBudget,
        settings: SettingsRepository,
        sessions: KiaSessionRepository,
        monitor: ApiMonitor,
        clock: Clock,
    ): VehicleApi = KiaClient(http, budget, settings, sessions, monitor, clock)
}
