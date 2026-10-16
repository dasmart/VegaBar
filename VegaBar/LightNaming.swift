import Foundation

/// Display names for lights, matching what the ZY Vega phone app shows.
///
/// A light advertises its internal product code and a per-unit suffix, such as
/// "PL103_8723". The phone app shows the product name with the same suffix
/// instead: "MOLUS G60_8723". VegaBar does the same, preferring the model the
/// light reports in its device info, then a table of known codes. On the PL103
/// the device info's model field is empty, so the table is what names it.
enum LightNaming {
    /// Internal product codes seen in Bluetooth names, and their product names.
    /// Only lights that have been confirmed are listed.
    static let productNames: [String: String] = [
        "PL103": "MOLUS G60",
    ]

    /// The product-style name for a light, or nil to keep `bluetoothName`.
    ///
    /// - parameters:
    ///   - bluetoothName: the advertised name, `<code>_<suffix>`.
    ///   - model: the model string from the light's device info, if read.
    static func displayName(bluetoothName: String, model: String? = nil) -> String? {
        guard let underscore = bluetoothName.lastIndex(of: "_") else { return nil }
        let code = String(bluetoothName[..<underscore])
        let suffix = bluetoothName[bluetoothName.index(after: underscore)...]
        guard !code.isEmpty, !suffix.isEmpty else { return nil }
        let product = usable(model, code: code) ?? productNames[code.uppercased()]
        guard let product else { return nil }
        return "\(product)_\(suffix)"
    }

    /// A model string worth showing: printable, not empty, and not just the
    /// product code again. Upper-cased, as the phone app shows it.
    private static func usable(_ model: String?, code: String) -> String? {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty,
              m.count <= 40, m.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              m.caseInsensitiveCompare(code) != .orderedSame else { return nil }
        return m.uppercased()
    }
}
