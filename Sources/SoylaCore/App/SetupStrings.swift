import Foundation

// OB-2: every word of first-run setup in English, Uzbek (Latin) and Russian, ported verbatim from the approved v5
// prototype's `T` table (bold as Markdown `**…**`, line breaks as `\n`). Plain Swift so it builds with the Command
// Line Tools: no .xcstrings, no bundle lookups. `{key}` is replaced by the hotkey's label.
// Rules: Uzbek keeps tech terms in English (Cloud, API key, Mac, macOS pane names, Allow / Don't Allow / Do Nothing);
// decimal comma in Uzbek and Russian; Soyla is feminine in Russian (готова, живёт).
// Lines marked "OB-2 addition" are not in v5 (key errors, other fn captions, the model on Try, Input Monitoring);
// their Uzbek and Russian wait for the owner's review.

struct SetupStrings: Sendable {
    let rail: [SetupStep: String]
    let wLine, wStart, wTime: String
    let railAria, uiAria: String
    let stepOf: @Sendable (Int, Int) -> String
    let cont, back, skip, finish, close: String

    let lTitle, lSub, lInfo: String
    let lTip: [String]
    let lEnSub, lClSub, lNone, lEn: String
    let lCloud: @Sendable (CloudCombo) -> String
    let dSteps: [String]
    let dField, dText: String

    let pTitle, pSub: String
    let pMic, pMicC, pMicB, pMicDenied: String
    let pAx, pAxC: String
    /// `var`: `naming(_:)` swaps in macOS's own words for its controls and panes (V-08).
    var pSet: String
    let pFn, pFnC: String
    var pFnDone: String
    let pFnB: String
    let pFnOr, pFnUses, tChange, tPick: String   // HOTKEY-1; pFnUses fills {key}
    let pOk, pFixed, pAll: String
    let pNext: [PendingPermission: String]
    var gMic, gMicSet: String
    let gAx: String
    var gFn: String
    let gDone: String
    var aw: [SystemSurface: String]
    let hAxT, hAxB, hMissing, hMissingT, hMissingB: String
    var hFnT: String
    let hFnB: String

    let cTitle: @Sendable (CloudCombo) -> String
    let cSub, cInfo: String
    let cTip: [String]
    let cG, cO, cS1: String
    let cOpen: @Sendable (String) -> String
    let cPh, cKeyAria, cConnect, cConnected, cOk, cChecking, cOpened, cSkip: String
    let rMac, rNoServer: String

    let tTitle, tSub: String
    let tReadIn: [SpokenLanguage: String]
    let tPh, tListen, tWrite, tShort, tOk: String
    let tSeconds: String
    let tLocal: String
    let tCloud: @Sendable (String) -> String

    let dnTitle, dnSub: String
    let dnMore: @Sendable (CloudCombo) -> String
    let dnMoreSub: String
    let n: [SpokenLanguage: String]
    let dnLocal, dnNeeds, dnReady, dnConnect: String
    let dnTry: @Sendable (SpokenLanguage) -> String
    let dsHere, dsSub, dsHold, holdAria: String

    // OB-2 additions
    let keyFail: [SetupKeyFailure: String]
    let pFnInput, pFnDictation: String
    let pIm, pImC: String
    let tNoKeys, tModelWait, tModelNone, tModelPermission: String

    // Audit 2026-10-19 additions (V-01, V-11, V-29): Done and Try while a permission is missing; Connect's Cancel
    // from the app. Their Uzbek and Russian wait for the owner's review.
    let dnBlocked, blMic, blAx, dnWait, cCancel: String
    let cReplace, dnMoreNoEn: String                                // flows F-20, F-03
    // Flows audit 2026-10-19 additions (F-04): captions that follow the engine.
    let lCloudVia, lEnVia, lTipCloud: @Sendable (String) -> String

    /// Try-it sentences: an everyday message with no proper nouns, so the recogniser can get it right.
    static let sample: [SpokenLanguage: String] = [
        .en: "I’m on my way, I’ll be there in ten minutes.",
        .uz: "Yo‘ldaman, o‘n daqiqada yetib boraman.",
        .ru: "Я уже еду, буду через десять минут.",
    ]
    /// macOS's own surfaces follow the macOS language, not the in-app picker (stage previews only). macOS names
    /// the app by its bundle name, so the dev build's preview says "Soyla Dev" like its real alert.
    static func macMicTitle(app: String) -> String { "“\(app)” Would Like to Access the Microphone" }
    static var appName: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Soyla" }

    static func `for`(_ l: UILanguage) -> SetupStrings {
        switch l { case .en: return en; case .uz: return uz; case .ru: return ru }
    }

    /// The table as shown on this Mac: the lines that name a macOS control or pane use the Mac's words (V-08).
    static func shown(_ l: UILanguage, mac: MacTerms.Language = MacTerms.current) -> SetupStrings { .for(l).naming(mac) }

    /// The lines that name a macOS control or pane, in `mac`'s words; the sentence around them stays in Soyla's language.
    func naming(_ mac: MacTerms.Language) -> SetupStrings {
        guard mac != .en else { return self }
        var t = self
        t.gMic = MacTerms.localize(gMic, mac); t.gMicSet = MacTerms.localize(gMicSet, mac); t.gFn = MacTerms.localize(gFn, mac)
        t.aw = aw.mapValues { MacTerms.localize($0, mac) }
        t.hFnT = MacTerms.localize(hFnT, mac); t.pSet = MacTerms.localize(pSet, mac); t.pFnDone = MacTerms.localize(pFnDone, mac)
        return t
    }

    /// The fn-row caption for the current "Press 🌐 key to" value (2 / absent = emoji picker).
    func fnCaption(usage: Int?) -> String {
        switch usage { case 1: return pFnInput; case 3: return pFnDictation; default: return pFnC }
    }

    static func cap1(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// `{key}` → the hotkey's short label ("fn").
    static func fill(_ s: String, key: String) -> String { s.replacingOccurrences(of: "{key}", with: key) }

    /// The text around `{key}`, so the view can draw the key inline; nil when there is no placeholder.
    static func around(_ s: String) -> (before: String, after: String)? {
        guard let r = s.range(of: "{key}") else { return nil }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
}

/// V-08 (audit 2026-10-19): macOS names its own buttons and panes in the Mac's language (`Locale.preferredLanguages`),
/// not in Soyla's interface language. On a Russian Mac the alert says «Разрешить», the app is «Системные настройки» and
/// the fn option is «Ничего не делать», so setup must name those words. Any other system language keeps the English
/// names (macOS has no Uzbek; English is what it shows then).
public enum MacTerms {
    public enum Language: Equatable, Sendable { case en, ru }

    public static func language(preferred: [String]) -> Language {
        guard let first = preferred.first?.lowercased() else { return .en }
        return first == "ru" || first.hasPrefix("ru-") || first.hasPrefix("ru_") ? .ru : .en
    }

    public static var current: Language { language(preferred: Locale.preferredLanguages) }

    /// English name → Russian macOS's, longest first so "Don’t Allow" and "System Settings" win over their parts.
    static let russian: [(en: String, ru: String)] = [
        ("Don’t Allow", "Не разрешать"), ("Do Nothing", "Ничего не делать"),
        // The app's name is never bold in the copy, so it carries its own quotes.
        ("System Settings", "«Системные настройки»"), ("Settings", "«Системные настройки»"), ("Allow", "Разрешить"),
    ]

    /// One control's name as this Mac shows it ("Allow", "Don’t Allow", "Do Nothing", "System Settings").
    public static func name(_ en: String, _ l: Language = current) -> String {
        guard l == .ru else { return en }
        return russian.first { $0.en == en }?.ru ?? en
    }

    /// Replaces the English names in a line that names macOS controls (bold `**Allow**`, quoted «Do Nothing», or a pane
    /// name like "Settings"). Placeholders (`{x}`) protect replaced words from the shorter names that follow.
    public static func localize(_ s: String, _ l: Language) -> String {
        guard l == .ru else { return s }
        var out = s
        for (i, pair) in russian.enumerated() { out = out.replacingOccurrences(of: pair.en, with: "{\(i)}") }
        for (i, pair) in russian.enumerated() { out = out.replacingOccurrences(of: "{\(i)}", with: pair.ru) }
        return out
    }
}

extension SetupStrings {
    static let en: SetupStrings = {
        let subj: [CloudCombo: String] = [.uz: "Uzbek", .ru: "Russian", .uzru: "Uzbek and Russian"]
        let n: [SpokenLanguage: String] = [.en: "English", .uz: "Uzbek", .ru: "Russian"]
        return SetupStrings(
            rail: [.welcome: "Welcome", .languages: "Languages", .permissions: "Permissions", .connect: "Connect", .tryIt: "Try it", .done: "Done"],
            wLine: "You speak. Soyla types.", wStart: "Start", wTime: "About 2 minutes",
            railAria: "Setup steps", uiAria: "Interface language",
            stepOf: { "Step \($0) of \($1)" },
            cont: "Continue", back: "Back", skip: "Skip", finish: "Finish", close: "Done",
            lTitle: "Which languages do you speak?", lSub: "Pick all that apply.", lInfo: "How each language works",
            lTip: ["**English** runs on this Mac with Apple’s speech model. Free, offline, and your audio never leaves the Mac.",
                   "**Uzbek and Russian** run in the Cloud with your own Google AI Studio or OpenRouter API key. Audio goes from your Mac straight to that service. There is no Soyla server."],
            lEnSub: "On this Mac · free", lClSub: "Cloud · needs an API key",
            lNone: "Pick at least one.", lEn: "Works offline. No account needed.",
            lCloud: { "\(subj[$0] ?? ""): one more step, about 2 minutes." },
            dSteps: ["Hold {key}", "Speak", "Let go"], dField: "Message", dText: "Hold {key}, speak, let go.",
            pTitle: "Let Soyla hear you and type for you", pSub: "Soyla listens only while you hold {key}.",
            pMic: "Hear your voice", pMicC: "Microphone", pMicB: "Allow…", pMicDenied: "Turned off in macOS",
            pAx: "Type where your cursor is", pAxC: "Accessibility", pSet: "Open Settings…",
            pFn: "Free up the fn key", pFnC: "Now opens emoji", pFnDone: "Set to Do Nothing", pFnB: "Fix…", pFnOr: "Or use another key", pFnUses: "Using {key} instead", tChange: "Change key", tPick: "Press the key you want, or click one",
            pOk: "Allowed", pFixed: "Done", pAll: "All set.",
            pNext: [.mic: "Start with the microphone.", .micSettings: "Start with the microphone.", .accessibility: "Next: typing.", .fn: "Last: the fn key."],
            gMic: "macOS will ask.\nClick **Allow**.", gMicSet: "Microphone is off.\nTurn on **Soyla** in Settings.",
            gAx: "Turn on the switch\nnext to **Soyla**.", gFn: "Set the globe key\nto **Do Nothing**.", gDone: "Hold to talk.",
            aw: [.micAlert: "Click **Allow**.", .accessibility: "Turn on **Soyla**.", .micSettings: "Turn on **Soyla**.",
                 .fnSetting: "Choose **Do Nothing**.", .inputMonitoring: "Turn on **Soyla**."],
            hAxT: "Turn on Soyla", hAxB: "macOS may ask for your password. This note closes itself.",
            hMissing: "Soyla isn’t listed", hMissingT: "Add it with +", hMissingB: "Choose Soyla in Applications, then turn it on.",
            hFnT: "Choose “Do Nothing”", hFnB: "This note closes itself.",
            cTitle: { "Connect \(subj[$0] ?? "")" }, cSub: "One API key, added once.", cInfo: "About the two services",
            cTip: ["**Google AI Studio** is free to start. On the free tier Google may use your audio to improve its models; a paid key keeps it out.",
                   "**OpenRouter** is pay as you go, about $0.005 per 40 seconds of speech. Best for sentences that mix languages.",
                   "Your key stays on this Mac, in a file only your user account can open."],
            cG: "Free to start", cO: "Pay as you go", cS1: "Create an API key", cOpen: { "Open \($0)" },
            cPh: "Paste the API key", cKeyAria: "API key", cConnect: "Connect", cConnected: "Connected",
            cOk: "Connected.", cChecking: "Checking…", cOpened: "Opened in your browser.", cSkip: "Skip for now",
            rMac: "This Mac", rNoServer: "No Soyla server in between",
            tTitle: "Try it once", tSub: "Hold {key}, read this aloud, let go.",
            tReadIn: [.en: "Read in English", .uz: "Read in Uzbek", .ru: "Read in Russian"],
            tPh: "Your words appear here", tListen: "Listening…", tWrite: "Writing…", tShort: "Hold a little longer.",
            tOk: "Works in every app.", tSeconds: "s",
            tLocal: "on this Mac", tCloud: { "via \($0)" },
            dnTitle: "Soyla is ready", dnSub: "Hold {key} in any app.",
            dnMore: { "One more step for \(subj[$0] ?? "")" }, dnMoreSub: "English works now.",
            n: n, dnLocal: "On this Mac", dnNeeds: "Needs an API key", dnReady: "Ready", dnConnect: "Connect…",
            dnTry: { "Try in \(n[$0] ?? "")" },
            dsHere: "Soyla lives here now", dsSub: "in the menu bar", dsHold: "Hold in any app to talk.", holdAria: "Hold to talk",
            keyFail: [.malformed: "That doesn’t look like an API key. Copy it again.",
                      .wrongProvider: "That key is for the other service. Pick it above.",
                      .rejected: "That key didn’t work. Check it and try again.",
                      .unreachable: "Couldn’t reach the service. Check the internet and try again.",
                      .notSaved: "Couldn’t save the key on this Mac."],
            pFnInput: "Now switches input source", pFnDictation: "Now starts Dictation",
            pIm: "Notice the {key} key", pImC: "Input Monitoring",
            tNoKeys: "Soyla can’t hear the {key} key yet.", tModelWait: "Getting English ready on this Mac…",
            tModelNone: "English on this Mac isn’t available here. You can skip.",
            tModelPermission: "Allow Speech Recognition for English.",
            dnBlocked: "One more step", blMic: "Allow the microphone first.", blAx: "Allow Accessibility first.",
            dnWait: "Waiting for permissions", cCancel: "Cancel", cReplace: "Replace…", dnMoreNoEn: "Add an API key, then hold {key}.",
            lCloudVia: { "Cloud · \($0)" }, lEnVia: { "English goes to \($0)." },
            lTipCloud: { "**English** goes to \($0) too while Cloud is on, with your API key." })
    }()

    static let uz: SetupStrings = {
        let subj: [CloudCombo: String] = [.uz: "o‘zbek tili", .ru: "rus tili", .uzru: "o‘zbek va rus tillari"]
        let n: [SpokenLanguage: String] = [.en: "Ingliz tili", .uz: "O‘zbek tili", .ru: "Rus tili"]
        return SetupStrings(
            rail: [.welcome: "Xush kelibsiz", .languages: "Tillar", .permissions: "Ruxsatlar", .connect: "Ulash", .tryIt: "Sinab ko‘rish", .done: "Tayyor"],
            wLine: "Siz gapirasiz, Soyla yozadi.", wStart: "Boshlash", wTime: "Taxminan 2 daqiqa",
            railAria: "Sozlash qadamlari", uiAria: "Interfeys tili",
            stepOf: { "\($1) qadamdan \($0)-qadam" },
            cont: "Davom etish", back: "Orqaga", skip: "O‘tkazib yuborish", finish: "Yakunlash", close: "Tayyor",
            lTitle: "Qaysi tillarda gapirasiz?", lSub: "Keraklilarini belgilang.", lInfo: "Har bir til qanday ishlaydi",
            lTip: ["**Ingliz tili** shu Mac’da Apple’ning nutq modeli bilan ishlaydi. Bepul, internetsiz, ovozingiz Mac’dan chiqmaydi.",
                   "**O‘zbek va rus tillari** Cloud’da, o‘zingizning Google AI Studio yoki OpenRouter API key’ingiz bilan ishlaydi. Ovoz Mac’dan to‘g‘ridan-to‘g‘ri shu xizmatga boradi. Soyla serveri yo‘q."],
            lEnSub: "Shu Mac’da · bepul", lClSub: "Cloud · API key kerak",
            lNone: "Kamida bittasini belgilang.", lEn: "Internetsiz ishlaydi. Hisob kerak emas.",
            lCloud: { "\(SetupStrings.cap1(subj[$0] ?? "")): yana bir qadam, taxminan 2 daqiqa." },
            dSteps: ["{key}’ni bosib turing", "Gapiring", "Qo‘yib yuboring"], dField: "Xabar",
            dText: "{key}’ni bosib turing, gapiring, qo‘yib yuboring.",
            pTitle: "Soyla sizni eshitsin va siz uchun yozsin", pSub: "Soyla faqat {key} bosib turilganda tinglaydi.",
            pMic: "Ovozingizni eshitish", pMicC: "Microphone", pMicB: "Ruxsat berish…", pMicDenied: "macOS’da o‘chirilgan",
            pAx: "Kursor turgan joyga yozish", pAxC: "Accessibility", pSet: "Settings’ni ochish…",
            pFn: "fn tugmasini bo‘shatish", pFnC: "Hozir emoji ochadi", pFnDone: "«Do Nothing» tanlandi", pFnB: "Tuzatish…", pFnOr: "Yoki boshqa tugmadan foydalaning", pFnUses: "Uning o‘rniga {key}", tChange: "Tugmani almashtirish", tPick: "Kerakli tugmani bosing yoki tanlang",
            pOk: "Ruxsat berildi", pFixed: "Tuzatildi", pAll: "Hammasi tayyor.",
            pNext: [.mic: "Microphone’dan boshlang.", .micSettings: "Microphone’dan boshlang.", .accessibility: "Keyingisi: yozish.", .fn: "Oxirgisi: fn tugmasi."],
            gMic: "macOS so‘raydi.\n**Allow**’ni bosing.", gMicSet: "Microphone o‘chiq.\nSettings’da **Soyla**’ni yoqing.",
            gAx: "**Soyla** yonidagi\ntugmachani yoqing.", gFn: "Globus tugmasi uchun\n**Do Nothing**’ni tanlang.", gDone: "Gapirish uchun bosib turing.",
            aw: [.micAlert: "**Allow**’ni bosing.", .accessibility: "**Soyla**’ni yoqing.", .micSettings: "**Soyla**’ni yoqing.",
                 .fnSetting: "**Do Nothing**’ni tanlang.", .inputMonitoring: "**Soyla**’ni yoqing."],
            hAxT: "Soyla’ni yoqing", hAxB: "macOS parol so‘rashi mumkin. Bu eslatma o‘zi yopiladi.",
            hMissing: "Soyla ro‘yxatda yo‘q", hMissingT: "+ bilan qo‘shing", hMissingB: "Applications’dan Soyla’ni tanlab, yoqing.",
            hFnT: "«Do Nothing»’ni tanlang", hFnB: "Bu eslatma o‘zi yopiladi.",
            cTitle: { "\(SetupStrings.cap1(subj[$0] ?? "")) uchun API\u{00A0}key ulang" }, cSub: "Bitta API key, bir marta qo‘shiladi.", cInfo: "Ikki xizmat haqida",
            cTip: ["**Google AI Studio**’da boshlash bepul. Bepul tarifda Google ovozingizdan o‘z modellarini yaxshilashda foydalanishi mumkin; pullik API key’da bunday bo‘lmaydi.",
                   "**OpenRouter**’da ishlatganingizga yarasha to‘laysiz: 40 soniya nutq taxminan $0,005. Aralash tilli gaplar uchun eng yaxshisi.",
                   "API key shu Mac’da, faqat sizning foydalanuvchi hisobingiz ocha oladigan faylda saqlanadi."],
            cG: "Boshlash bepul", cO: "Ishlatganingizga yarasha to‘lov", cS1: "API key yarating", cOpen: { "\($0) saytini ochish" },
            cPh: "API key’ni shu yerga qo‘ying", cKeyAria: "API key", cConnect: "Ulash", cConnected: "Ulandi",
            cOk: "Ulandi.", cChecking: "Tekshirilmoqda…", cOpened: "Brauzerda ochildi.", cSkip: "Hozircha o‘tkazib yuborish",
            rMac: "Shu Mac", rNoServer: "O‘rtada Soyla serveri yo‘q",
            tTitle: "Bir marta sinab ko‘ring", tSub: "{key}’ni bosib turing, buni o‘qing, qo‘yib yuboring.",
            tReadIn: [.en: "Ingliz tilida o‘qing", .uz: "O‘zbek tilida o‘qing", .ru: "Rus tilida o‘qing"],
            tPh: "So‘zlaringiz shu yerda chiqadi", tListen: "Tinglayapman…", tWrite: "Yozyapman…", tShort: "Biroz uzoqroq bosib turing.",
            tOk: "Har qanday ilovada ishlaydi.", tSeconds: "s",
            tLocal: "shu Mac’da", tCloud: { "\($0) orqali" },
            dnTitle: "Soyla tayyor", dnSub: "Istalgan ilovada {key}’ni bosib turing.",
            dnMore: { "\(SetupStrings.cap1(subj[$0] ?? "")) uchun yana bir qadam" }, dnMoreSub: "Ingliz tili hozir ishlaydi.",
            n: n, dnLocal: "Shu Mac’da", dnNeeds: "API key kerak", dnReady: "Ishlaydi", dnConnect: "Ulash…",
            dnTry: { "\($0 == .ru ? "Rus" : "O‘zbek") tilida sinab ko‘ring" },
            dsHere: "Soyla endi shu yerda", dsSub: "menyu satrida", dsHold: "Istalgan ilovada bosib turib gapiring.",
            holdAria: "Gapirish uchun bosib turing",
            keyFail: [.malformed: "Bu API key’ga o‘xshamaydi. Qaytadan nusxa oling.",
                      .wrongProvider: "Bu API key boshqa xizmatniki. Uni yuqorida tanlang.",
                      .rejected: "Bu API key ishlamadi. Tekshirib, qayta urinib ko‘ring.",
                      .unreachable: "Xizmatga ulanib bo‘lmadi. Internetni tekshirib, qayta urinib ko‘ring.",
                      .notSaved: "API key shu Mac’da saqlanmadi."],
            pFnInput: "Hozir klaviatura tilini almashtiradi", pFnDictation: "Hozir Dictation’ni yoqadi",
            pIm: "{key} tugmasini sezish", pImC: "Input Monitoring",
            tNoKeys: "Soyla hali {key} tugmasini sezmayapti.", tModelWait: "Ingliz tili shu Mac’da tayyorlanmoqda…",
            tModelNone: "Bu Mac’da ingliz tili mavjud emas. O‘tkazib yuborishingiz mumkin.",
            tModelPermission: "Ingliz tili uchun Speech Recognition’ga ruxsat bering.",
            dnBlocked: "Yana bir qadam", blMic: "Avval mikrofonga ruxsat bering.", blAx: "Avval Accessibility’ga ruxsat bering.",
            dnWait: "Ruxsat kutilmoqda", cCancel: "Bekor qilish", cReplace: "Almashtirish…", dnMoreNoEn: "API key qo‘shing, so‘ng {key}’ni bosib turing.",
            lCloudVia: { "Cloud · \($0)" }, lEnVia: { "Ingliz tili \($0) orqali ishlaydi." },
            lTipCloud: { "Cloud yoqilgan paytda **ingliz tili** ham \($0) orqali, API key’ingiz bilan ishlaydi." })
    }()

    static let ru: SetupStrings = {
        let gen: [CloudCombo: String] = [.uz: "узбекского", .ru: "русского", .uzru: "узбекского и русского"]
        let acc: [CloudCombo: String] = [.uz: "узбекский", .ru: "русский", .uzru: "узбекский и русский"]
        let n: [SpokenLanguage: String] = [.en: "Английский", .uz: "Узбекский", .ru: "Русский"]
        return SetupStrings(
            rail: [.welcome: "Добро пожаловать", .languages: "Языки", .permissions: "Разрешения", .connect: "Подключение", .tryIt: "Попробовать", .done: "Готово"],
            wLine: "Вы говорите, Soyla печатает.", wStart: "Начать", wTime: "Около 2 минут",
            railAria: "Шаги настройки", uiAria: "Язык интерфейса",
            stepOf: { "Шаг \($0) из \($1)" },
            cont: "Продолжить", back: "Назад", skip: "Пропустить", finish: "Завершить", close: "Готово",
            lTitle: "На каких языках вы говорите?", lSub: "Отметьте все подходящие.", lInfo: "Как работает каждый язык",
            lTip: ["**Английский** распознаёт модель Apple прямо на этом Mac. Бесплатно, без интернета, звук не покидает Mac.",
                   "**Узбекский и русский** работают в облаке по вашему API-ключу Google AI Studio или OpenRouter. Звук идёт с Mac напрямую к этому сервису. Серверов Soyla нет."],
            lEnSub: "На этом Mac · бесплатно", lClSub: "Облако · нужен API-ключ",
            lNone: "Отметьте хотя бы один.", lEn: "Работает без интернета. Аккаунт не нужен.",
            lCloud: { "Для \(gen[$0] ?? "") ещё один шаг, около 2 минут." },
            dSteps: ["Зажмите {key}", "Говорите", "Отпустите"], dField: "Сообщение", dText: "Зажмите {key}, скажите, отпустите.",
            pTitle: "Разрешите Soyla слышать вас и печатать за вас", pSub: "Soyla слушает, только пока вы держите {key}.",
            pMic: "Слышать ваш голос", pMicC: "Микрофон", pMicB: "Разрешить…", pMicDenied: "Выключен в macOS",
            pAx: "Печатать там, где курсор", pAxC: "Accessibility (Универсальный доступ)", pSet: "Открыть настройки…",
            pFn: "Освободить клавишу fn", pFnC: "Сейчас открывает эмодзи", pFnDone: "Выбрано «Do Nothing»", pFnB: "Исправить…", pFnOr: "Или выберите другую клавишу", pFnUses: "Вместо неё {key}", tChange: "Сменить клавишу", tPick: "Нажмите нужную клавишу или выберите",
            pOk: "Разрешено", pFixed: "Готово", pAll: "Всё готово.",
            pNext: [.mic: "Начните с микрофона.", .micSettings: "Начните с микрофона.", .accessibility: "Дальше: печать.", .fn: "Последнее: клавиша fn."],
            gMic: "macOS спросит.\nНажмите **Allow**.", gMicSet: "Микрофон выключен.\nВключите **Soyla** в настройках.",
            gAx: "Включите переключатель\nрядом с **Soyla**.", gFn: "Для клавиши с глобусом\nвыберите **Do Nothing**.", gDone: "Зажмите, чтобы говорить.",
            aw: [.micAlert: "Нажмите **Allow**.", .accessibility: "Включите **Soyla**.", .micSettings: "Включите **Soyla**.",
                 .fnSetting: "Выберите **Do Nothing**.", .inputMonitoring: "Включите **Soyla**."],
            hAxT: "Включите Soyla", hAxB: "macOS может спросить пароль. Подсказка закроется сама.",
            hMissing: "Soyla нет в списке", hMissingT: "Добавьте через +", hMissingB: "Выберите Soyla в Applications и включите.",
            hFnT: "Выберите «Do Nothing»", hFnB: "Подсказка закроется сама.",
            cTitle: { "Подключите \(acc[$0] ?? "")" }, cSub: "Один API-ключ, подключается один раз.", cInfo: "О двух сервисах",
            cTip: ["У **Google AI Studio** есть бесплатный тариф. На нём Google может использовать ваш звук для улучшения моделей; с платным ключом этого нет.",
                   "**OpenRouter**: оплата по факту, около $0,005 за 40 секунд речи. Лучше всего для фраз на смеси языков.",
                   "Ключ хранится на этом Mac, в файле, который может открыть только ваша учётная запись."],
            cG: "Бесплатно для начала", cO: "Оплата по факту", cS1: "Создайте API-ключ", cOpen: { "Открыть \($0)" },
            cPh: "Вставьте API-ключ", cKeyAria: "API-ключ", cConnect: "Подключить", cConnected: "Подключено",
            cOk: "Подключено.", cChecking: "Проверяем…", cOpened: "Открыто в браузере.", cSkip: "Пока пропустить",
            rMac: "Этот Mac", rNoServer: "Серверов Soyla между ними нет",
            tTitle: "Попробуйте один раз", tSub: "Зажмите {key}, прочитайте вслух, отпустите.",
            tReadIn: [.en: "Читайте по-английски", .uz: "Читайте по-узбекски", .ru: "Читайте по-русски"],
            tPh: "Здесь появятся ваши слова", tListen: "Слушаю…", tWrite: "Пишу…", tShort: "Держите чуть дольше.",
            tOk: "Работает в любом приложении.", tSeconds: "с",
            tLocal: "на этом Mac", tCloud: { "через \($0)" },
            dnTitle: "Soyla готова", dnSub: "Зажмите {key} в любом приложении.",
            dnMore: { "Ещё один шаг для \(gen[$0] ?? "")" }, dnMoreSub: "Английский уже работает.",
            n: n, dnLocal: "На этом Mac", dnNeeds: "Нужен API-ключ", dnReady: "Работает", dnConnect: "Подключить…",
            dnTry: { "Попробовать \($0 == .ru ? "по-русски" : "по-узбекски")" },
            dsHere: "Теперь Soyla живёт здесь", dsSub: "в строке меню", dsHold: "Зажмите в любом приложении и говорите.",
            holdAria: "Зажмите, чтобы говорить",
            keyFail: [.malformed: "Это не похоже на API-ключ. Скопируйте его ещё раз.",
                      .wrongProvider: "Это ключ другого сервиса. Выберите его выше.",
                      .rejected: "Ключ не подошёл. Проверьте его и попробуйте снова.",
                      .unreachable: "Не удалось связаться с сервисом. Проверьте интернет и попробуйте снова.",
                      .notSaved: "Не удалось сохранить ключ на этом Mac."],
            pFnInput: "Сейчас переключает раскладку", pFnDictation: "Сейчас включает диктовку",
            pIm: "Слышать клавишу {key}", pImC: "Input Monitoring",
            tNoKeys: "Soyla пока не слышит клавишу {key}.", tModelWait: "Готовим английский на этом Mac…",
            tModelNone: "Английский на этом Mac недоступен. Можно пропустить.",
            tModelPermission: "Разрешите Speech Recognition для английского.",
            dnBlocked: "Ещё один шаг", blMic: "Сначала разрешите доступ к микрофону.",
            blAx: "Сначала включите Универсальный доступ (Accessibility).", dnWait: "Ждёт разрешений", cCancel: "Отмена", cReplace: "Заменить…", dnMoreNoEn: "Добавьте API-ключ, затем зажмите {key}.",
            lCloudVia: { "Облако · \($0)" }, lEnVia: { "Английский идёт через \($0)." },
            lTipCloud: { "Пока включено облако, **английский** тоже идёт через \($0) с вашим API-ключом." })
    }()
}
