package app.elroq.precondition.rules

import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

@Serializable
data class RuleBundle(
    val version: Int = CURRENT_VERSION,
    val places: List<Place> = emptyList(),
    val rules: List<Rule> = emptyList(),
) {
    companion object {
        const val CURRENT_VERSION = 1
    }
}

data class ImportIssue(val section: String, val index: Int, val name: String?, val message: String) {
    override fun toString(): String = "$section #${index + 1}${name?.let { " \"$it\"" } ?: ""}: $message"
}

data class ImportResult(val places: List<Place>, val rules: List<Rule>, val issues: List<ImportIssue>) {
    val ok: Boolean get() = issues.isEmpty()
}

/**
 * JSON backup format for rules and places. Never contains the API key or VIN.
 * Import decodes and validates each entry separately so one bad rule does not hide the rest.
 */
object RuleJson {
    val json = Json {
        prettyPrint = true
        encodeDefaults = true
        ignoreUnknownKeys = true
        classDiscriminator = "type"
    }

    fun export(places: List<Place>, rules: List<Rule>): String =
        json.encodeToString(RuleBundle.serializer(), RuleBundle(places = places, rules = rules))

    /**
     * @param existingPlaceIds places already on the phone; rules may refer to them as well as to imported ones.
     */
    fun import(text: String, existingPlaceIds: Set<String> = emptySet()): ImportResult {
        val root = try {
            json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            return ImportResult(emptyList(), emptyList(), listOf(ImportIssue("file", 0, null, "not a JSON object: ${e.message}")))
        }
        val issues = mutableListOf<ImportIssue>()

        val version = (root["version"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: RuleBundle.CURRENT_VERSION
        if (version > RuleBundle.CURRENT_VERSION) {
            issues += ImportIssue("file", 0, null, "version $version is newer than this app supports")
            return ImportResult(emptyList(), emptyList(), issues)
        }

        val places = decodeEach(root["places"], "place", issues) { json.decodeFromJsonElement(Place.serializer(), it) }
            .filter { (i, p) ->
                val problems = RuleValidator.validatePlace(p)
                problems.forEach { issues += ImportIssue("place", i, p.name, it) }
                problems.isEmpty()
            }
            .map { it.second }

        val placeIds = existingPlaceIds + places.map { it.id }
        val seenIds = mutableSetOf<String>()
        val rules = decodeEach(root["rules"], "rule", issues) { json.decodeFromJsonElement(Rule.serializer(), it) }
            .filter { (i, r) ->
                val problems = RuleValidator.validate(r, placeIds).toMutableList()
                if (!seenIds.add(r.id)) problems += "duplicate id '${r.id}'"
                problems.forEach { issues += ImportIssue("rule", i, r.name, it) }
                problems.isEmpty()
            }
            .map { it.second }

        return ImportResult(places, rules, issues)
    }

    private fun <T> decodeEach(
        element: kotlinx.serialization.json.JsonElement?,
        section: String,
        issues: MutableList<ImportIssue>,
        decode: (kotlinx.serialization.json.JsonElement) -> T,
    ): List<Pair<Int, T>> {
        if (element == null) return emptyList()
        val array = element as? JsonArray
            ?: return emptyList<Pair<Int, T>>().also { issues += ImportIssue(section, 0, null, "'${section}s' is not a list") }
        return array.mapIndexedNotNull { i, e ->
            try {
                i to decode(e)
            } catch (ex: SerializationException) {
                issues += ImportIssue(section, i, nameOf(e), ex.message ?: "invalid")
                null
            } catch (ex: IllegalArgumentException) {
                issues += ImportIssue(section, i, nameOf(e), ex.message ?: "invalid")
                null
            }
        }
    }

    private fun nameOf(e: kotlinx.serialization.json.JsonElement): String? =
        ((e as? JsonObject)?.get("name") as? JsonPrimitive)?.contentOrNull
}
