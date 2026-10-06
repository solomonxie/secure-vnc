import Foundation

/// X11 keysyms used by RFB key events.
public enum KeySym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let enter: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let shift: UInt32 = 0xFFE1
    public static let control: UInt32 = 0xFFE3
    public static let option: UInt32 = 0xFFE9 // Alt_L
    public static let command: UInt32 = 0xFFE7 // Meta_L
    public static func f(_ n: Int) -> UInt32 { 0xFFBE + UInt32(n - 1) }

    public static func of(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar {
        case "\n", "\r": enter
        case "\t": tab
        case _ where scalar.value >= 0x20 && scalar.value <= 0xFF: scalar.value
        default: 0x0100_0000 | scalar.value
        }
    }
}
