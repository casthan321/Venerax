package io.github.casthan321.venera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidBridgeUtilsTest {
    @Test
    fun sanitizeMimeTypeKeepsValidValuesAndRejectsMalformedInput() {
        assertEquals("application/zip", AndroidBridgeUtils.sanitizeMimeType(" application/zip "))
        assertEquals("image/*", AndroidBridgeUtils.sanitizeMimeType("image/*"))
        assertEquals("*/*", AndroidBridgeUtils.sanitizeMimeType(null))
        assertEquals("*/*", AndroidBridgeUtils.sanitizeMimeType("text/plain\ninvalid"))
        assertEquals("*/*", AndroidBridgeUtils.sanitizeMimeType("not-a-mime"))
    }

    @Test
    fun safeDocumentNameRejectsTraversalAndSeparators() {
        assertEquals("comic.cbz", AndroidBridgeUtils.safeDocumentName("comic.cbz"))
        assertNull(AndroidBridgeUtils.safeDocumentName("../comic.cbz"))
        assertNull(AndroidBridgeUtils.safeDocumentName("folder/comic.cbz"))
        assertNull(AndroidBridgeUtils.safeDocumentName("folder\\comic.cbz"))
        assertNull(AndroidBridgeUtils.safeDocumentName(".."))
    }

    @Test
    fun relativeDocumentPathAllowsDescendantsButRejectsTraversal() {
        assertTrue(AndroidBridgeUtils.isSafeRelativePath(""))
        assertTrue(AndroidBridgeUtils.isSafeRelativePath("Comics/Series/Chapter 1"))
        assertFalse(AndroidBridgeUtils.isSafeRelativePath("/Comics"))
        assertFalse(AndroidBridgeUtils.isSafeRelativePath("Comics//Chapter"))
        assertFalse(AndroidBridgeUtils.isSafeRelativePath("Comics/../Secrets"))
        assertFalse(AndroidBridgeUtils.isSafeRelativePath("Comics\\Secrets"))
    }

    @Test
    fun uniqueNamePreservesTheOriginalExtension() {
        assertEquals("comic.cbz", AndroidBridgeUtils.uniqueName("comic.cbz", 0))
        assertEquals("comic (2).cbz", AndroidBridgeUtils.uniqueName("comic.cbz", 2))
        assertEquals("archive.tar (1).gz", AndroidBridgeUtils.uniqueName("archive.tar.gz", 1))
        assertEquals("README (1)", AndroidBridgeUtils.uniqueName("README", 1))
    }

    @Test
    fun proxyEndpointValidatesPortsAndBracketsIpv6() {
        assertEquals(
            "proxy.example:8080",
            AndroidBridgeUtils.formatProxyEndpoint(" proxy.example ", "8080")
        )
        assertEquals(
            "[2001:db8::1]:8443",
            AndroidBridgeUtils.formatProxyEndpoint("[2001:db8::1]", "8443")
        )
        assertNull(AndroidBridgeUtils.formatProxyEndpoint("proxy.example", "0"))
        assertNull(AndroidBridgeUtils.formatProxyEndpoint("proxy example", "8080"))
        assertNull(AndroidBridgeUtils.formatProxyEndpoint("proxy;https=other", "8080"))
    }
}
