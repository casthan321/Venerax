package io.github.casthan321.venera

import android.Manifest
import android.annotation.TargetApi
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import dev.flutter.packages.file_selector_android.FileUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    private val volumeListen = VolumeListen()
    private var listening = false

    private val storageRequestCode = 0x10
    private val storagePermissionRequests = ArrayList<(Boolean) -> Unit>()
    private var storagePermissionInFlight = false

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayDeque<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "venera-picker-io").apply { isDaemon = true }
    }

    @Volatile
    private var activityDestroyed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
        prunePickerCacheAsync()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND ||
            intent.type?.lowercase(Locale.ROOT)?.startsWith("text/") != true
        ) {
            return
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (!text.isNullOrBlank()) handleSharedText(text)
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            if (sharedTexts.size == MAX_QUEUED_SHARED_TEXTS) {
                sharedTexts.removeFirst()
            }
            sharedTexts.addLast(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>,
        onLaunchError: (Exception) -> Unit
    ) {
        val key = "activity_rq_for_result#${nextLocalRequestCode.getAndIncrement()}"
        val registry = activityResultRegistry
        var launcher: ActivityResultLauncher<I>? = null
        val observer = object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (Lifecycle.Event.ON_DESTROY == event) {
                    launcher?.unregister()
                    lifecycle.removeObserver(this)
                }
            }
        }
        lifecycle.addObserver(observer)
        val newCallback = ActivityResultCallback<O> {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            callback.onActivityResult(it)
        }
        try {
            launcher = registry.register(key, contract, newCallback)
            launcher.launch(input)
        } catch (error: Exception) {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            onLaunchError(error)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/method_channel"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "getProxy" -> res.success(getProxy())
                "setScreenOn" -> {
                    val set = call.argument<Boolean>("set") ?: false
                    if (set) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    res.success(null)
                }

                "getDirectoryPath" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startContractForResult(
                        contract = ActivityResultContracts.StartActivityForResult(),
                        input = intent,
                        callback = { activityResult ->
                            if (activityResult.resultCode != Activity.RESULT_OK) {
                                res.success(null)
                            } else {
                                val pickedDirectoryUri = activityResult.data?.data
                                if (pickedDirectoryUri == null) {
                                    res.success(null)
                                } else {
                                    onPickedDirectory(pickedDirectoryUri, res)
                                }
                            }
                        },
                        onLaunchError = { error ->
                            res.error("picker unavailable", error.message, null)
                        }
                    )
                }

                "openFolder" -> {
                    val path = call.arguments as? String
                    res.success(path != null && openFolder(path))
                }

                else -> res.notImplemented()
            }
        }

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.onUp = {
                        events.success(1)
                    }
                    volumeListen.onDown = {
                        events.success(2)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    listening = false
                    volumeListen.clear()
                }
            })

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/storage")
        storageChannel.setMethodCallHandler { _, res ->
            requestStoragePermission { result ->
                res.success(result)
            }
        }

        val selectFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/select_file")
        selectFileChannel.setMethodCallHandler { req, res ->
            openFile(res, AndroidBridgeUtils.sanitizeMimeType(req.arguments<String>()))
        }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = { text ->
                        events.success(text)
                    }
                    while (sharedTexts.isNotEmpty()) {
                        events.success(sharedTexts.removeFirst())
                    }
                }

                override fun onCancel(arguments: Any?) {
                    textShareHandler = null
                }
            })
    }

    /**
     * Opens an Android document directory without exposing a raw file URI.
     *
     * ACTION_VIEW lets a capable file manager browse the exact directory. Some
     * OEM file managers do not handle directory VIEW intents, so the system
     * tree picker is used as a fallback with the same document as its initial
     * location. Starting either activity is the complete MethodChannel result;
     * no activity-result callback can complete the result a second time.
     */
    private fun openFolder(path: String): Boolean {
        val documentUri = directoryDocumentUri(path) ?: return false
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(documentUri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (tryStartFolderActivity(viewIntent)) {
            return true
        }

        val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentUri)
            }
        }
        return tryStartFolderActivity(pickerIntent)
    }

    private fun tryStartFolderActivity(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            Log.w("OpenFolder", "No activity handles ${intent.action}", error)
            false
        } catch (error: Exception) {
            Log.w("OpenFolder", "Failed to start ${intent.action}", error)
            false
        }
    }

    private fun directoryDocumentUri(path: String): Uri? {
        if (path.startsWith(SAF_PATH_PREFIX)) {
            return safDocumentUri(path)
        }
        val documentId = externalStorageDocumentId(path) ?: return null
        return DocumentsContract.buildDocumentUri(
            EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY,
            documentId
        )
    }

    /**
     * Maps only Android's canonical primary-storage path and conventional
     * removable-volume mount paths. Arbitrary app paths are intentionally not
     * reinterpreted as external-storage document IDs.
     */
    private fun externalStorageDocumentId(path: String): String? {
        val canonicalPath = try {
            File(path).canonicalPath.replace(File.separatorChar, '/')
        } catch (error: Exception) {
            return null
        }

        if (canonicalPath == PRIMARY_STORAGE_ROOT) {
            return "primary:"
        }
        if (canonicalPath.startsWith("$PRIMARY_STORAGE_ROOT/")) {
            return "primary:${canonicalPath.substring(PRIMARY_STORAGE_ROOT.length + 1)}"
        }

        val removable = REMOVABLE_STORAGE_PATH.matchEntire(canonicalPath)
            ?: return null
        val volume = removable.groupValues[1].uppercase(Locale.ROOT)
        val relativePath = removable.groupValues[2]
        return if (relativePath.isEmpty()) "$volume:" else "$volume:$relativePath"
    }

    /** Resolves flutter_saf's android:// document ID through our persisted tree grant. */
    private fun safDocumentUri(path: String): Uri? {
        val documentId = path.removePrefix(SAF_PATH_PREFIX).trimEnd('/')
        if (!isSafeDocumentId(documentId)) {
            return null
        }

        var selectedTree: Uri? = null
        var selectedTreeIdLength = -1
        for (permission in contentResolver.persistedUriPermissions) {
            if (!permission.isReadPermission) continue
            val treeUri = permission.uri
            val treeId = try {
                DocumentsContract.getTreeDocumentId(treeUri)
            } catch (error: Exception) {
                continue
            }
            if (!isSameOrDescendantDocument(treeId, documentId)) continue
            if (treeId.length > selectedTreeIdLength) {
                selectedTree = treeUri
                selectedTreeIdLength = treeId.length
            }
        }

        val treeUri = selectedTree ?: return null
        return try {
            DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        } catch (error: Exception) {
            null
        }
    }

    private fun isSafeDocumentId(documentId: String): Boolean {
        if (documentId.isEmpty() || documentId.indexOf('\u0000') >= 0) return false
        return documentId
            .split('/')
            .none { segment -> segment.isEmpty() || segment == "." || segment == ".." }
    }

    private fun isSameOrDescendantDocument(treeId: String, documentId: String): Boolean {
        if (treeId.isEmpty()) return false
        if (documentId == treeId) return true
        return if (treeId.endsWith(':')) {
            documentId.startsWith(treeId) && documentId.length > treeId.length
        } else {
            documentId.startsWith("$treeId/")
        }
    }

    private fun getProxy(): String {
        val proxies = ArrayList<String>(2)
        proxyEndpoint("https")?.let { proxies.add("https=$it") }
        proxyEndpoint("http")?.let { proxies.add("http=$it") }
        return if (proxies.isEmpty()) "No Proxy" else proxies.joinToString(";")
    }

    private fun proxyEndpoint(scheme: String): String? {
        return AndroidBridgeUtils.formatProxyEndpoint(
            System.getProperty("$scheme.proxyHost"),
            System.getProperty("$scheme.proxyPort")
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (listening) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }

                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// Ensure that the directory is accessible by dart:io
    private fun onPickedDirectory(uri: Uri, result: MethodChannel.Result) {
        submitIo(
            onRejected = {
                result.error("copy error", "The file worker is unavailable", null)
            }
        ) {
            var destination: File? = null
            try {
                if (hasStoragePermission()) {
                    val directPath = documentTreeToExternalPath(uri)
                    if (directPath != null) {
                        completeOnMain { result.success(directPath) }
                        return@submitIo
                    }
                }

                val source = DocumentFile.fromTreeUri(this, uri)
                    ?: throw IOException("Cannot access the selected directory")
                val safeDirName = AndroidBridgeUtils.safeDocumentName(source.name)
                    ?: throw IOException("Selected directory has no valid name")
                val copyDestination = createUniqueCacheDirectory(safeDirName)
                destination = copyDestination
                copyDirectory(contentResolver, source, copyDestination, depth = 0)
                val copiedPath = copyDestination.absolutePath
                completeOnMain { result.success(copiedPath) }
            } catch (error: Exception) {
                destination?.deleteRecursively()
                completeOnMain {
                    result.error("copy error", error.message ?: "Cannot copy directory", null)
                }
            }
        }
    }

    private fun copyDirectory(
        resolver: ContentResolver,
        src: DocumentFile,
        destDir: File,
        depth: Int
    ) {
        if (depth > MAX_DIRECTORY_DEPTH) {
            throw IOException("The selected directory is nested too deeply")
        }
        for (file in src.listFiles()) {
            val childName = AndroidBridgeUtils.safeDocumentName(file.name)
                ?: throw IOException("A selected file has no valid name")
            if (file.isDirectory) {
                val newDir = File(destDir, childName)
                if (!newDir.mkdir()) {
                    throw IOException("Cannot create ${newDir.path}")
                }
                copyDirectory(resolver, file, newDir, depth + 1)
            } else {
                val newFile = File(destDir, childName)
                if (!newFile.createNewFile()) {
                    throw IOException("Duplicate file name: $childName")
                }
                val inputStream = resolver.openInputStream(file.uri)
                    ?: throw IOException("Cannot read ${file.uri}")
                inputStream.use { input ->
                    FileOutputStream(newFile).use { output ->
                        input.copyTo(output, bufferSize = COPY_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun documentTreeToExternalPath(uri: Uri): String? {
        if (uri.authority != EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY) return null
        val documentId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (error: Exception) {
            return null
        }
        val separator = documentId.indexOf(':')
        if (separator <= 0) return null
        val volumeId = documentId.substring(0, separator)
        val relativePath = documentId.substring(separator + 1)
        if (!AndroidBridgeUtils.isSafeRelativePath(relativePath)) return null

        val root = when {
            volumeId.equals("primary", ignoreCase = true) ->
                Environment.getExternalStorageDirectory()
            REMOVABLE_VOLUME_ID.matches(volumeId) ->
                File("/storage/${volumeId.uppercase(Locale.ROOT)}")
            else -> return null
        }
        return if (relativePath.isEmpty()) {
            root.absolutePath
        } else {
            File(root, relativePath).absolutePath
        }
    }

    private fun createUniqueCacheDirectory(name: String): File {
        val parent = ensureCacheDirectory(PICKED_DIRECTORY_CACHE)
        for (attempt in 0 until MAX_UNIQUE_NAME_ATTEMPTS) {
            val candidate = File(parent, AndroidBridgeUtils.uniqueName(name, attempt))
            if (candidate.mkdir()) return candidate
        }
        throw IOException("Cannot create a unique temporary directory")
    }

    private fun createUniqueCacheFile(name: String): File {
        val parent = ensureCacheDirectory(PICKED_FILE_CACHE)
        for (attempt in 0 until MAX_UNIQUE_NAME_ATTEMPTS) {
            val candidate = File(parent, AndroidBridgeUtils.uniqueName(name, attempt))
            if (candidate.createNewFile()) return candidate
        }
        throw IOException("Cannot create a unique temporary file")
    }

    private fun ensureCacheDirectory(name: String): File {
        val directory = File(cacheDir, name)
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Cannot create the picker cache")
        }
        return directory
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
            val writeGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
            val supportsLegacyAccess = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                Environment.isExternalStorageLegacy()
            readGranted && writeGranted && supportsLegacyAccess
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        storagePermissionRequests.add(result)
        if (storagePermissionInFlight) return
        if (hasStoragePermission()) {
            finishStoragePermissionRequest(true)
            return
        }
        storagePermissionInFlight = true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            try {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } catch (error: Exception) {
                finishStoragePermissionRequest(false)
            }
        } else {
            launchStorageSettings(appSpecific = true)
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun launchStorageSettings(appSpecific: Boolean) {
        val intent = if (appSpecific) {
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                addCategory(Intent.CATEGORY_DEFAULT)
                data = Uri.parse("package:$packageName")
            }
        } else {
            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
        }
        startContractForResult(
            contract = ActivityResultContracts.StartActivityForResult(),
            input = intent,
            callback = {
                finishStoragePermissionRequest(Environment.isExternalStorageManager())
            },
            onLaunchError = {
                if (appSpecific) {
                    launchStorageSettings(appSpecific = false)
                } else {
                    finishStoragePermissionRequest(false)
                }
            }
        )
    }

    private fun finishStoragePermissionRequest(granted: Boolean) {
        storagePermissionInFlight = false
        val callbacks = storagePermissionRequests.toList()
        storagePermissionRequests.clear()
        for (callback in callbacks) callback(granted)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            finishStoragePermissionRequest(hasStoragePermission())
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            type = mimeType
        }
        startContractForResult(
            contract = ActivityResultContracts.StartActivityForResult(),
            input = intent,
            callback = { activityResult ->
                if (activityResult.resultCode != Activity.RESULT_OK) {
                    result.success(null)
                    return@startContractForResult
                }
                val uri = activityResult.data?.data
                if (uri == null) {
                    result.success(null)
                    return@startContractForResult
                }
                copySelectedFile(uri, result)
            },
            onLaunchError = { error ->
                result.error("picker unavailable", error.message, null)
            }
        )
    }

    private fun copySelectedFile(uri: Uri, result: MethodChannel.Result) {
        submitIo(
            onRejected = {
                result.error("copy error", "The file worker is unavailable", null)
            }
        ) {
            var destination: File? = null
            try {
                if (hasStoragePermission()) {
                    try {
                        val directFile = File(FileUtils.getPathFromUri(this, uri))
                        if (directFile.isFile && directFile.canRead()) {
                            val directPath = directFile.absolutePath
                            completeOnMain { result.success(directPath) }
                            return@submitIo
                        }
                    } catch (error: Exception) {
                        // Some providers cannot expose a dart:io path. Copy below instead.
                    }
                }

                val document = DocumentFile.fromSingleUri(this, uri)
                    ?: throw IOException("Cannot access the selected file")
                val fileName = AndroidBridgeUtils.safeDocumentName(document.name)
                    ?: throw IOException("Selected file has no valid name")
                val copyDestination = createUniqueCacheFile(fileName)
                destination = copyDestination
                val inputStream = contentResolver.openInputStream(uri)
                    ?: throw IOException("Cannot read the selected file")
                inputStream.use { input ->
                    FileOutputStream(copyDestination).use { output ->
                        input.copyTo(output, bufferSize = COPY_BUFFER_SIZE)
                        output.flush()
                    }
                }
                val copiedPath = copyDestination.absolutePath
                completeOnMain { result.success(copiedPath) }
            } catch (error: Exception) {
                destination?.delete()
                completeOnMain {
                    result.error("copy error", error.message ?: "Cannot copy file", null)
                }
            }
        }
    }

    private fun submitIo(onRejected: () -> Unit, operation: () -> Unit) {
        try {
            ioExecutor.execute { operation() }
        } catch (error: RejectedExecutionException) {
            completeOnMain(onRejected)
        }
    }

    private fun completeOnMain(action: () -> Unit) {
        val guardedAction = Runnable {
            if (!activityDestroyed) action()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            guardedAction.run()
        } else {
            mainHandler.post(guardedAction)
        }
    }

    private fun prunePickerCacheAsync() {
        submitIo(onRejected = {}) {
            val cutoff = System.currentTimeMillis() - PICKER_CACHE_RETENTION_MS
            for (cacheName in arrayOf(PICKED_FILE_CACHE, PICKED_DIRECTORY_CACHE)) {
                val pickerCache = File(cacheDir, cacheName)
                try {
                    pickerCache.listFiles()?.forEach { entry ->
                        if (entry.lastModified() in 1 until cutoff) {
                            entry.deleteRecursively()
                        }
                    }
                } catch (error: Exception) {
                    Log.w("VeneraPicker", "Cannot prune stale picker cache", error)
                }
            }
        }
    }

    override fun onDestroy() {
        activityDestroyed = true
        listening = false
        volumeListen.clear()
        textShareHandler = null
        storagePermissionRequests.clear()
        storagePermissionInFlight = false
        ioExecutor.shutdownNow()
        mainHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        listening = false
        volumeListen.clear()
        textShareHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val SAF_PATH_PREFIX = "android://"
        private const val PRIMARY_STORAGE_ROOT = "/storage/emulated/0"
        private const val EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY =
            "com.android.externalstorage.documents"
        private const val PICKED_FILE_CACHE = "venera-picked-files"
        private const val PICKED_DIRECTORY_CACHE = "venera-picked-directories"
        private const val COPY_BUFFER_SIZE = 64 * 1024
        private const val MAX_DIRECTORY_DEPTH = 64
        private const val MAX_UNIQUE_NAME_ATTEMPTS = 1000
        private const val MAX_QUEUED_SHARED_TEXTS = 32
        private const val PICKER_CACHE_RETENTION_MS = 7L * 24 * 60 * 60 * 1000
        private val REMOVABLE_VOLUME_ID = Regex("^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$")
        private val REMOVABLE_STORAGE_PATH =
            Regex("^/storage/([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})(?:/(.*))?$")
    }
}

class VolumeListen {
    var onUp = fun() {}
    var onDown = fun() {}

    fun up() {
        onUp()
    }

    fun down() {
        onDown()
    }

    fun clear() {
        onUp = {}
        onDown = {}
    }
}

