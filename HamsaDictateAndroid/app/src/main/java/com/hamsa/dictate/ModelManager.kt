package com.hamsa.dictate

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Baixa e gerencia o modelo Whisper (ONNX, int8) usado pelo sherpa-onnx.
 * Equivalente ao download automático do WhisperKit no app de Mac.
 *
 * Modelo padrão: whisper-base multilíngue (~150 MB baixado) — o equilíbrio
 * viável num celular; o large do Mac não roda em telefone.
 */
class ModelManager(private val context: Context) {
    companion object {
        private const val MODEL_NAME = "sherpa-onnx-whisper-base"
        private const val MODEL_URL =
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2"
    }

    data class ModelFiles(val encoder: String, val decoder: String, val tokens: String)

    private val modelDir: File get() = File(context.filesDir, "models/$MODEL_NAME")

    /** Modelo pronto no disco? */
    fun installedFiles(): ModelFiles? {
        val dir = modelDir
        if (!dir.isDirectory) return null
        val files = dir.walkTopDown().filter { it.isFile }.toList()
        val encoder = files.firstOrNull { it.name.contains("encoder") && it.name.endsWith(".int8.onnx") }
        val decoder = files.firstOrNull { it.name.contains("decoder") && it.name.endsWith(".int8.onnx") }
        val tokens = files.firstOrNull { it.name.endsWith("tokens.txt") }
        return if (encoder != null && decoder != null && tokens != null) {
            ModelFiles(encoder.absolutePath, decoder.absolutePath, tokens.absolutePath)
        } else null
    }

    /**
     * Baixa (se preciso) e extrai o modelo, reportando progresso 0…1 do
     * download. Idempotente; seguro chamar de novo após falha parcial.
     */
    suspend fun ensureModel(onProgress: (Float) -> Unit): ModelFiles = withContext(Dispatchers.IO) {
        installedFiles()?.let { return@withContext it }

        val archive = File(context.cacheDir, "$MODEL_NAME.tar.bz2")
        if (!archive.exists() || archive.length() == 0L) {
            download(MODEL_URL, archive, onProgress)
        }

        val target = modelDir
        target.deleteRecursively()
        target.mkdirs()
        extractTarBz2(archive, target)
        archive.delete()

        installedFiles() ?: error("Arquivos do modelo não encontrados após a extração")
    }

    private fun download(url: String, dest: File, onProgress: (Float) -> Unit) {
        val tmp = File(dest.parentFile, dest.name + ".part")
        var connection = URL(url).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        // GitHub releases redireciona para outro host; HttpURLConnection não
        // segue redirect entre hosts sozinho.
        var redirects = 0
        while (connection.responseCode in 301..308 && redirects < 5) {
            val next = connection.getHeaderField("Location") ?: break
            connection.disconnect()
            connection = URL(next).openConnection() as HttpURLConnection
            redirects++
        }
        check(connection.responseCode == 200) { "Download falhou: HTTP ${connection.responseCode}" }

        val total = connection.contentLengthLong
        connection.inputStream.use { input ->
            FileOutputStream(tmp).use { out ->
                val buf = ByteArray(1 shl 16)
                var read = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    read += n
                    if (total > 0) onProgress(read.toFloat() / total)
                }
            }
        }
        connection.disconnect()
        check(tmp.length() > 0) { "Download vazio" }
        tmp.renameTo(dest)
    }

    private fun extractTarBz2(archive: File, targetDir: File) {
        BufferedInputStream(archive.inputStream()).use { fileIn ->
            BZip2CompressorInputStream(fileIn).use { bzIn ->
                TarArchiveInputStream(bzIn).use { tar ->
                    while (true) {
                        val entry = tar.nextEntry ?: break
                        val out = File(targetDir, entry.name)
                        // Proteção contra path traversal no tar.
                        check(out.canonicalPath.startsWith(targetDir.canonicalPath)) {
                            "Entrada de tar inválida: ${entry.name}"
                        }
                        if (entry.isDirectory) {
                            out.mkdirs()
                        } else {
                            out.parentFile?.mkdirs()
                            FileOutputStream(out).use { tar.copyTo(it) }
                        }
                    }
                }
            }
        }
    }
}
