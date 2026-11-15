import CoreBluetooth
import Foundation

/// The sensor's GATT surface.
///
/// There is **no BLE bonding and no link-layer encryption** on a GS3. All
/// security is the application-layer cipher, which is why this driver refuses to
/// do anything interesting before the auth frame has been acknowledged: an
/// unauthenticated `ff32` write is answered with the bootstrap frame and
/// nothing else.
public enum SibionicsGATT {
    /// `0000ff30-0000-1000-8000-00805f9b34fb`
    public static let service = CBUUID(string: "FF30")

    /// Sensor → phone. Every reply and every record arrives here.
    public static let notifyCharacteristic = CBUUID(string: "FF31")

    /// Phone → sensor. V3 requires **Write Request** (acknowledged), not Write
    /// Without Response, and the frame must fit the negotiated MTU.
    public static let writeCharacteristic = CBUUID(string: "FF32")

    public static let batteryService = CBUUID(string: "180F")
    public static let batteryLevel = CBUUID(string: "2A19")

    public static let deviceInfoService = CBUUID(string: "180A")
    public static let manufacturerName = CBUUID(string: "2A29")
    public static let modelNumber = CBUUID(string: "2A24")
    public static let serialNumber = CBUUID(string: "2A25")
    public static let hardwareRevision = CBUUID(string: "2A27")
    public static let firmwareRevision = CBUUID(string: "2A26")
    /// Carries `_V3.` on a V3 sensor; the only generation signal there is.
    public static let softwareRevision = CBUUID(string: "2A28")

    public static let servicesToDiscover: [CBUUID] = [service, deviceInfoService, batteryService]

    /// A 23-byte ATT MTU gives a 20-byte write payload. The activation frame is
    /// 19 bytes, so it fits even without MTU negotiation; longer reads benefit
    /// from a bigger MTU but nothing depends on it.
    public static let defaultWritePayload = 20
    public static let preferredMTU = 185
}
