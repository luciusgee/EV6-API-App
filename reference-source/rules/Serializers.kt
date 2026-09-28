package app.elroq.precondition.rules

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.DayOfWeek
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/** Serialises [LocalTime] as "HH:mm" so exported rules are easy to hand-edit. */
object LocalTimeSerializer : KSerializer<LocalTime> {
    private val format = DateTimeFormatter.ofPattern("HH:mm")

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("app.elroq.LocalTime", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: LocalTime) {
        encoder.encodeString(value.format(format))
    }

    /** Accepts "7:05" as well as "07:05" for hand-edited files. */
    private val lenient = DateTimeFormatter.ofPattern("H:mm")

    override fun deserialize(decoder: Decoder): LocalTime {
        val text = decoder.decodeString().trim()
        return try {
            LocalTime.parse(text, lenient)
        } catch (e: DateTimeParseException) {
            throw SerializationException("Invalid time '$text', expected HH:mm")
        }
    }
}

/** Serialises [DayOfWeek] as its three-letter English name ("MON"), accepting full names on input. */
object DayOfWeekSerializer : KSerializer<DayOfWeek> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("app.elroq.DayOfWeek", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: DayOfWeek) {
        encoder.encodeString(value.name.take(3))
    }

    override fun deserialize(decoder: Decoder): DayOfWeek {
        val text = decoder.decodeString().trim().uppercase()
        return DayOfWeek.entries.firstOrNull { it.name == text || it.name.take(3) == text }
            ?: throw SerializationException("Invalid day '$text', expected MON..SUN")
    }
}
