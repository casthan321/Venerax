package io.github.casthan321.venera

internal object AndroidBridgeUtils {
    private const val MAX_MIME_TYPE_LENGTH = 127
    private val mimeTypePattern =
        Regex("^[A-Za-z0-9!#$&^_.+-]+/(?:[A-Za-z0-9!#$&^_.+-]+|\\*)$")
    private val hostPattern = Regex("^[A-Za-z0-9.-]+$")
    private val ipv6Pattern = Regex("^[0-9A-Fa-f:.]+$")

    fun sanitizeMimeType(value: String?): String {
        val mimeType = value?.trim()?.takeIf { it.length <= MAX_MIME_TYPE_LENGTH }
            ?: return "*/*"
        if (mimeType == "*/*") return mimeType
        return if (mimeTypePattern.matches(mimeType)) mimeType else "*/*"
    }

    fun safeDocumentName(name: String?): String? {
        if (name.isNullOrBlank() || name == "." || name == "..") return null
        if (name.indexOf('\u0000') >= 0 || name.contains('/') || name.contains('\\')) {
            return null
        }
        return name
    }

    fun isSafeRelativePath(path: String): Boolean {
        if (path.indexOf('\u0000') >= 0 || path.contains('\\')) return false
        if (path.isEmpty()) return true
        return path.split('/').none { it.isEmpty() || it == "." || it == ".." }
    }

    fun uniqueName(name: String, attempt: Int): String {
        if (attempt <= 0) return name
        val extensionStart = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        return "${name.substring(0, extensionStart)} ($attempt)${name.substring(extensionStart)}"
    }

    fun formatProxyEndpoint(hostValue: String?, portValue: String?): String? {
        var host = hostValue?.trim()
        val port = portValue?.trim()?.toIntOrNull()
        if (host.isNullOrEmpty() || port == null || port !in 1..65535) return null
        if (host.startsWith('[') && host.endsWith(']')) {
            host = host.substring(1, host.length - 1)
        }
        if (host.isEmpty() || host.any { it.isWhitespace() }) return null
        if (host.contains(':')) {
            if (!ipv6Pattern.matches(host)) return null
        } else if (!hostPattern.matches(host)) {
            return null
        }
        return if (host.contains(':')) "[$host]:$port" else "$host:$port"
    }
}
