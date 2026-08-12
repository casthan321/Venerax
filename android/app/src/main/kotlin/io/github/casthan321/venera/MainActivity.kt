package io.github.casthan321.venera

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    private val storageRequestCode = 0x10
    private var storagePermissionRequest: ((Boolean) -> Unit)? = null

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayList<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            sharedTexts.add(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>
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
        launcher = registry.register(key, contract, newCallback)
        launcher.launch(input)
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
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
                        if (activityResult.resultCode != Activity.RESULT_OK) {
                            res.success(null)
                            return@startContractForResult
                        }
                        val pickedDirectoryUri = activityResult.data?.data
                        if (pickedDirectoryUri == null)
                            res.success(null)
                        else
                            onPickedDirectory(pickedDirectoryUri, res)
                    }
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
            val mimeType = req.arguments<String>()
            openFile(res, mimeType!!)
        }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = {text ->
                        events.success(text)
                    }
                    if (sharedTexts.isNotEmpty()) {
                        for (text in sharedTexts) {
                            events.success(text)
                        }
                        sharedTexts.clear()
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
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (host != null && port != null) {
            "$host:$port"
        } else {
            "No Proxy"
        }
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
        if (hasStoragePermission()) {
            var plain = uri.toString()
            if(plain.contains("%3A")) {
                plain = Uri.decode(plain)
            }
            val externalStoragePrefix = "content://com.android.externalstorage.documents/tree/primary:";
            if(plain.startsWith(externalStoragePrefix)) {
                val path = plain.substring(externalStoragePrefix.length)
                result.success(Environment.getExternalStorageDirectory().absolutePath + "/" + path)
                return
            }
            // The uri cannot be parsed to plain path, use copy method
        }
        // dart:io cannot access the directory without permission.
        // so we need to copy the directory to cache directory
        val contentResolver = contentResolver
        val safeDirName = safeDocumentName(DocumentFile.fromTreeUri(this, uri)?.name)
        if (safeDirName == null) {
            result.error("copy error", "Selected directory has no valid name", null)
            return
        }
        var tmp = File(cacheDir, safeDirName)
        if (tmp.exists() && !tmp.deleteRecursively()) {
            result.error("copy error", "Cannot clear the temporary directory", null)
            return
        }
        if (!tmp.mkdirs() && !tmp.isDirectory) {
            result.error("copy error", "Cannot create the temporary directory", null)
            return
        }
        Thread {
            try {
                copyDirectory(contentResolver, uri, tmp)
                result.success(tmp.absolutePath)
            }
            catch (e: Exception) {
                result.error("copy error", e.message, null)
            }
        }.start()

    }

    private fun copyDirectory(resolver: ContentResolver, srcUri: Uri, destDir: File) {
        val src = DocumentFile.fromTreeUri(this, srcUri)
            ?: throw IOException("Cannot access the selected directory")
        for (file in src.listFiles()) {
            val childName = safeDocumentName(file.name)
                ?: throw IOException("A selected file has no valid name")
            if (file.isDirectory) {
                val newDir = File(destDir, childName)
                if (!newDir.mkdirs() && !newDir.isDirectory) {
                    throw IOException("Cannot create ${newDir.path}")
                }
                copyDirectory(resolver, file.uri, newDir)
            } else {
                val newFile = File(destDir, childName)
                val inputStream = resolver.openInputStream(file.uri)
                    ?: throw IOException("Cannot read ${file.uri}")
                inputStream.use { input ->
                    FileOutputStream(newFile).use { output ->
                        input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun safeDocumentName(name: String?): String? {
        if (name.isNullOrBlank() || name == "." || name == "..") return null
        val fileName = File(name).name
        return if (fileName == name) fileName else null
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            val writePermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            if (!readPermission || !writePermission) {
                storagePermissionRequest = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } else {
                result(true)
            }
        } else {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.addCategory("android.intent.category.DEFAULT")
                    intent.data = Uri.parse("package:$packageName")
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ _ ->
                        result(Environment.isExternalStorageManager())
                    }
                } catch (e: Exception) {
                    result(false)
                }
            } else {
                result(true)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            storagePermissionRequest?.invoke(grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            })
            storagePermissionRequest = null
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@startContractForResult
            }
            val contentResolver = contentResolver
            val file = DocumentFile.fromSingleUri(this, uri)
            if (file == null) {
                result.success(null)
                return@startContractForResult
            }
            val fileName = file.name
            if (fileName == null) {
                result.success(null)
                return@startContractForResult
            }
            if(hasStoragePermission()) {
                try {
                    val filePath = FileUtils.getPathFromUri(this, uri)
                    result.success(filePath)
                    return@startContractForResult
                }
                catch (e: Exception) {
                    // ignore
                }
            }
            // use copy method
            val tmp = File(cacheDir, fileName)
            if(tmp.exists()) {
                tmp.delete()
            }
            Log.i("Venera", "copy file (${fileName}) to ${tmp.absolutePath}")
            Thread {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tmp).use { output ->
                            input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                            output.flush()
                        }
                    }
                    result.success(tmp.absolutePath)
                }
                catch (e: Exception) {
                    result.error("copy error", e.message, null)
                }
            }.start()
        }
    }

    companion object {
        private const val SAF_PATH_PREFIX = "android://"
        private const val PRIMARY_STORAGE_ROOT = "/storage/emulated/0"
        private const val EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY =
            "com.android.externalstorage.documents"
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
}

