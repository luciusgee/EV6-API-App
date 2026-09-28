package app.elroq.precondition.api

import app.elroq.precondition.rules.ClimateState
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.VehicleSnapshot
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant

object VehicleMapper {

    private val runningStates = setOf("HEATING", "COOLING", "HEATING_AUXILIARY", "VENTILATION")
    private val offStates = setOf("OFF", "COMPLETED")

    /** CONNECT_CABLE means no cable; every other known charging state implies one is connected. */
    private val pluggedStates = setOf("CHARGING", "CONSERVING", "READY_FOR_CHARGING", "DISCHARGING", "CHARGING_INTERRUPTED")

    fun toSnapshot(dto: VehicleResponseDto, raw: JsonElement?, fetchedAt: Instant): VehicleSnapshot {
        val v = dto.vehicle
        val ac = v?.airConditioning
        val charging = v?.charging
        val acState = ac?.state?.uppercase()
        val chargingState = charging?.status?.state?.uppercase()
        val captured = listOfNotNull(ac?.carCapturedTimestamp, charging?.carCapturedTimestamp)
            .mapNotNull(HeaderParser::instant)
            .maxOrNull()

        return VehicleSnapshot(
            socPercent = charging?.status?.battery?.stateOfChargeInPercent,
            rangeKm = charging?.status?.battery?.remainingCruisingRangeInMeters?.let { (it / 1000).toInt() },
            chargePowerKw = charging?.status?.chargePowerInKw?.takeIf { chargingState == "CHARGING" },
            minutesToFullyCharged = charging?.status?.remainingTimeToFullyChargedInMinutes?.takeIf { chargingState == "CHARGING" },
            pluggedIn = when (chargingState) {
                null -> null
                "CONNECT_CABLE" -> false
                in pluggedStates -> true
                else -> null
            },
            climate = when (acState) {
                null -> ClimateState.UNKNOWN
                in runningStates -> ClimateState.RUNNING
                in offStates -> ClimateState.OFF
                else -> ClimateState.UNKNOWN
            },
            climateRawState = acState,
            targetTempC = ac?.targetTemperature?.celsius,
            targetReachedAtEpochMs = ac?.estimatedReachOfTargetTemperatureAt?.let(HeaderParser::instant)?.toEpochMilli(),
            climateWithoutExternalPower = ac?.airConditioningWithoutExternalPower,
            chargingState = chargingState,
            outsideTempC = raw?.let { findOutsideTemperature(it) },
            parkingPosition = v?.parkingPosition?.gpsCoordinates?.let { LatLon(it.latitude, it.longitude) },
            parked = when (v?.parkingPosition?.state?.uppercase()) {
                "PARKED" -> true
                "IN_MOTION" -> false
                else -> null
            },
            carCapturedAtEpochMs = captured?.toEpochMilli(),
            fetchedAtEpochMs = fetchedAt.toEpochMilli(),
            unavailable = dto.errors.mapNotNull { it.type },
        )
    }

    private val outsideKey = Regex("(outside|outdoor|ambient|exterior|external).*temp", RegexOption.IGNORE_CASE)

    /**
     * The public API is not known to report an outside temperature (open question in the spec).
     * Rather than guess a field name, look for any key that plainly names one, as a number or a
     * {value, unit} object. The first-run dump in the log shows whether anything matched.
     */
    fun findOutsideTemperature(e: JsonElement): Double? = when (e) {
        is JsonObject -> e.entries.firstNotNullOfOrNull { (k, value) ->
            if (outsideKey.containsMatchIn(k)) temperatureOf(value) else null
        } ?: e.values.firstNotNullOfOrNull { findOutsideTemperature(it) }
        is JsonArray -> e.firstNotNullOfOrNull { findOutsideTemperature(it) }
        is JsonPrimitive -> null
    }

    private fun temperatureOf(e: JsonElement): Double? = when (e) {
        is JsonPrimitive -> e.doubleOrNull
        is JsonObject -> {
            val value = (e["value"] as? JsonPrimitive)?.doubleOrNull
            val unit = (e["unit"] as? JsonPrimitive)?.contentOrNull
            TemperatureDto(value, unit).celsius
        }
        is JsonArray -> null
    }
}

/** VINs appear in logs only as their last four characters. */
fun maskVin(vin: String): String = if (vin.length <= 4) vin else "*".repeat(vin.length - 4) + vin.takeLast(4)

/** VIN alphabet: 17 characters, no I, O or Q. */
private val vinPattern = Regex("\\b[A-HJ-NPR-Z0-9]{17}\\b", RegexOption.IGNORE_CASE)

/** Masks [vin] and anything else shaped like a VIN in [text]. */
fun redactVin(text: String, vin: String?): String {
    val known = if (vin.isNullOrBlank()) text else text.replace(vin, maskVin(vin), ignoreCase = true)
    return vinPattern.replace(known) { maskVin(it.value) }
}
