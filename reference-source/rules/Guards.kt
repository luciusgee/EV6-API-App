package app.elroq.precondition.rules

/** Safety guards shared by automated rules and manual commands. Unknown inputs always fail a guard. */
object Guards {
    fun soc(v: VehicleSnapshot, minPercent: Int): Check = when {
        v.pluggedIn == true -> Check("SoC guard", Tri.PASS, "plugged in")
        v.socPercent == null -> Check("SoC guard", Tri.FAIL, "state of charge unknown")
        v.socPercent < minPercent -> Check("SoC guard", Tri.FAIL, "SoC ${v.socPercent}% below minimum $minPercent%")
        else -> Check("SoC guard", Tri.PASS, "SoC ${v.socPercent}% ≥ $minPercent%")
    }

    fun notRunning(v: VehicleSnapshot): Check = when (v.climate) {
        ClimateState.OFF -> Check("not running", Tri.PASS, "climatisation off")
        ClimateState.RUNNING -> Check("not running", Tri.FAIL, "already running (${v.climateRawState ?: "on"})")
        ClimateState.UNKNOWN -> Check("not running", Tri.FAIL, "climatisation state unknown")
    }

    fun running(v: VehicleSnapshot): Check = when (v.climate) {
        ClimateState.RUNNING -> Check("running", Tri.PASS, "climatisation running")
        ClimateState.OFF -> Check("running", Tri.FAIL, "climatisation already off")
        ClimateState.UNKNOWN -> Check("running", Tri.FAIL, "climatisation state unknown")
    }
}
