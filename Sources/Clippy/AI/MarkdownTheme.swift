import SwiftUI
import MarkdownUI

extension MarkdownUI.Theme {
    /// A Markdown theme mapped onto Clippy's token + typography system so
    /// assistant replies match the panel, with real fenced code blocks.
    static func clippy(tokens: ThemeTokens, settings: AppSettings) -> MarkdownUI.Theme {
        // fontSizeBase is an Int (UserDefaults-backed); FontSize(_:) takes a
        // CGFloat, so convert before scaling to keep the arithmetic in CGFloat.
        let baseSize = CGFloat(settings.fontSizeBase)

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(tokens.textPrimary)
                FontSize(baseSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(baseSize * 0.92)
                BackgroundColor(tokens.cardSurface)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(baseSize * 0.92)
                            ForegroundColor(tokens.textPrimary)
                        }
                }
                .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))
                .markdownMargin(top: 6, bottom: 6)
            }
            .link {
                ForegroundColor(tokens.accent)
            }
    }
}
