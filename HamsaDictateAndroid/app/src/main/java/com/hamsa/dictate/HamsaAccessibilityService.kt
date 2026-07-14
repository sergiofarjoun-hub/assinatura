package com.hamsa.dictate

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Insere o texto transcrito no campo focado de qualquer app — o papel do
 * TextInserter.swift (⌘V simulado) no Mac.
 *
 * Ordem de tentativa:
 * 1. ACTION_PASTE no nó focado (insere na posição do cursor) com o clipboard
 *    temporariamente trocado — e restaurado ~1 s depois, como no Mac.
 * 2. ACTION_SET_TEXT anexando ao texto existente (apps que bloqueiam paste).
 * 3. Fallback: deixa no clipboard e avisa (o chamador mostra o toast).
 */
class HamsaAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile var instance: HamsaAccessibilityService? = null
            private set

        val isEnabled: Boolean get() = instance != null
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    /** @return true se conseguiu inserir; false se só deixou no clipboard. */
    fun insertText(text: String): Boolean {
        val root = rootInActiveWindow
        val target = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

        val clipboard = getSystemService(ClipboardManager::class.java)
        val previous = clipboard.primaryClip

        if (target != null && target.isEditable) {
            // 1) Paste na posição do cursor.
            clipboard.setPrimaryClip(ClipData.newPlainText("HamsaDictate", text))
            val pasted = target.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            if (pasted) {
                restoreClipboardLater(clipboard, previous)
                return true
            }

            // 2) SET_TEXT anexando ao conteúdo atual.
            val existing = target.text?.toString().orEmpty()
            val combined = if (existing.isBlank()) text else "$existing $text"
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined)
            }
            if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                restoreClipboardLater(clipboard, previous)
                return true
            }
        }

        // 3) Sem campo editável focado (ou app resistiu): fica no clipboard.
        clipboard.setPrimaryClip(ClipData.newPlainText("HamsaDictate", text))
        return false
    }

    private fun restoreClipboardLater(clipboard: ClipboardManager, previous: ClipData?) {
        Handler(Looper.getMainLooper()).postDelayed({
            runCatching {
                if (previous != null) clipboard.setPrimaryClip(previous)
                else clipboard.clearPrimaryClip()
            }
        }, 1000)
    }
}
