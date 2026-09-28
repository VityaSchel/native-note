import Testing

@testable import PowerLossKit

struct DHCPLeasesTests {
	private let leases = """
		{
			name=builder
			ip_address=192.168.64.5
			hw_address=1,2:6e:6e:70:6c:1
			identifier=1,2:6e:6e:70:6c:1
			lease=0x6aa51795
		}
		{
			ip_address=192.168.64.9
			hw_address=1,2:6e:6e:70:6c:1
			identifier=1,2:6e:6e:70:6c:1
			lease=0x6aa51800
		}
		{
			name=other
			ip_address=192.168.64.13
			hw_address=1,6e:68:fa:37:58:81
			identifier=1,6e:68:fa:37:58:81
			lease=0x68e34a7d
		}
		{
			name=incomplete
			hw_address=1,2:6e:6e:70:6c:1
			lease=0x7fffffff
		}
		"""

	@Test func everyCompleteLeaseIsRead() {
		#expect(DHCPLeases.parse(leases) == [
			DHCPLease(ipAddress: "192.168.64.5", hardwareAddress: "2:6e:6e:70:6c:1", lease: 0x6AA5_1795),
			DHCPLease(ipAddress: "192.168.64.9", hardwareAddress: "2:6e:6e:70:6c:1", lease: 0x6AA5_1800),
			DHCPLease(ipAddress: "192.168.64.13", hardwareAddress: "6e:68:fa:37:58:81", lease: 0x68E3_4A7D),
		])
	}

	@Test func theNewestLeaseForTheMACAddressWinsWhateverItsZeroPadding() {
		#expect(DHCPLeases.address(of: "02:6E:6E:70:6C:01", in: leases) == "192.168.64.9")
		#expect(DHCPLeases.address(of: "6e:68:fa:37:58:81", in: leases) == "192.168.64.13")
	}

	@Test func anUnknownMACAddressHasNoLease() {
		#expect(DHCPLeases.address(of: "02:6e:6e:70:6c:02", in: leases) == nil)
		#expect(DHCPLeases.address(of: "02:6e:6e:70:6c:01", in: "") == nil)
	}

	@Test func aZeroOctetStaysOneDigit() {
		#expect(DHCPLeases.normalized("1,00:0a:10:ff:00:01") == "0:a:10:ff:0:1")
	}
}
