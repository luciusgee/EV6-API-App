package app.elroq.precondition.api.kia

import app.elroq.precondition.rules.ClimateState
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.VehicleSnapshot
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Turns Kia's cached-status responses (both protocols) into a [VehicleSnapshot]. */
object KiaMapper {
    /** Non-CCS2 timestamps are Central European local time; CCS2 "Date" is UTC. */
    private val kiaZone: ZoneId = ZoneId.of("Europe/Berlin")
    private val compact = DateTimeFormatter.ofPattern("yyyyMMddHHmmss")

    /**
     * @param status body of `status/latest` (non-CCS2) or `ccs2/carstatus/latest`
     * @param park body of `location/park`, if it was read; its position wins over the one in [status]
     */
    fun toSnapshot(status: JsonObject, park: JsonObject?, ccs2: Boolean, fetchedAt: Instant): VehicleSnapshot {
        val base = if (ccs2) fromCcs2(status.path("resMsg.state.Vehicle")) else fromLegacy(status.path("resMsg.vehicleStatusInfo"))
        val parked = park?.path("resMsg")?.let { position(it.path("coord.lat"), it.path("coord.lon")) }
        return base.copy(parkingPosition = parked ?: base.parkingPosition, fetchedAtEpochMs = fetchedAt.toEpochMilli())
    }

    /** Cars without CCS2 (most EV6s built before the 2024 facelift). */
    private fun fromLegacy(info: JsonElement?): VehicleSnapshot {
        val vs = info.path("vehicleStatus")
        val ev = vs.path("evStatus")
        val charging = ev.path("batteryCharge").bool()
        val plug = ev.path("batteryPlugin").num()?.toInt()
        val range = ev.path("drvDistance.0.rangeByFuel.evModeRange") ?: ev.path("drvDistance.0.rangeByFuel.totalAvailableRange")
        val power = listOfNotNull(
            ev.path("batteryPower.batteryStndChrgPower").num(),
            ev.path("batteryPower.batteryFstChrgPower").num(),
        ).filter { it > 0 }.maxOrNull()
        val airOn = vs.path("airCtrlOn").bool()
        val engine = vs.path("engine").bool()
        return VehicleSnapshot(
            socPercent = ev.path("batteryStatus").num()?.toInt(),
            rangeKm = km(range.path("value").num(), range.path("unit").num()?.toInt()),
            pluggedIn = plug?.let { it != 0 },
            chargePowerKw = power?.takeIf { charging == true },
            minutesToFullyCharged = ev.path("remainTime2.atc.value").num()?.toInt()?.takeIf { charging == true && it > 0 },
            climate = when (airOn) {
                true -> ClimateState.RUNNING
                false -> ClimateState.OFF
                null -> ClimateState.UNKNOWN
            },
            climateRawState = airOn?.let { if (it) "ON" else "OFF" },
            targetTempC = legacyTemp(vs.path("airTemp.value").str(), vs.path("airTemp.unit").num()?.toInt()),
            chargingState = chargingState(plug?.let { it != 0 }, charging),
            parkingPosition = position(info.path("vehicleLocation.coord.lat"), info.path("vehicleLocation.coord.lon")),
            parked = engine?.let { !it },
            carCapturedAtEpochMs = localTime(vs.path("time").str())?.toEpochMilli(),
            fetchedAtEpochMs = 0,
        )
    }

    private fun fromCcs2(v: JsonElement?): VehicleSnapshot {
        val green = v.path("Green")
        val plugged = green.path("ChargingInformation.ConnectorFastening.State").num()?.let { it > 0 }
        val remain = green.path("ChargingInformation.Charging.RemainTime").num()?.toInt()
        val charging = if (plugged == false) false else remain?.let { it > 0 }
        val blower = v.path("Cabin.HVAC.Row1.Driver.Blower.SpeedLevel").num()
        val driver = v.path("Cabin.HVAC.Row1.Driver.Temperature")
        val outside = v.path("Cabin.HVAC.OutsideTemperature")
        val ready = v.path("DrivingReady").bool()
        return VehicleSnapshot(
            socPercent = green.path("BatteryManagement.BatteryRemain.Ratio").num()?.toInt(),
            rangeKm = km(v.path("Drivetrain.FuelSystem.DTE.Total").num(), v.path("Drivetrain.FuelSystem.DTE.Unit").num()?.toInt()),
            pluggedIn = plugged,
            chargePowerKw = green.path("Electric.SmartGrid.RealTimePower").num()?.takeIf { charging == true && it > 0 },
            minutesToFullyCharged = remain?.takeIf { charging == true },
            climate = when {
                blower == null -> ClimateState.UNKNOWN
                blower > 0 -> ClimateState.RUNNING
                else -> ClimateState.OFF
            },
            climateRawState = blower?.let { if (it > 0) "ON" else "OFF" },
            targetTempC = celsius(driver.path("Value").num(), driver.path("Unit").num()?.toInt()),
            outsideTempC = celsius(outside.path("Value").num(), outside.path("Unit").num()?.toInt()),
            chargingState = chargingState(plugged, charging),
            parkingPosition = position(v.path("Location.GeoCoord.Latitude"), v.path("Location.GeoCoord.Longitude")),
            parked = ready?.let { !it },
            carCapturedAtEpochMs = utcTime(v.path("Date").str())?.toEpochMilli(),
            fetchedAtEpochMs = 0,
        )
    }

    private fun chargingState(plugged: Boolean?, charging: Boolean?): String? = when {
        charging == true -> "CHARGING"
        plugged == true -> "PLUGGED_IN"
        plugged == false -> "UNPLUGGED"
        else -> null
    }

    /** Non-CCS2 cars report temperatures as a hex index into 14.0–29.5 °C in 0.5 steps, e.g. "0EH" = 21 °C. */
    fun legacyTemp(hex: String?, unit: Int?): Double? {
        if (hex == null || (unit != null && unit != 0)) return null
        val index = hex.uppercase().removeSuffix("H").toIntOrNull(16) ?: return null
        return (KiaConfig.MIN_TEMP_C + index * 0.5).takeIf { it <= KiaConfig.MAX_TEMP_C }
    }

    /** Inverse of [legacyTemp]: 21.0 → "0EH". */
    fun legacyTempCode(c: Double): String {
        val index = ((c.coerceIn(KiaConfig.MIN_TEMP_C, KiaConfig.MAX_TEMP_C) - KiaConfig.MIN_TEMP_C) * 2).toInt()
        return Integer.toHexString(index).uppercase().padStart(2, '0') + "H"
    }

    /** Unit 0 = °C, 1 = °F. */
    private fun celsius(value: Double?, unit: Int?): Double? = when {
        value == null -> null
        unit == 1 -> (value - 32) * 5 / 9
        else -> value
    }

    /** Unit 1 = km, 2 or 3 = miles. */
    private fun km(value: Double?, unit: Int?): Int? = value?.let { if (unit == 2 || unit == 3) (it * 1.609344).toInt() else it.toInt() }

    private fun position(lat: JsonElement?, lon: JsonElement?): LatLon? {
        val la = lat.num() ?: return null
        val lo = lon.num() ?: return null
        if (la == 0.0 && lo == 0.0) return null
        return LatLon(la, lo)
    }

    private fun localTime(raw: String?): Instant? = compactTime(raw)?.atZone(kiaZone)?.toInstant()
    private fun utcTime(raw: String?): Instant? = compactTime(raw)?.toInstant(ZoneOffset.UTC)

    /** "20240101120000" or "20240101120000.000"; tolerates separators. */
    private fun compactTime(raw: String?): LocalDateTime? {
        val digits = raw?.filter { it.isDigit() }?.takeIf { it.length >= 14 } ?: return null
        return runCatching { LocalDateTime.parse(digits.take(14), compact) }.getOrNull()
    }
}

// ---- JSON helpers ---------------------------------------------------------------------------

/** Follows a dotted path through objects (and arrays, for numeric parts). */
internal fun JsonElement?.path(dotted: String): JsonElement? = dotted.split('.').fold(this) { e, part ->
    when (e) {
        is JsonObject -> e[part]
        is JsonArray -> part.toIntOrNull()?.let { e.getOrNull(it) }
        else -> null
    }
}

internal fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.contentOrNull

internal fun JsonElement?.num(): Double? = (this as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()

/** Kia mixes true/false and 0/1. */
internal fun JsonElement?.bool(): Boolean? {
    val p = this as? JsonPrimitive ?: return null
    p.booleanOrNull?.let { return it }
    return p.contentOrNull?.toDoubleOrNull()?.let { it != 0.0 }
}
