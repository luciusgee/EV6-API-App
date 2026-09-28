package app.elroq.precondition.rules

import java.time.LocalTime
import java.time.ZonedDateTime

data class ScheduledCheck(val at: ZonedDateTime, val time: LocalTime)

object ScheduleCalculator {

    /** Next time strictly after [after] that falls on one of [trigger]'s days at its time. */
    fun next(trigger: Trigger.Schedule, after: ZonedDateTime): ZonedDateTime? {
        if (trigger.days.isEmpty()) return null
        for (offset in 0L..7L) {
            val date = after.toLocalDate().plusDays(offset)
            if (date.dayOfWeek !in trigger.days) continue
            // ZonedDateTime.of moves a time inside a DST gap forward, which is what an alarm should do.
            val candidate = ZonedDateTime.of(date, trigger.time, after.zone)
            if (candidate.isAfter(after)) return candidate
        }
        return null
    }

    /** The soonest schedule check across all enabled rules, used to arm a single exact alarm. */
    fun nextCheck(rules: List<Rule>, after: ZonedDateTime): ScheduledCheck? =
        rules.asSequence()
            .filter { it.enabled }
            .mapNotNull { it.trigger as? Trigger.Schedule }
            .mapNotNull { t -> next(t, after)?.let { ScheduledCheck(it, t.time) } }
            .minByOrNull { it.at }
}
