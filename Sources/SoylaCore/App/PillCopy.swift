import Foundation

// APP-1 (c): the pill's failure cards in the interface language, and where their fix leads. The cards are built in
// English by the pipeline (and tested in English); `localized` swaps in Uzbek or Russian at display time. Every
// line here is an APP-1 addition (not in the prototype); Uzbek and Russian wait for the owner's review.

/// What a failure card's second button fixes.
public enum PillFix: Equatable, Sendable {
    /// A missing or refused key: setup's Connect when a cloud language is chosen, else the Languages page.
    case connectKey
    case setup(SetupStep)
    case page(SettingsPage)

    public func route(cloudLanguage: Bool) -> MenuRoute {
        switch self {
        case .connectKey: return cloudLanguage ? .setup(.connect) : .page(.languages)
        case .setup(let s): return .setup(s)
        case .page(let p): return .page(p)
        }
    }

    func button(_ t: AppStrings) -> String {
        switch self {
        case .connectKey: return t.connect
        case .setup: return t.pMicB
        case .page(let p): return t.pillOpen(t.page[p] ?? p.title)
        }
    }
}

extension PillFailure {
    /// The same card in `l` (English as built). Dynamic parts (a device name, an HTTP code) are kept.
    public func localized(_ l: UILanguage) -> PillFailure {
        guard l != .en else { return self }
        var f = self
        f.title = PillCopy.text(title, l)
        f.hint = PillCopy.text(hint, l)
        return f
    }
}

extension PillFailure {
    /// The card as drawn: in `l`, and a missing key worded from the shared readiness (V-10): "Uzbek needs an API key /
    /// English works without one." while English dictates, "Soyla needs an API key" when nothing does yet.
    public func shown(_ l: UILanguage, readiness: Readiness) -> PillFailure {
        guard fix == .connectKey, title == Self.noKeyTitle else { return PillCopy.typeset(localized(l)) }
        let t = AppStrings.for(l)
        var f = localized(l)
        f.kind = .info
        // D22: when English waits too, the card names Soyla, not only the cloud languages.
        let combo: CloudCombo? = if case .needsKey(let c, _, false) = readiness { c } else { nil }
        f.title = combo.map(t.pillKey) ?? t.keyTitle
        f.hint = readiness.englishWorks && combo != nil ? t.pillKeyHint : PillCopy.text(hint, l)
        return f
    }
}

enum PillCopy {
    /// V-32: the English cards are built (and tested) with straight apostrophes; they are drawn with ’ like the rest of
    /// the app. Only a letter–apostrophe–letter is changed, so codes and quotes stay as they are.
    static func typeset(_ f: PillFailure) -> PillFailure {
        var f = f
        f.title = curly(f.title); f.hint = curly(f.hint)
        return f
    }

    static func curly(_ s: String) -> String {
        s.replacingOccurrences(of: "(?<=\\p{L})'(?=\\p{L})", with: "’", options: .regularExpression)
    }

    static func text(_ en: String, _ l: UILanguage) -> String {
        guard l != .en, !en.isEmpty else { return en }
        if let pair = table[en] { return l == .uz ? pair.uz : pair.ru }
        if en.hasPrefix("No sound from ") {
            let name = String(en.dropFirst("No sound from ".count))
            return l == .uz ? "\(name)’dan ovoz kelmayapti" : "Нет звука от \(name)"
        }
        if en.hasPrefix("Transcription failed (HTTP "), let code = en.split(separator: " ").last?.dropLast() {
            return l == .uz ? "Matnga aylantirib bo‘lmadi (HTTP \(code))" : "Не удалось распознать (HTTP \(code))"
        }
        return en
    }

    static let table: [String: (uz: String, ru: String)] = [
        // titles
        "Didn't understand that": ("Tushunib bo‘lmadi", "Не удалось разобрать"),
        "No internet": ("Internet yo‘q", "Нет интернета"),
        "The server didn't answer in time": ("Server vaqtida javob bermadi", "Сервер не ответил вовремя"),
        "Couldn't reach the server": ("Serverga ulanib bo‘lmadi", "Не удалось связаться с сервером"),
        "No API key yet": ("Hali API key yo‘q", "API-ключа пока нет"),
        "Soyla can't read your API key": ("Soyla API key’ingizni o‘qiy olmayapti", "Soyla не может прочитать ваш API-ключ"),
        "Waiting for your Mac password": ("Mac parolingiz kutilmoqda", "Ждём пароль Mac"),
        "Your API key was refused": ("API key’ingiz qabul qilinmadi", "Ваш API-ключ отклонён"),
        "Out of OpenRouter credit": ("OpenRouter’da mablag‘ tugadi", "На OpenRouter закончились средства"),
        "Too many requests": ("So‘rovlar juda ko‘p", "Слишком много запросов"),
        "The speech service is having trouble": ("Nutq xizmatida nosozlik", "У сервиса распознавания сбой"),
        "No speech heard": ("Nutq eshitilmadi", "Речь не услышана"),
        "Didn't catch that": ("Eshitolmadim", "Не расслышал"),
        "The server sent an odd reply": ("Server g‘alati javob qaytardi", "Сервер прислал странный ответ"),
        "This server needs https": ("Bu serverga https kerak", "Этому серверу нужен https"),
        "Change its address in Languages → Custom.": ("Manzilini Tillar → Custom’da o‘zgartiring.", "Измените адрес в Языки → Custom."),
        "Not pasted: it's on your clipboard": ("Qo‘yilmadi: matn clipboard’da", "Не вставлено: текст в буфере обмена"),
        "Microphone problem": ("Mikrofonda muammo", "Проблема с микрофоном"),
        "Something went wrong": ("Nimadir xato ketdi", "Что-то пошло не так"),
        "Speaking Uzbek or Russian?": ("O‘zbek yoki rus tilida gapiryapsizmi?", "Говорите по-узбекски или по-русски?"),
        "English model not ready": ("Ingliz tili modeli tayyor emas", "Английская модель не готова"),
        "Allow Speech Recognition in Settings": ("Speech Recognition’ga ruxsat bering", "Разрешите Speech Recognition"),
        "Pasted as heard (cleanup skipped)": (AppStrings.uz.d.rsSkipped, AppStrings.ru.d.rsSkipped),
        "On-device engine unavailable": ("Shu Mac’da tanib olish ishlamayapti", "Распознавание на этом Mac недоступно"),
        // hints
        "Nothing was pasted. Retry, or say it again.": ("Hech narsa qo‘yilmadi. Qayta yuboring yoki yana ayting.",
                                                         "Ничего не вставлено. Повторите или скажите ещё раз."),
        "Your recording is saved. Retry when you're online.": ("Yozuv saqlandi. Internet bo‘lganda qayta yuboring.",
                                                                "Запись сохранена. Повторите, когда появится интернет."),
        "Your recording is saved. Retry.": ("Yozuv saqlandi. Qayta yuboring.", "Запись сохранена. Повторите."),
        "Check your internet, then retry.": ("Internetni tekshirib, qayta yuboring.", "Проверьте интернет и повторите."),
        "Connect a key to start dictating.": ("Diktovkani boshlash uchun API key ulang.", "Подключите ключ, чтобы начать диктовку."),
        "Quit and reopen Soyla, then click Always Allow.": ("Soyla’dan chiqib, qayta oching, so‘ng Always Allow’ni bosing.",
                                                            "Завершите и снова откройте Soyla, затем нажмите Always Allow."),
        "Type it in the macOS dialog, click Always Allow, then retry.": ("macOS oynasida parolni kiriting, Always Allow’ni bosing va qayta yuboring.",
                                                                         "Введите его в окне macOS, нажмите Always Allow и повторите."),
        "Replace it in Languages.": ("Uni Tillar sahifasida almashtiring.", "Замените его на странице «Языки»."),
        "Top up at openrouter.ai, then retry.": ("openrouter.ai’da hisobni to‘ldirib, qayta yuboring.", "Пополните баланс на openrouter.ai и повторите."),
        "Wait a few seconds, then retry.": ("Bir necha soniya kutib, qayta yuboring.", "Подождите несколько секунд и повторите."),
        "It's usually brief. Retry in a moment.": ("Odatda tez o‘tadi. Birozdan keyin qayta yuboring.", "Обычно это ненадолго. Повторите чуть позже."),
        PillFailure.otherModel: ("Qayta yuboring. Takrorlansa, Tillar sahifasida boshqa model tanlang.",
                                 "Повторите. Если не помогает, выберите другую модель на странице «Языки»."),
        PillFailure.allowAccessibility: ("⌘V’ni bosing. Avtomatik qo‘yish uchun Accessibility’ga ruxsat bering.",
                                         "Нажмите ⌘V. Чтобы вставлять сразу, разрешите Accessibility."),
        "Try again. If it repeats, choose another mic in System Settings → Sound.": (
            "Qayta urinib ko‘ring. Takrorlansa, System Settings → Sound’da boshqa mikrofonni tanlang.",
            "Попробуйте ещё раз. Если повторится, выберите другой микрофон в System Settings → Sound."),
        "Add a cloud key.": ("Cloud uchun API key qo‘shing.", "Добавьте облачный ключ."),
        "Open Soyla to finish setup.": ("Sozlashni tugatish uchun Soyla’ni oching.", "Откройте Soyla, чтобы закончить настройку."),
        "Your recording is saved. Retry after allowing it.": ("Yozuv saqlandi. Ruxsat bergach, qayta yuboring.",
                                                               "Запись сохранена. Повторите после разрешения."),
        "Try again or switch to Cloud.": ("Qayta urinib ko‘ring yoki Cloud’ga o‘ting.", "Попробуйте ещё раз или переключитесь на облако."),
        "If it's AirPods, they may be on your iPhone. Switch them to this Mac, or use the built-in mic (Privacy & data).": (
            "AirPods bo‘lsa, ular iPhone’ga ulangan bo‘lishi mumkin. Ularni shu Mac’ga o‘tkazing yoki ichki mikrofonni tanlang (Maxfiylik va ma’lumotlar).",
            "Если это AirPods, они могут быть подключены к iPhone. Переключите их на этот Mac или выберите встроенный микрофон («Конфиденциальность»)."),
        "A password field or Secure Keyboard Entry blocks typing. Press ⌘V if it's safe.": (
            "Parol maydoni yoki Secure Keyboard Entry yozishni to‘smoqda. Xavfsiz bo‘lsa, ⌘V’ni bosing.",
            "Поле пароля или Secure Keyboard Entry блокирует ввод. Нажмите ⌘V, если это безопасно."),
        "You switched apps. Press ⌘V where you want it.": ("Siz boshqa ilovaga o‘tdingiz. Kerakli joyda ⌘V’ni bosing.",
                                                           "Вы переключили приложение. Нажмите ⌘V там, где нужно."),
        "Press ⌘V to paste it.": ("Qo‘yish uchun ⌘V’ni bosing.", "Нажмите ⌘V, чтобы вставить."),
        // Flows audit 2026-10-19 (F-05, F-16)
        PillFailure.lidClosedHint: ("Mac’ingiz qopqog‘i yopiq, shuning uchun uning mikrofoni o‘chiq. Qopqoqni oching yoki mikrofon ulang.",
                                    "Крышка Mac закрыта, поэтому его микрофон выключен. Откройте крышку или подключите микрофон."),
        PillFailure.checkMicHint: ("Mikrofon ulangan va ovozi o‘chirilmaganini tekshiring yoki Maxfiylik va ma’lumotlar’da boshqasini tanlang.",
                                   "Проверьте, что микрофон подключён и не выключен, или выберите другой в «Конфиденциальности»."),
        "Soyla can’t hear you yet": (AppStrings.uz.micOff, AppStrings.ru.micOff),
        "Soyla can’t type for you yet": (AppStrings.uz.axOff, AppStrings.ru.axOff),
        "Allow the microphone first.": (AppStrings.uz.mMicFirst, AppStrings.ru.mMicFirst),
        "Allow Accessibility first.": (AppStrings.uz.mAxFirst, AppStrings.ru.mAxFirst),
    ]
}
