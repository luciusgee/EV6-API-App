package app.elroq.precondition.api

import kotlinx.serialization.Serializable

/*
 * DTOs for the MyŠkoda Public API (https://public.api.connect.skoda-auto.cz).
 *
 * Source: field names match the OpenAPI-derived models of the `skoda-public-api` Python client
 * (v1.3.0, mobility-lab-vsb), because the official docs host was unreachable when this was written.
 * Confirm against the Swagger/OpenAPI reference before relying on anything marked UNCONFIRMED.
 *
 * Everything is nullable with defaults: the API returns partial 200s, and a missing section is
 * "unknown", never a parse failure. Enum-like fields are kept as strings for the same reason.
 */

@Serializable
data class VehicleResponseDto(
    val vehicle: VehicleDto? = null,
    val errors: List<VehicleErrorDto> = emptyList(),
)

/** e.g. type = "PARKING_POSITION_UNSUPPORTED" / "_DISABLED" / "_UNAVAILABLE". */
@Serializable
data class VehicleErrorDto(val type: String? = null, val description: String? = null)

@Serializable
data class VehicleDto(
    val vin: String? = null,
    val name: String? = null,
    val airConditioning: AirConditioningDto? = null,
    val charging: ChargingDto? = null,
    val parkingPosition: ParkingPositionDto? = null,
)

@Serializable
data class TemperatureDto(val value: Double? = null, val unit: String? = null) {
    val celsius: Double?
        get() = value?.let { if (unit.equals("FAHRENHEIT", ignoreCase = true)) (it - 32) * 5 / 9 else it }
}

@Serializable
data class AirConditioningDto(
    /** OFF, COOLING, HEATING, HEATING_AUXILIARY, VENTILATION, COMPLETED, UNKNOWN, UNSUPPORTED. */
    val state: String? = null,
    val targetTemperature: TemperatureDto? = null,
    val estimatedReachOfTargetTemperatureAt: String? = null,
    val airConditioningWithoutExternalPower: Boolean? = null,
    val airConditioningAtUnlock: Boolean? = null,
    val carCapturedTimestamp: String? = null,
)

@Serializable
data class ChargingDto(
    val isVehicleInSavedLocation: Boolean? = null,
    val status: ChargingStatusDto? = null,
    val carCapturedTimestamp: String? = null,
)

@Serializable
data class ChargingStatusDto(
    /** CONNECT_CABLE, CHARGING, CONSERVING, READY_FOR_CHARGING, DISCHARGING, CHARGING_INTERRUPTED. */
    val state: String? = null,
    val chargeType: String? = null,
    val chargePowerInKw: Double? = null,
    val remainingTimeToFullyChargedInMinutes: Int? = null,
    val battery: BatteryDto? = null,
)

@Serializable
data class BatteryDto(
    val stateOfChargeInPercent: Int? = null,
    val remainingCruisingRangeInMeters: Long? = null,
)

@Serializable
data class ParkingPositionDto(
    /** IN_MOTION or PARKED. */
    val state: String? = null,
    val gpsCoordinates: GpsDto? = null,
    val formattedAddress: String? = null,
)

@Serializable
data class GpsDto(val latitude: Double, val longitude: Double)

/**
 * Body of POST /api/v1/vehicles/{vin}/air-conditioning/start.
 * The API has no duration parameter for air conditioning (only auxiliary heating has one).
 */
@Serializable
data class StartAirConditioningRequest(
    val targetTemperature: TemperatureDto,
    /** Allow climatisation on battery power when not plugged in. */
    val airConditioningWithoutExternalPower: Boolean = true,
)
