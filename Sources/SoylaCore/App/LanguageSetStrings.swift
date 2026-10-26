import Foundation

// D26(b) · BL-04: the words of the language set (Settings → Dictation → My languages, History → Retry as…, the pill's
// chip) in English, Uzbek (Latin) and Russian. Its own small table so the big ones stay untouched (BL-03 edits them in
// parallel). Same rules as `AppStrings`: Uzbek uses ‘ and calls the pill "indikator"; Soyla is feminine in Russian.
// Uzbek and Russian wait for the owner's review.

struct LanguageSetStrings: Sendable {
    let title, caption, info, retryAs, mine, chipWord: String

    /// VoiceOver for the pill chip: "Languages: UZ·EN".
    func chipA11y(_ chip: String) -> String { "\(chipWord): \(chip)" }

    static func `for`(_ l: UILanguage) -> LanguageSetStrings {
        switch l { case .en: return en; case .uz: return uz; case .ru: return ru }
    }

    static let en = LanguageSetStrings(
        title: "My languages", caption: "Soyla writes only these",
        info: "Soyla tells the model you speak only these languages and checks that the text uses their alphabets. Keep all three for mixed speech. When not all three are ticked, a small label on the pill shows them while you record.",
        retryAs: "Retry as", mine: "My languages", chipWord: "Languages")

    static let uz = LanguageSetStrings(
        title: "Mening tillarim", caption: "Soyla faqat shu tillarda yozadi",
        info: "Soyla modelga faqat shu tillarda gapirishingizni aytadi va matn ularning alifbosida yozilganini tekshiradi. Aralash nutq uchun uchalasini qoldiring. Uchalasi belgilanmagan bo‘lsa, yozish paytida indikatordagi kichik belgi ularni ko‘rsatadi.",
        retryAs: "Shu tilda qayta yuborish", mine: "Mening tillarim", chipWord: "Tillar")

    static let ru = LanguageSetStrings(
        title: "Мои языки", caption: "Soyla пишет только на них",
        info: "Soyla сообщает модели, что вы говорите только на этих языках, и проверяет, что текст написан их алфавитом. Для смешанной речи оставьте все три. Если отмечены не все три, во время записи маленький ярлык на индикаторе показывает выбранные языки.",
        retryAs: "Повторить на языке", mine: "Мои языки", chipWord: "Языки")
}
