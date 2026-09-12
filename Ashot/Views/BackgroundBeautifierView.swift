import SwiftUI

struct BackgroundBeautifierView: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var style = ImageBackground()
    @State private var finished = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Beautify Screenshot").font(.title2.bold())
            if let image = try? viewModel.previewImage(scale: 0.5) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 220)
            }
            HStack {
                Text("Background")
                ForEach(0..<4, id: \.self) { index in
                    Button("\(index + 1)") {
                        switch index {
                        case 0: style.color = RGBA(red: 0.15, green: 0.24, blue: 0.46); style.secondColor = RGBA(red: 0.42, green: 0.3, blue: 0.65)
                        case 1: style.color = RGBA(red: 0.93, green: 0.94, blue: 0.96); style.secondColor = nil
                        case 2: style.color = RGBA(red: 0.08, green: 0.09, blue: 0.11); style.secondColor = nil
                        default: style.color = RGBA(red: 0.16, green: 0.46, blue: 0.36); style.secondColor = RGBA(red: 0.35, green: 0.65, blue: 0.47)
                        }
                    }.accessibilityLabel(Text("Background preset \(index + 1)"))
                }
            }
            Slider(value: $style.padding, in: 0...160, step: 4) { Text("Padding") }
            Slider(value: $style.cornerRadius, in: 0...48, step: 2) { Text("Corner Radius") }
            Slider(value: $style.shadow, in: 0...48, step: 2) { Text("Shadow") }
            HStack {
                Button("Cancel", role: .cancel) { viewModel.cancelTransaction(); finished = true; dismiss() }
                Button("Remove Background") { viewModel.applyBackground(nil); viewModel.endTransaction(); finished = true; dismiss() }
                Spacer()
                Button("Apply") { viewModel.endTransaction(); finished = true; dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 490)
        .onAppear {
            style = viewModel.document.background ?? ImageBackground()
            viewModel.beginTransaction(L10n.string("Beautify")); viewModel.applyBackground(style)
        }
        .onChange(of: style) { viewModel.applyBackground(style) }
        .onDisappear { if !finished { viewModel.cancelTransaction() } }
    }
}
