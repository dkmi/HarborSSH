import SwiftUI

enum AppLanguage: String, CaseIterable {
    case en, bg
    static let preferenceKey = "appLanguage"
    static func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .en
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage = .current()) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func serverCount(_ count: Int) -> String {
        String(format: text("server_count"), locale: Locale(identifier: AppLanguage.current().rawValue), count)
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var selected = AppLanguage.en.rawValue
    var body: some View {
        HStack(spacing: 4) {
            languageButton(.en, title: "EN")
            languageButton(.bg, title: "BG")
        }
        .padding(4)
        .background(Color.white.opacity(0.08), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Language"))
    }

    private func languageButton(_ language: AppLanguage, title: String) -> some View {
        Button { selected = language.rawValue } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected == language.rawValue ? Color.black : Color.white)
                .frame(width: 44, height: 36)
                .background(selected == language.rawValue ? Color.mint : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language == .en ? "English" : "Български")
        .accessibilityAddTraits(selected == language.rawValue ? .isSelected : [])
    }
}
