import Foundation
import LoopKitUI
import SibionicsKit
import SibionicsKitUI

public final class SibionicsKitPlugin: NSObject, CGMManagerUIPlugin {
    public var pumpManagerType: PumpManagerUI.Type? { nil }
    public var cgmManagerType: CGMManagerUI.Type? { SibionicsCGMManager.self }

    override public init() { super.init() }
}
