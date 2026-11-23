package dev.hloth.nativenote

import android.Manifest
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.drawable.AdaptiveIconDrawable
import android.security.NetworkSecurityPolicy
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.xmlpull.v1.XmlPullParser

@RunWith(AndroidJUnit4::class)
class PlatformPolicyTest {
	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	@Test
	fun backupIsOff() {
		assertEquals(0, context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
	}

	@Test
	fun cloudBackupAndDeviceTransferExcludeEveryDomain() {
		val expected = listOf("cloud-backup", "device-transfer").flatMap { section ->
			listOf("root", "device_root", "external").map { "data-extraction-rules/$section/exclude domain=$it path=." }
		}

		assertEquals(expected, elementsOf(R.xml.data_extraction_rules).filter { "/exclude " in it })
	}

	@Test
	fun plainHttpReachesAnyHost() {
		assertTrue(NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("192.0.2.1"))
		assertTrue(NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("notes.example"))
	}

	@Test
	fun httpsTrustsSystemAndUserCertificates() {
		val anchors = "network-security-config/base-config/trust-anchors/certificates"

		assertEquals(listOf("$anchors src=system", "$anchors src=user"), elementsOf(R.xml.network_security_config).filter { it.startsWith(anchors) })
	}

	@Test
	fun internetAndBiometricsAreTheOnlyPermissionsTheAppDeclaresFromOutsideIt() {
		@Suppress("DEPRECATION")
		val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
		val declared = info.requestedPermissions.orEmpty().filterIndexed { index, permission ->
			info.requestedPermissionsFlags!![index] and PackageInfo.REQUESTED_PERMISSION_IMPLICIT == 0 &&
				!permission.startsWith("${context.packageName}.")
		}

		assertEquals(listOf(Manifest.permission.INTERNET, Manifest.permission.USE_BIOMETRIC), declared)
	}

	@Test
	fun theLauncherIconIsAdaptiveWithAMonochromeLayerForThemedIcons() {
		val icon = context.packageManager.getApplicationIcon(context.packageName)

		assertTrue(icon is AdaptiveIconDrawable)
		assertTrue((icon as AdaptiveIconDrawable).monochrome != null)
	}

	private fun elementsOf(xml: Int): List<String> {
		val parser = context.resources.getXml(xml)
		val path = ArrayDeque<String>()
		val elements = mutableListOf<String>()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			when (parser.eventType) {
				XmlPullParser.START_TAG -> {
					path.addLast(parser.name)
					val attributes = (0 until parser.attributeCount).map { "${parser.getAttributeName(it)}=${parser.getAttributeValue(it)}" }
					elements += (listOf(path.joinToString("/")) + attributes).joinToString(" ")
				}
				XmlPullParser.END_TAG -> path.removeLast()
			}
		}
		return elements
	}
}
