package com.hamsa.dictate

import android.content.Context

/** Preferências do app (equivalente ao AppSettings.swift do Mac). */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("hamsa_dictate", Context.MODE_PRIVATE)

    /** Idioma do Whisper: "pt", "en" ou "" (auto-detect). */
    var language: String
        get() = prefs.getString("language", "pt") ?: "pt"
        set(value) = prefs.edit().putString("language", value).apply()
}
