import Foundation

// APP-1 (d): the last user-facing words of the main app in English, Uzbek (Latin) and Russian: the personal dictionary,
// History cards, pill captions and menus, Report a Problem, update prompts and the update card, the custom-endpoint
// card, and the free engine's status lines. Reached as `AppStrings.for(language).d`. Same rules as `AppStrings`: Uzbek
// keeps tech terms in English (Cloud, API key, Mac, macOS, Keychain, Google AI Studio, OpenRouter); decimal comma in
// Uzbek and Russian; Soyla is feminine in Russian. None of this is in the prototype: Uzbek and Russian wait for the
// owner's review. English is byte-identical to what each view and pure function said before.

struct AppDStrings: Sendable {
    // Personal dictionary
    let dcIntro, dcHeard, dcWrite, dcRemove, dcAdd, dcVocab: String
    let dcLimit: @Sendable (Int) -> String

    // History cards
    let hPlay, hStop, hRetry, hPlayH, hStopH, hRetryH, hCopyH, hRetryModel, hCleanH, hVersionA: String
    let stWorking, stDone, stFailed, stCancelled, stInterrupted: String
    let phFailed, phFailedRetry, phCancelled, phPending, phEmpty: String     // phCancelled: audit V-19
    let phInterrupted, phInterruptedRetry: @Sendable (Double) -> String
    let fNoRec, fNoRecRetry, fRetrying, fBusy: String
    let months: [String]

    // Names of settings choices
    let spot: [PillSpot: String]
    let kRightOption, kRightCommand, kRightControl, sSoyla, sGlass, sWood, sClassic, sSystem, sOff: String

    // The pill
    let pcNeedsPerm, pcTranscribing, pcCleaning, pcPasting, pcPasted, pcDrag, pcStill, pcSlow: String
    let pcDismiss, pcHide1h, pcResetPos, pcBusy, anRecording, anTranscribing: String
    let keyA11y: @Sendable (String) -> String                            // VoiceOver: "fn key"
    let keyHeld: String
    let pcIdle, pcReady: @Sendable (String) -> String      // the hotkey's label
    let pcLeft: @Sendable (Int) -> String

    // Report a Problem
    let rpTitle, rpIntro, rpNote, rpOpen, rpOpenH: String

    // Update prompts, the update card and its failures
    let upAvailText, upToDate, upNoneT, upNoneText, upFailT, upNetText, upBadText, upOK: String
    let upAvail, upToDateText, upButton, ucRestart: @Sendable (String) -> String
    let ucAvail, ucFailed, ucRestarting, ucRetry, ucTip, ucHide, ucHideA, ucPage: String
    let ucDownloading: @Sendable (Int) -> String
    let ucA11y: @Sendable (String, String) -> String
    let sfBusy, sfNotOffered, sfNetwork, sfVerify, sfUnsigned, sfNotWritable, sfInstall: String

    // Custom endpoint (developer mode) and its key card
    let ceBase, ceBaseC, ceAny: String
    let ceEnv: @Sendable (Bool) -> String
    let kcEmpty, kcSaved, kcUsed, kcOptional, kcWorks, kcMore, kcReplaceKey, kcCheckAgain, kcUse, kcPaste, kcType, kcSave, kcField: String
    let kcPasteH, kcStep2, kpEmpty, kpSpaces: String
    let kcAsking, kcA11y: @Sendable (String) -> String
    let kcRefused: @Sendable (String) -> String

    // D26 (c): Raw (the old Off), the fallback note, the History badge
    let rsRawC, rsSkipped, rsBadgeH: String

    // Free engine status (EngineCopy) and the switch offer (EngineSwitchPrompt)
    let ecChecking, ecReady, ecDlFailed, ecNeedsDl, ecNeedsPerm, ecNoLocale, ecNoModel, ecRestricted, ecSlotsFull, ecOsOld: String
    let ecDownload, ecRetry, atNeedsDl, atNeedsPerm, atUnavailable: String
    let ecDownloading, atDownloading: @Sendable (Int) -> String
    let spToCloudT, spToFreeT, spToCloudM, spToFreeM, spToCloudB, spToFreeB, spStay, spNotNow: String

    static func `for`(_ l: UILanguage) -> AppDStrings { AppStrings.for(l).d }

    /// 1.5 as "1.5" or "1,5".
    static func num(_ x: Double, comma: Bool) -> String {
        let v = String(format: "%.1f", x)
        return comma ? v.replacingOccurrences(of: ".", with: ",") : v
    }

    func hotkey(_ c: HotkeyChoice) -> String {
        switch c {
        case .fn: return "fn"
        case .rightOption: return kRightOption
        case .rightCommand: return kRightCommand
        case .rightControl: return kRightControl
        case .ctrlShiftSpace: return "⌃⇧Space"
        case .f13: return "F13"
        }
    }

    func sound(_ s: SoundSet) -> String {
        switch s {
        case .soyla: return sSoyla
        case .glass: return sGlass
        case .wood: return sWood
        case .classic: return sClassic
        case .system: return sSystem
        case .off: return sOff
        }
    }

    func status(_ s: RunStatus) -> String {
        switch s {
        case .pending: return stWorking
        case .ok: return stDone
        case .failed: return stFailed
        case .cancelled: return stCancelled
        case .interrupted: return stInterrupted
        }
    }

    /// "15 Oct 14:02": day, the language's month abbreviation, time.
    func dayMonth(_ day: Int, _ month: Int) -> String { "\(day) \(months[max(0, min(11, month - 1))])" }
}

extension AppDStrings {
    static let en = AppDStrings(
        dcIntro: "Replacements: whenever Soyla writes the left word, it pastes the right one (names, spellings).",
        dcHeard: "Heard", dcWrite: "Write", dcRemove: "Remove replacement", dcAdd: "Add replacement",
        dcVocab: "Names and terms the model should spell correctly, one per line.", dcLimit: { "Limit reached (\($0))." },
        hPlay: "Play", hStop: "Stop", hRetry: "Retry", hPlayH: "Play the recording", hStopH: "Stop playback",
        hRetryH: "Send the recording again and copy the result (right-click for another model)", hCopyH: "Copy the text",
        hRetryModel: "Retry with another model", hCleanH: "Show the corrected text or the raw transcript", hVersionA: "Text version",
        stWorking: "Working", stDone: "Done", stFailed: "Failed", stCancelled: "Cancelled", stInterrupted: "Interrupted",
        phFailed: "Nothing was pasted.", phFailedRetry: "Nothing was pasted. Retry sends the recording again.", phCancelled: "Cancelled before sending.",
        phPending: "Transcribing…", phEmpty: "(empty)",
        phInterrupted: { String(format: "Recording interrupted (%.1f s)", $0) },
        phInterruptedRetry: { String(format: "Recording interrupted (%.1f s) — Retry to transcribe it", $0) },
        fNoRec: "Recording not kept", fNoRecRetry: "Recording not kept — nothing to retry",
        fRetrying: "Retrying… the result will be copied", fBusy: "Busy — try again in a moment",
        months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        spot: [.topLeft: "Top left", .topCenter: "Top centre", .topRight: "Top right",
               .bottomLeft: "Bottom left", .bottomCenter: "Bottom centre", .bottomRight: "Bottom right"],
        kRightOption: "Right ⌥", kRightCommand: "Right ⌘", kRightControl: "Right ⌃", sSoyla: "Soft", sGlass: "Glass", sWood: "Wood", sClassic: "Classic beeps",
        sSystem: "System", sOff: "Off",
        pcNeedsPerm: "Soyla needs permissions", pcTranscribing: "Transcribing…", pcCleaning: "Cleaning up…", pcPasting: "Pasting…",
        pcPasted: "Pasted", pcDrag: "Drag me where you want me", pcStill: "Still working…", pcSlow: "Taking longer than usual…",
        pcDismiss: "Dismiss", pcHide1h: "Hide for 1 hour", pcResetPos: "Reset position",
        pcBusy: "Still working on your last dictation", anRecording: "Recording", anTranscribing: "Transcribing",
        keyA11y: { "\($0) key" }, keyHeld: "held", pcIdle: { "Hold \($0) to dictate" }, pcReady: { "Ready — hold \($0) to dictate" },
        pcLeft: { "\($0) s left" },
        rpTitle: "Report a problem",
        rpIntro: "This is everything the report contains. Edit or delete any line. It has no dictated text, no audio and no API keys.",
        rpNote: "Nothing is sent from here. “Open GitHub issue” opens your browser with this text filled in; you read it there and press Submit yourself.",
        rpOpen: "Open GitHub issue", rpOpenH: "Open a prefilled issue in your browser",
        upAvailText: "Click “Update available” at the bottom of the sidebar in the Soyla window.",
        upToDate: "You’re up to date", upNoneT: "No releases yet",
        upNoneText: "Soyla has no published release to compare with yet. Try again later.",
        upFailT: "Couldn’t check for updates", upNetText: "Soyla couldn’t reach GitHub. Check your connection and try again.",
        upBadText: "GitHub sent an unexpected answer. Try again later.", upOK: "OK",
        upAvail: { "Soyla \($0) is available" }, upToDateText: { "Soyla \($0) is the latest version." },
        upButton: { "Update to \($0)" }, ucRestart: { "Restart to get \($0)" },
        ucAvail: "Update available", ucFailed: "Update didn’t install", ucRestarting: "Restarting…",
        ucRetry: "Hover for why · click to retry",
        ucTip: "After the restart macOS asks once for your Mac password. Click Always Allow.",
        ucHide: "Hide for now", ucHideA: "Hide the update for now", ucPage: "Open download page",
        ucDownloading: { "Downloading… \($0) %" }, ucA11y: { "Update available. Soyla \($0). \($1)" },
        sfBusy: "Finish your dictation first, then click Update again.",
        sfNotOffered: "This release can’t be installed from here. Download it from the release page.",
        sfNetwork: "The download stopped. Check your internet and try again.",
        sfVerify: "Couldn’t verify this update, so nothing was changed. Download it from the release page.",
        sfUnsigned: "This copy of Soyla can’t update itself. Download the new version from the release page.",
        sfNotWritable: "Soyla can’t replace itself in this folder. Download the new version from the release page.",
        sfInstall: "The update couldn’t be installed. Your current version is unchanged.",
        ceBase: "Base URL", ceBaseC: "{base}/chat/completions · https (http for localhost)", ceAny: "Any OpenAI-compatible server",
        ceEnv: { "Using the key from \($0 ? "an environment variable" : ".env.local (dev)"); it wins over the saved key." },
        kcEmpty: "Not connected", kcSaved: "Saved", kcUsed: "Used for dictation", kcOptional: "Optional",
        kcWorks: "Soyla can transcribe with this key.", kcMore: "More", kcReplaceKey: "Replace key…", kcCheckAgain: "Check again",
        kcUse: "Use for dictation", kcPaste: "Paste key", kcType: "Type it instead", kcSave: "Save", kcField: "Type or paste the key",
        kcPasteH: "Reads the key from the clipboard, saves it on this Mac, then clears the clipboard",
        kcStep2: "Come back here and paste it. Soyla checks it right away.",
        kpEmpty: "The clipboard is empty. Copy the key first, then press Paste key.",
        kpSpaces: "That isn’t a key: the clipboard holds text with spaces. Copy just the key.",
        kcAsking: { "Asking \($0) whether the key works. This takes a second." }, kcA11y: { "\($0) API key" },
        kcRefused: { "\($0) refused this key. It may be incomplete, revoked, or from another account. Copy it again and paste it here." },
        rsRawC: "What the speech model heard, plus your dictionary. Long filler sounds like “mmm” are still removed.",
        rsSkipped: "Pasted as heard (cleanup skipped)",
        rsBadgeH: "Changed after transcription. Struck-through words were removed; highlighted words were added or changed.",
        ecChecking: "Checking…", ecReady: "Ready", ecDlFailed: "The download didn’t finish. Check your connection and retry.",
        ecNeedsDl: "Needs a one-time download (internet)", ecNeedsPerm: "Needs Speech Recognition permission",
        ecNoLocale: "Not available: this Mac has no on-device English model",
        ecNoModel: "Not available: Apple’s on-device English model isn’t installed. macOS 26 includes it",
        ecRestricted: "Not available: Speech Recognition is restricted on this Mac",
        ecSlotsFull: "Not available: other apps are using all of macOS’s speech-model slots", ecOsOld: "Needs macOS 14 or later",
        ecDownload: "Download", ecRetry: "Retry", atNeedsDl: "English model needs a download — open Settings",
        atNeedsPerm: "Speech Recognition permission needed — open Settings", atUnavailable: "On-device engine not available — open Settings",
        ecDownloading: { "Downloading \($0)%" }, atDownloading: { "English model downloading (\($0)%)" },
        spToCloudT: "Switch to Cloud?", spToFreeT: "Switch to On this Mac?",
        spToCloudM: "Adds Uzbek, Russian and mixed speech. Your audio then goes to the provider you chose.",
        spToFreeM: "Soyla has no key to use now. On this Mac is free and works offline, in English only.",
        spToCloudB: "Switch to Cloud", spToFreeB: "Switch to On this Mac", spStay: "Stay on this Mac", spNotNow: "Not now")
}

extension AppDStrings {
    static let uz = AppDStrings(
        dcIntro: "Almashtirishlar: Soyla chap tomondagi so‘zni yozganda, o‘rniga o‘ngdagisini qo‘yadi (ismlar, imlo).",
        dcHeard: "Eshitilgan", dcWrite: "Yoziladi", dcRemove: "Almashtirishni o‘chirish", dcAdd: "Almashtirish qo‘shish",
        dcVocab: "Model to‘g‘ri yozishi kerak bo‘lgan ismlar va atamalar, har biri alohida qatorda.",
        dcLimit: { "Chegaraga yetdi (\($0))." },
        hPlay: "Eshitish", hStop: "To‘xtatish", hRetry: "Qayta yuborish", hPlayH: "Yozuvni eshitish",
        hStopH: "Eshitishni to‘xtatish",
        hRetryH: "Yozuvni qayta yuborib, natijadan nusxa oladi (boshqa model uchun sichqonchaning o‘ng tugmasini bosing)",
        hCopyH: "Matndan nusxa olish", hRetryModel: "Boshqa model bilan qayta yuborish",
        hCleanH: "Tuzatilgan matnni yoki xom matnni ko‘rsatish", hVersionA: "Matn turi",
        stWorking: "Ishlayapti", stDone: "Tayyor", stFailed: "O‘tmadi", stCancelled: "Bekor qilindi", stInterrupted: "To‘xtatildi",
        phFailed: "Hech narsa qo‘yilmadi.", phFailedRetry: "Hech narsa qo‘yilmadi. «Qayta yuborish» yozuvni yana yuboradi.",
        phCancelled: "Yuborishdan oldin bekor qilindi.",
        phPending: "Matnga aylantiryapman…", phEmpty: "(bo‘sh)",
        phInterrupted: { "Yozuv to‘xtatildi (\(AppDStrings.num($0, comma: true)) s)" },
        phInterruptedRetry: { "Yozuv to‘xtatildi (\(AppDStrings.num($0, comma: true)) s): matnga aylantirish uchun «Qayta yuborish»ni bosing" },
        fNoRec: "Yozuv saqlanmagan", fNoRecRetry: "Yozuv saqlanmagan: qayta yuboradigan narsa yo‘q",
        fRetrying: "Qayta yuborilmoqda… natijadan nusxa olinadi", fBusy: "Band: birozdan keyin urinib ko‘ring",
        months: ["yan", "fev", "mar", "apr", "may", "iyn", "iyl", "avg", "sen", "okt", "noy", "dek"],
        spot: [.topLeft: "Yuqori chap", .topCenter: "Yuqori o‘rta", .topRight: "Yuqori o‘ng",
               .bottomLeft: "Pastki chap", .bottomCenter: "Pastki o‘rta", .bottomRight: "Pastki o‘ng"],
        kRightOption: "O‘ng ⌥", kRightCommand: "O‘ng ⌘", kRightControl: "O‘ng ⌃", sSoyla: "Yumshoq", sGlass: "Shisha", sWood: "Yog‘och", sClassic: "Klassik signallar",
        sSystem: "Tizim", sOff: "O‘chiq",
        pcNeedsPerm: "Soyla’ga ruxsatlar kerak", pcTranscribing: "Matnga aylantiryapman…", pcCleaning: "Tuzatyapman…",
        pcPasting: "Qo‘yyapman…", pcPasted: "Qo‘yildi", pcDrag: "Meni kerakli joyga suring", pcStill: "Hali ishlayapman…",
        pcSlow: "Odatdagidan uzoqroq davom etmoqda…", pcDismiss: "Yopish", pcHide1h: "1 soatga yashirish",
        pcResetPos: "Joylashuvni tiklash", pcBusy: "Oxirgi diktovka hali ishlanmoqda",
        anRecording: "Yozilmoqda", anTranscribing: "Matnga aylantirilmoqda",
        keyA11y: { "\($0) tugmasi" }, keyHeld: "bosilgan", pcIdle: { "Gapirish uchun \($0)’ni bosib turing" }, pcReady: { "Tayyor: gapirish uchun \($0)’ni bosib turing" },
        pcLeft: { "\($0) s qoldi" },
        rpTitle: "Muammo haqida xabar berish",
        rpIntro: "Hisobotda faqat shu ma’lumotlar bor. Istalgan qatorni tahrirlang yoki o‘chiring. Unda diktovka matni, ovoz va API key’lar yo‘q.",
        rpNote: "Bu yerdan hech narsa yuborilmaydi. «GitHub issue’ni ochish» brauzeringizni shu matn bilan ochadi; uni o‘sha yerda o‘qib, Submit’ni o‘zingiz bosasiz.",
        rpOpen: "GitHub issue’ni ochish", rpOpenH: "Brauzerda tayyor to‘ldirilgan issue’ni ochish",
        upAvailText: "Soyla oynasida yon panel pastidagi «Yangilanish mavjud»ni bosing.",
        upToDate: "Sizda eng so‘nggi versiya", upNoneT: "Hozircha versiyalar yo‘q",
        upNoneText: "Solishtirish uchun Soyla’ning e’lon qilingan versiyasi hali yo‘q. Keyinroq urinib ko‘ring.",
        upFailT: "Yangilanishlarni tekshirib bo‘lmadi",
        upNetText: "Soyla GitHub’ga ulana olmadi. Internetni tekshirib, qayta urinib ko‘ring.",
        upBadText: "GitHub kutilmagan javob qaytardi. Keyinroq urinib ko‘ring.", upOK: "OK",
        upAvail: { "Soyla \($0) mavjud" }, upToDateText: { "Eng so‘nggi versiya o‘rnatilgan: Soyla \($0)." },
        upButton: { "\($0) versiyaga yangilash" }, ucRestart: { "\($0) olish uchun qayta ishga tushiring" },
        ucAvail: "Yangilanish mavjud", ucFailed: "Yangilanish o‘rnatilmadi", ucRestarting: "Qayta ishga tushmoqda…",
        ucRetry: "Sababi uchun ustiga olib boring · qayta urinish uchun bosing",
        ucTip: "Qayta ishga tushgandan keyin macOS Mac parolingizni bir marta so‘raydi. Always Allow’ni bosing.",
        ucHide: "Hozircha yashirish", ucHideA: "Yangilanishni hozircha yashirish", ucPage: "Yuklab olish sahifasini ochish",
        ucDownloading: { "Yuklab olinmoqda… \($0) %" }, ucA11y: { "Yangilanish mavjud. Soyla \($0). \($1)" },
        sfBusy: "Avval diktovkani tugating, so‘ng yangilashni yana bosing.",
        sfNotOffered: "Bu versiyani shu yerdan o‘rnatib bo‘lmaydi. Uni yuklab olish sahifasidan oling.",
        sfNetwork: "Yuklab olish to‘xtadi. Internetni tekshirib, qayta urinib ko‘ring.",
        sfVerify: "Bu yangilanishni tekshirib bo‘lmadi, shuning uchun hech narsa o‘zgarmadi. Uni yuklab olish sahifasidan oling.",
        sfUnsigned: "Soyla’ning bu nusxasi o‘zini yangilay olmaydi. Yangi versiyani yuklab olish sahifasidan oling.",
        sfNotWritable: "Soyla bu papkada o‘zini almashtira olmaydi. Yangi versiyani yuklab olish sahifasidan oling.",
        sfInstall: "Yangilanishni o‘rnatib bo‘lmadi. Hozirgi versiyangiz o‘zgarmadi.",
        ceBase: "Base URL", ceBaseC: "{base}/chat/completions · https (localhost uchun http)",
        ceAny: "OpenAI bilan mos istalgan server",
        ceEnv: { "\($0 ? "Environment variable" : ".env.local (dev)")’dagi API key ishlatilmoqda; u saqlangan API key’dan ustun turadi." },
        kcEmpty: "Ulanmagan", kcSaved: "Saqlandi", kcUsed: "Diktovka uchun ishlatiladi", kcOptional: "Ixtiyoriy",
        kcWorks: "Soyla shu API key bilan matnga aylantira oladi.", kcMore: "Yana", kcReplaceKey: "API key’ni almashtirish…",
        kcCheckAgain: "Qayta tekshirish", kcUse: "Diktovka uchun ishlatish", kcPaste: "API key’ni qo‘yish",
        kcType: "Qo‘lda kiritish", kcSave: "Saqlash", kcField: "API key’ni yozing yoki qo‘ying",
        kcPasteH: "API key’ni clipboard’dan o‘qiydi, shu Mac’da saqlaydi va clipboard’ni tozalaydi",
        kcStep2: "Shu yerga qaytib, uni qo‘ying. Soyla darhol tekshiradi.",
        kpEmpty: "Clipboard bo‘sh. Avval API key’dan nusxa oling, so‘ng «API key’ni qo‘yish»ni bosing.",
        kpSpaces: "Bu API key emas: clipboard’da bo‘shliqli matn bor. Faqat API key’ni nusxalang.",
        kcAsking: { "API key ishlashi \($0)dan so‘ralmoqda. Bu bir soniya oladi." }, kcA11y: { "\($0) uchun API key" },
        kcRefused: { "\($0) bu API key’ni qabul qilmadi. U to‘liq emas, bekor qilingan yoki boshqa hisobniki bo‘lishi mumkin. Uni qayta nusxalab, shu yerga qo‘ying." },
        rsRawC: "Nutq modeli eshitgani va lug‘atingiz. “mmm” kabi uzun to‘ldiruvchi tovushlar baribir olib tashlanadi.",
        rsSkipped: "Eshitilganicha qo‘yildi (tuzatish o‘tkazib yuborildi)",
        rsBadgeH: "Yozib olingandan keyin o‘zgartirilgan. Ustiga chizilgan so‘zlar olib tashlangan; ajratilgan so‘zlar qo‘shilgan yoki o‘zgargan.",
        ecChecking: "Tekshirilmoqda…", ecReady: "Ishlaydi", ecDlFailed: "Yuklab olish tugamadi. Internetni tekshirib, qayta urinib ko‘ring.",
        ecNeedsDl: "Bir martalik yuklab olish kerak (internet)", ecNeedsPerm: "Speech Recognition ruxsati kerak",
        ecNoLocale: "Mavjud emas: bu Mac’da ingliz tili modeli yo‘q",
        ecNoModel: "Mavjud emas: Apple’ning ingliz tili modeli o‘rnatilmagan. U macOS 26 bilan birga keladi",
        ecRestricted: "Mavjud emas: bu Mac’da Speech Recognition cheklangan",
        ecSlotsFull: "Mavjud emas: boshqa ilovalar macOS’ning barcha nutq modeli o‘rinlarini band qilgan",
        ecOsOld: "macOS 14 yoki yangiroq kerak", ecDownload: "Yuklab olish", ecRetry: "Qayta urinish",
        atNeedsDl: "Ingliz tili modelini yuklab olish kerak: Sozlamalarni oching",
        atNeedsPerm: "Speech Recognition ruxsati kerak: Sozlamalarni oching",
        atUnavailable: "Shu Mac’dagi tanib olish mavjud emas: Sozlamalarni oching",
        ecDownloading: { "Yuklab olinmoqda \($0)%" }, atDownloading: { "Ingliz tili modeli yuklanmoqda (\($0)%)" },
        spToCloudT: "Cloud’ga o‘tilsinmi?", spToFreeT: "«Shu Mac’da»ga o‘tilsinmi?",
        spToCloudM: "O‘zbek, rus va aralash nutq qo‘shiladi. Shundan keyin ovozingiz siz tanlagan xizmatga boradi.",
        spToFreeM: "Soyla’da hozir ishlatadigan API key yo‘q. «Shu Mac’da» bepul va internetsiz ishlaydi, faqat ingliz tilida.",
        spToCloudB: "Cloud’ga o‘tish", spToFreeB: "«Shu Mac’da»ga o‘tish", spStay: "Shu Mac’da qolish", spNotNow: "Hozir emas")

    static let ru = AppDStrings(
        dcIntro: "Замены: когда Soyla пишет слово слева, она вставляет слово справа (имена, написание).",
        dcHeard: "Услышано", dcWrite: "Писать как", dcRemove: "Удалить замену", dcAdd: "Добавить замену",
        dcVocab: "Имена и термины, которые модель должна писать правильно, по одному в строке.",
        dcLimit: { "Лимит достигнут (\($0))." },
        hPlay: "Слушать", hStop: "Стоп", hRetry: "Повторить", hPlayH: "Прослушать запись",
        hStopH: "Остановить воспроизведение",
        hRetryH: "Отправить запись ещё раз и скопировать результат (правый клик: другая модель)",
        hCopyH: "Скопировать текст", hRetryModel: "Повторить с другой моделью",
        hCleanH: "Показать исправленный текст или исходную расшифровку", hVersionA: "Версия текста",
        stWorking: "В работе", stDone: "Готово", stFailed: "Не удалось", stCancelled: "Отменено", stInterrupted: "Прервано",
        phFailed: "Ничего не вставлено.", phFailedRetry: "Ничего не вставлено. «Повторить» отправит запись ещё раз.",
        phCancelled: "Отменено до отправки.",
        phPending: "Расшифровываю…", phEmpty: "(пусто)",
        phInterrupted: { "Запись прервана (\(AppDStrings.num($0, comma: true)) с)" },
        phInterruptedRetry: { "Запись прервана (\(AppDStrings.num($0, comma: true)) с): нажмите «Повторить», чтобы расшифровать" },
        fNoRec: "Запись не сохранена", fNoRecRetry: "Запись не сохранена: повторять нечего",
        fRetrying: "Повторяю… результат будет скопирован", fBusy: "Занято: попробуйте чуть позже",
        months: ["янв.", "февр.", "мар.", "апр.", "мая", "июн.", "июл.", "авг.", "сент.", "окт.", "нояб.", "дек."],
        spot: [.topLeft: "Сверху слева", .topCenter: "Сверху по центру", .topRight: "Сверху справа",
               .bottomLeft: "Снизу слева", .bottomCenter: "Снизу по центру", .bottomRight: "Снизу справа"],
        kRightOption: "Правый ⌥", kRightCommand: "Правый ⌘", kRightControl: "Правый ⌃", sSoyla: "Мягкие", sGlass: "Стекло", sWood: "Дерево", sClassic: "Классические сигналы",
        sSystem: "Системные",
        sOff: "Выключены",
        pcNeedsPerm: "Soyla нужны разрешения", pcTranscribing: "Расшифровываю…", pcCleaning: "Исправляю…", pcPasting: "Вставляю…",
        pcPasted: "Вставлено", pcDrag: "Перетащите меня, куда нужно", pcStill: "Ещё работаю…", pcSlow: "Дольше обычного…",
        pcDismiss: "Закрыть", pcHide1h: "Скрыть на 1 час", pcResetPos: "Сбросить положение",
        pcBusy: "Предыдущая диктовка ещё в работе", anRecording: "Идёт запись", anTranscribing: "Расшифровка",
        keyA11y: { "клавиша \($0)" }, keyHeld: "зажата", pcIdle: { "Зажмите \($0), чтобы диктовать" }, pcReady: { "Готово: зажмите \($0), чтобы диктовать" },
        pcLeft: { "осталось \($0) с" },
        rpTitle: "Сообщить о проблеме",
        rpIntro: "Это всё, что войдёт в отчёт. Любую строку можно изменить или удалить. В нём нет надиктованного текста, звука и API-ключей.",
        rpNote: "Отсюда ничего не отправляется. «Открыть GitHub issue» откроет браузер с этим текстом; вы прочитаете его там и сами нажмёте Submit.",
        rpOpen: "Открыть GitHub issue", rpOpenH: "Открыть в браузере заполненный issue",
        upAvailText: "Нажмите «Доступно обновление» внизу боковой панели в окне Soyla.",
        upToDate: "У вас последняя версия", upNoneT: "Релизов пока нет",
        upNoneText: "Пока нет опубликованного релиза для сравнения. Попробуйте позже.",
        upFailT: "Не удалось проверить обновления",
        upNetText: "Soyla не смогла связаться с GitHub. Проверьте интернет и повторите.",
        upBadText: "GitHub прислал неожиданный ответ. Попробуйте позже.", upOK: "OK",
        upAvail: { "Доступна Soyla \($0)" }, upToDateText: { "Установлена последняя версия: Soyla \($0)." },
        upButton: { "Обновить до \($0)" }, ucRestart: { "Перезапустите, чтобы получить \($0)" },
        ucAvail: "Доступно обновление", ucFailed: "Обновление не установилось", ucRestarting: "Перезапуск…",
        ucRetry: "Наведите, чтобы узнать причину · нажмите, чтобы повторить",
        ucTip: "После перезапуска macOS один раз спросит пароль Mac. Нажмите Always Allow.",
        ucHide: "Пока скрыть", ucHideA: "Пока скрыть обновление", ucPage: "Открыть страницу загрузки",
        ucDownloading: { "Загрузка… \($0) %" }, ucA11y: { "Доступно обновление. Soyla \($0). \($1)" },
        sfBusy: "Сначала закончите диктовку, затем снова нажмите обновление.",
        sfNotOffered: "Эту версию нельзя установить отсюда. Скачайте её на странице релиза.",
        sfNetwork: "Загрузка прервалась. Проверьте интернет и повторите.",
        sfVerify: "Не удалось проверить это обновление, поэтому ничего не изменилось. Скачайте его на странице релиза.",
        sfUnsigned: "Эта копия Soyla не может обновить себя. Скачайте новую версию на странице релиза.",
        sfNotWritable: "Soyla не может заменить себя в этой папке. Скачайте новую версию на странице релиза.",
        sfInstall: "Не удалось установить обновление. Текущая версия не изменилась.",
        ceBase: "Base URL", ceBaseC: "{base}/chat/completions · https (для localhost http)",
        ceAny: "Любой OpenAI-совместимый сервер",
        ceEnv: { "Используется ключ из \($0 ? "переменной окружения" : ".env.local (dev)"); он главнее сохранённого ключа." },
        kcEmpty: "Не подключено", kcSaved: "Сохранён", kcUsed: "Используется для диктовки", kcOptional: "Необязательно",
        kcWorks: "Soyla может распознавать речь с этим ключом.", kcMore: "Ещё", kcReplaceKey: "Заменить ключ…",
        kcCheckAgain: "Проверить снова", kcUse: "Использовать для диктовки", kcPaste: "Вставить ключ",
        kcType: "Ввести вручную", kcSave: "Сохранить", kcField: "Введите или вставьте ключ",
        kcPasteH: "Читает ключ из буфера обмена, сохраняет на этом Mac и очищает буфер",
        kcStep2: "Вернитесь сюда и вставьте его. Soyla сразу проверит.",
        kpEmpty: "Буфер обмена пуст. Сначала скопируйте ключ, затем нажмите «Вставить ключ».",
        kpSpaces: "Это не ключ: в буфере обмена текст с пробелами. Скопируйте только ключ.",
        kcAsking: { "Спрашиваем \($0), работает ли ключ. Это займёт секунду." }, kcA11y: { "API-ключ \($0)" },
        kcRefused: { "\($0) отклонил этот ключ. Он может быть неполным, отозванным или от другого аккаунта. Скопируйте его снова и вставьте сюда." },
        rsRawC: "То, что услышала модель распознавания, плюс ваш словарь. Долгие звуки-паразиты вроде «ммм» всё равно убираются.",
        rsSkipped: "Вставлено как услышано (коррекция пропущена)",
        rsBadgeH: "Изменено после распознавания. Зачёркнутые слова убраны; выделенные добавлены или изменены.",
        ecChecking: "Проверяем…", ecReady: "Работает", ecDlFailed: "Загрузка не завершилась. Проверьте интернет и повторите.",
        ecNeedsDl: "Нужна разовая загрузка (интернет)", ecNeedsPerm: "Нужно разрешение Speech Recognition",
        ecNoLocale: "Недоступно: на этом Mac нет английской модели",
        ecNoModel: "Недоступно: английская модель Apple не установлена. Она входит в macOS 26",
        ecRestricted: "Недоступно: на этом Mac ограничен Speech Recognition",
        ecSlotsFull: "Недоступно: другие приложения заняли все слоты речевых моделей macOS",
        ecOsOld: "Нужна macOS 14 или новее", ecDownload: "Скачать", ecRetry: "Повторить",
        atNeedsDl: "Нужно скачать английскую модель: откройте Настройки",
        atNeedsPerm: "Нужно разрешение Speech Recognition: откройте Настройки",
        atUnavailable: "Распознавание на этом Mac недоступно: откройте Настройки",
        ecDownloading: { "Загрузка \($0)%" }, atDownloading: { "Английская модель загружается (\($0)%)" },
        spToCloudT: "Перейти на облако?", spToFreeT: "Перейти на «На этом Mac»?",
        spToCloudM: "Добавит узбекский, русский и смешанную речь. После этого звук пойдёт в выбранный вами сервис.",
        spToFreeM: "У Soyla сейчас нет ключа. «На этом Mac» бесплатно и работает без интернета, только на английском.",
        spToCloudB: "Перейти на облако", spToFreeB: "Перейти на «На этом Mac»", spStay: "Остаться на этом Mac", spNotNow: "Не сейчас")
}
