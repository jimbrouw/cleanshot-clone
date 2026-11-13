import Foundation
import SwiftUI
import AppKit

public struct ColorPickerPopoverView: View {
    @Binding var selectedColor: CodableColor
    @ObservedObject private var settings = SettingsStore.shared

    @State private var hexInput: String
    @State private var redInput: String
    @State private var greenInput: String
    @State private var blueInput: String
    @State private var alphaPercent: Double

    public init(selectedColor: Binding<CodableColor>) {
        self._selectedColor = selectedColor
        let c = selectedColor.wrappedValue
        _hexInput = State(initialValue: c.hexString.replacingOccurrences(of: "#", with: ""))
        _redInput = State(initialValue: "\(Int(round(c.red * 255)))")
        _greenInput = State(initialValue: "\(Int(round(c.green * 255)))")
        _blueInput = State(initialValue: "\(Int(round(c.blue * 255)))")
        _alphaPercent = State(initialValue: round(c.alpha * 100))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: selectedColor.nsColor))
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.2)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Color Palette")
                        .font(.headline)
                    Button {
                        NSColorSampler().show { picked in
                            if let picked = picked?.usingColorSpace(.sRGB) {
                                let newColor = CodableColor(
                                    red: picked.redComponent,
                                    green: picked.greenComponent,
                                    blue: picked.blueComponent,
                                    alpha: picked.alphaComponent
                                )
                                updateFromCodable(newColor)
                            }
                        }
                    } label: {
                        Label("Pick from Screen", systemImage: "eyedropper")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hex").font(.caption2).foregroundStyle(.secondary)
                    TextField("9425E7", text: $hexInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onChange(of: hexInput) { _, newVal in
                            if newVal.count == 6 {
                                let c = CodableColor(hex: newVal, alpha: alphaPercent / 100.0)
                                selectedColor = c
                                syncRGB(from: c)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("R").font(.caption2).foregroundStyle(.secondary)
                    TextField("R", text: $redInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 42)
                        .onSubmit { applyRGBInputs() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("G").font(.caption2).foregroundStyle(.secondary)
                    TextField("G", text: $greenInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 42)
                        .onSubmit { applyRGBInputs() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("B").font(.caption2).foregroundStyle(.secondary)
                    TextField("B", text: $blueInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 42)
                        .onSubmit { applyRGBInputs() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Alpha")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(alphaPercent))%")
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $alphaPercent, in: 10...100, step: 1)
                    .onChange(of: alphaPercent) { _, val in
                        var c = selectedColor
                        c.alpha = val / 100.0
                        selectedColor = c
                    }
            }

            Divider()

            HStack {
                Text("My Colors")
                    .font(.caption.bold())
                Spacer()
                Button("+ Add to My Colors") {
                    let swatch = ColorSwatch(
                        name: selectedColor.hexString,
                        hex: selectedColor.hexString,
                        alpha: selectedColor.alpha
                    )
                    if !settings.savedColors.contains(where: { $0.hex == swatch.hex && abs($0.alpha - swatch.alpha) < 0.01 }) {
                        settings.savedColors.append(swatch)
                    }
                }
                .controlSize(.small)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 7), spacing: 8) {
                ForEach(settings.savedColors) { swatch in
                    let color = CodableColor(hex: swatch.hex, alpha: swatch.alpha)
                    Button {
                        updateFromCodable(color)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(selectedColor.hexString == swatch.hex ? 0.9 : 0.2), lineWidth: selectedColor.hexString == swatch.hex ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(settings.showColorNames ? swatch.name : swatch.hex)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func updateFromCodable(_ c: CodableColor) {
        selectedColor = c
        hexInput = c.hexString.replacingOccurrences(of: "#", with: "")
        alphaPercent = round(c.alpha * 100)
        syncRGB(from: c)
    }

    private func syncRGB(from c: CodableColor) {
        redInput = "\(Int(round(c.red * 255)))"
        greenInput = "\(Int(round(c.green * 255)))"
        blueInput = "\(Int(round(c.blue * 255)))"
    }

    private func applyRGBInputs() {
        let r = Double(max(0, min(255, Int(redInput) ?? 0))) / 255.0
        let g = Double(max(0, min(255, Int(greenInput) ?? 0))) / 255.0
        let b = Double(max(0, min(255, Int(blueInput) ?? 0))) / 255.0
        let c = CodableColor(red: r, green: g, blue: b, alpha: alphaPercent / 100.0)
        selectedColor = c
        hexInput = c.hexString.replacingOccurrences(of: "#", with: "")
    }
}
