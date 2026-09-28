package dev.flexvpn.flutter_singbox_vpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The last selected tunnel, encrypted with a device-bound Android Keystore key. */
internal object QuickTileProfile {
    private const val ALIAS = "bmray.quickTileProfile"
    private const val PREFS = "bmray-quick-tile"
    private const val PAYLOAD = "profile"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    data class Config(val singBox: String, val xray: String?, val name: String?)

    fun save(context: Context, singBox: String?, xray: String?, name: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (singBox.isNullOrEmpty()) {
            prefs.edit().remove(PAYLOAD).commit()
            return
        }
        val plain = JSONObject().put("singBox", singBox)
            .put("xray", xray ?: JSONObject.NULL)
            .put("name", name ?: JSONObject.NULL).toString().toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(plain)
        if (!prefs.edit().putString(PAYLOAD, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()) {
            throw IllegalStateException("Could not save the Quick Settings profile")
        }
    }

    fun load(context: Context): Config? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val encoded = prefs.getString(PAYLOAD, null) ?: return null
        return try {
            val sealed = Base64.decode(encoded, Base64.NO_WRAP)
            require(sealed.size > 12)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
            val json = JSONObject(String(cipher.doFinal(sealed.copyOfRange(12, sealed.size)), Charsets.UTF_8))
            Config(json.getString("singBox"),
                if (json.isNull("xray")) null else json.getString("xray"),
                if (json.isNull("name")) null else json.getString("name"))
        } catch (_: Exception) {
            // Restored app data without its device-bound key must never be used.
            prefs.edit().remove(PAYLOAD).commit()
            null
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        return generator.generateKey()
    }
}
