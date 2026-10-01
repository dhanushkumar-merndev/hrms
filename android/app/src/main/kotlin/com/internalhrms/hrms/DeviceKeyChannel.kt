package com.internalhrms.hrms

import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hardware-backed punch signing key.
 *
 *  - generateKey: EC P-256 key in the Android Keystore (StrongBox when
 *    available), attested with the server's single-use nonce. When
 *    `requireBiometric` is set the key cannot sign without a fresh strong
 *    biometric per operation and is destroyed if a new biometric is enrolled.
 *    Returns the attestation certificate chain (leaf first) for the server
 *    to verify against Google's roots.
 *  - sign: SHA256withECDSA over the canonical punch payload, behind a
 *    BiometricPrompt bound to the key (CryptoObject), so the app itself
 *    cannot produce a signature without the user's biometric.
 */
class DeviceKeyChannel(private val activity: FragmentActivity) {

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status(call.argument<String>("alias")!!))
                "generateKey" -> result.success(
                    generateKey(
                        call.argument<String>("alias")!!,
                        call.argument<ByteArray>("challenge")!!,
                        call.argument<Boolean>("requireBiometric") ?: true,
                    ),
                )
                "sign" -> sign(
                    call.argument<String>("alias")!!,
                    call.argument<ByteArray>("payload")!!,
                    call.argument<String>("title") ?: "Confirm punch",
                    call.argument<String>("subtitle") ?: "",
                    result,
                )
                "authorize" -> authorize(
                    call.argument<String>("alias")!!,
                    call.argument<String>("title") ?: "Confirm punch",
                    call.argument<String>("subtitle") ?: "",
                    result,
                )
                "signAuthorized" -> {
                    val sig = pending ?: throw IllegalArgumentException("Verification expired. Try again.")
                    pending = null
                    sig.update(call.argument<ByteArray>("payload")!!)
                    result.success(Base64.encodeToString(sig.sign(), Base64.NO_WRAP))
                }
                "clearAuthorized" -> {
                    pending = null
                    result.success(true)
                }
                "confirmUser" -> confirmUser(
                    call.argument<String>("title") ?: "Confirm it's you",
                    call.argument<String>("subtitle") ?: "",
                    result,
                )
                "setSecure" -> {
                    // Hides the screen from screenshots, screen recording and
                    // the recent-apps preview while private data is shown.
                    if (call.argument<Boolean>("on") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                }
                "deleteKey" -> {
                    keyStore().deleteEntry(call.argument<String>("alias")!!)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("KEY_INVALIDATED", "Biometrics changed on this phone. Register it again.", null)
        } catch (e: IllegalStateException) {
            result.error("BIOMETRIC_NOT_ENROLLED", e.message ?: "Set up fingerprint or face unlock first.", null)
        } catch (e: Exception) {
            result.error("DEVICE_KEY_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** One signature unlocked by the last [authorize]; usable once. */
    private var pending: Signature? = null

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun biometricState(): String {
        return when (BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> "ready"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "no_hardware"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "update_required"
            else -> "unavailable"
        }
    }

    private fun status(alias: String): Map<String, Any?> {
        val ks = keyStore()
        var usable = false
        var biometricBound = false
        if (ks.containsAlias(alias)) {
            try {
                val key = ks.getKey(alias, null) as? PrivateKey
                if (key != null) {
                    val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                        .getKeySpec(key, KeyInfo::class.java)
                    biometricBound = info.isUserAuthenticationRequired
                    // initSign throws if a new biometric invalidated the key.
                    Signature.getInstance("SHA256withECDSA").initSign(key)
                    usable = true
                }
            } catch (e: KeyPermanentlyInvalidatedException) {
                usable = false
            } catch (e: Exception) {
                // UserNotAuthenticatedException etc.: key exists and is usable after auth.
                usable = true
            }
        }
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "hasKey" to ks.containsAlias(alias),
            "keyUsable" to usable,
            "keyBiometricBound" to biometricBound,
            "biometric" to biometricState(),
            "strongBox" to (Build.VERSION.SDK_INT >= 28 &&
                activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)),
        )
    }

    private fun generateKey(alias: String, challenge: ByteArray, requireBiometric: Boolean): Map<String, Any?> {
        val ks = keyStore()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)

        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge(challenge)
            if (requireBiometric) {
                b.setUserAuthenticationRequired(true)
                if (Build.VERSION.SDK_INT >= 30) {
                    b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                } else {
                    @Suppress("DEPRECATION")
                    b.setUserAuthenticationValidityDurationSeconds(-1)
                }
                b.setInvalidatedByBiometricEnrollment(true)
            }
            if (strongBox && Build.VERSION.SDK_INT >= 28) b.setIsStrongBoxBacked(true)
            return b.build()
        }

        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val wantStrongBox = Build.VERSION.SDK_INT >= 28 &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        var usedStrongBox = wantStrongBox
        try {
            kpg.initialize(spec(wantStrongBox))
            kpg.generateKeyPair()
        } catch (e: Exception) {
            if (wantStrongBox && (e is StrongBoxUnavailableException || e.cause is StrongBoxUnavailableException)) {
                usedStrongBox = false
                kpg.initialize(spec(false))
                kpg.generateKeyPair()
            } else {
                throw e
            }
        }
        val chain = ks.getCertificateChain(alias)
            ?: throw IllegalArgumentException("This phone does not support hardware key attestation.")
        return mapOf(
            "chain" to chain.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) },
            "strongBox" to usedStrongBox,
        )
    }

    private fun sign(alias: String, payload: ByteArray, title: String, subtitle: String, result: MethodChannel.Result) {
        val key = keyStore().getKey(alias, null) as? PrivateKey
        if (key == null) {
            result.error("KEY_MISSING", "This phone is not registered for punching.", null)
            return
        }
        val signature = Signature.getInstance("SHA256withECDSA")
        try {
            signature.initSign(key)
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("KEY_INVALIDATED", "Biometrics changed on this phone. Register it again.", null)
            return
        }
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java)
        if (!info.isUserAuthenticationRequired) {
            signature.update(payload)
            result.success(Base64.encodeToString(signature.sign(), Base64.NO_WRAP))
            return
        }

        val replied = AtomicBoolean(false)
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    if (!replied.compareAndSet(false, true)) return
                    try {
                        val sig = res.cryptoObject?.signature
                            ?: throw IllegalStateException("No crypto object")
                        sig.update(payload)
                        result.success(Base64.encodeToString(sig.sign(), Base64.NO_WRAP))
                    } catch (e: Exception) {
                        result.error("DEVICE_KEY_ERROR", e.message ?: "Signing failed", null)
                    }
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    if (!replied.compareAndSet(false, true)) return
                    val cancelled = code == BiometricPrompt.ERROR_USER_CANCELED ||
                        code == BiometricPrompt.ERROR_NEGATIVE_BUTTON || code == BiometricPrompt.ERROR_CANCELED
                    result.error(if (cancelled) "BIOMETRIC_CANCELLED" else "BIOMETRIC_ERROR", msg.toString(), code)
                }
            })
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
    }

    /**
     * Plain "is this the phone's owner" check (fingerprint/face, or the
     * screen lock as a fallback) before showing private data such as salary.
     * Not key-bound: the data itself is still authorised by the server.
     */
    private fun confirmUser(title: String, subtitle: String, result: MethodChannel.Result) {
        val allowed = if (Build.VERSION.SDK_INT >= 30) BIOMETRIC_STRONG or DEVICE_CREDENTIAL
            else BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        if (BiometricManager.from(activity).canAuthenticate(allowed) != BiometricManager.BIOMETRIC_SUCCESS) {
            result.error("BIOMETRIC_NOT_ENROLLED", "Set up a fingerprint or screen lock on this phone first.", null)
            return
        }
        val replied = AtomicBoolean(false)
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    if (replied.compareAndSet(false, true)) result.success(true)
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    if (!replied.compareAndSet(false, true)) return
                    val cancelled = code == BiometricPrompt.ERROR_USER_CANCELED ||
                        code == BiometricPrompt.ERROR_NEGATIVE_BUTTON || code == BiometricPrompt.ERROR_CANCELED
                    result.error(if (cancelled) "BIOMETRIC_CANCELLED" else "BIOMETRIC_ERROR", msg.toString(), code)
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(allowed)
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(info)
    }

    /**
     * Fingerprint FIRST, payload later: unlocks one signature operation on
     * the key (CryptoObject) and keeps it for [signAuthorized]. The app reads
     * a fresh location only after the person has confirmed, so time spent
     * at the prompt never makes the location reading stale.
     */
    private fun authorize(alias: String, title: String, subtitle: String, result: MethodChannel.Result) {
        pending = null
        val key = keyStore().getKey(alias, null) as? PrivateKey
        if (key == null) {
            result.error("KEY_MISSING", "This phone is not registered for punching.", null)
            return
        }
        val signature = Signature.getInstance("SHA256withECDSA")
        try {
            signature.initSign(key)
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("KEY_INVALIDATED", "Biometrics changed on this phone. Register it again.", null)
            return
        }
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java)
        if (!info.isUserAuthenticationRequired) {
            pending = signature
            result.success(true)
            return
        }
        val replied = AtomicBoolean(false)
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    if (!replied.compareAndSet(false, true)) return
                    val sig = res.cryptoObject?.signature
                    if (sig == null) {
                        result.error("DEVICE_KEY_ERROR", "No crypto object", null)
                    } else {
                        pending = sig
                        result.success(true)
                    }
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    if (!replied.compareAndSet(false, true)) return
                    val cancelled = code == BiometricPrompt.ERROR_USER_CANCELED ||
                        code == BiometricPrompt.ERROR_NEGATIVE_BUTTON || code == BiometricPrompt.ERROR_CANCELED
                    result.error(if (cancelled) "BIOMETRIC_CANCELLED" else "BIOMETRIC_ERROR", msg.toString(), code)
                }
            })
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
    }
}
