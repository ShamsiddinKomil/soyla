import Foundation

// APP-1: the main app's words in English, Uzbek (Latin) and Russian, ported verbatim from the approved prototype's
// `T` table (design prototype v2), the same pattern as `SetupStrings`. Commit (a) holds the shell,
// Home and menu-bar strings; later commits extend it. `{key}` is replaced by the hotkey's label.
// Rules: Uzbek keeps tech terms in English (Cloud, API key, Mac, macOS pane names); decimal comma in Uzbek and
// Russian; Soyla is feminine in Russian (готова).
// Lines marked "APP-1 addition" are not in the prototype (Accessibility off, a hosted engine with no key, the Keychain
// notice, a failed last dictation, Secure Input); their Uzbek and Russian wait for the owner's review.

struct AppStrings: Sendable {
    // Shell
    let navHome, navHistory: String
    let page: [SettingsPage: String]
    let version: @Sendable (String) -> String
    let setupA, uiAria: String
    let n: [SpokenLanguage: String]

    // Home title
    let ready, holdSub: String
    let more: @Sendable (CloudCombo) -> String
    let moreSub, micOff, micOffSub: String
    let axOff, axOffSub, keyTitle, needsKeySub: String          // APP-1 addition

    // Hero
    let tryPh, handsFree, cancel, tShort, listening, writing, secs, onMacLow: String
    let via: @Sendable (String) -> String

    // Your languages
    let langs, change, onMac: String
    let cloudVia: @Sendable (String) -> String
    let cloudOnly, readyW, needsKey, connect, offW, useCloud: String

    // Permissions group (mic off)
    let perms, pMic, pMicC, pMicB, pOff, pAx, pAxC: String

    // Last dictation
    let last, allHist, copy, copied: String
    let today: @Sendable (Int, String) -> String
    let todayEmpty, metaToday: String
    let failedRun, keychainWaiting, keychainDenied, keychainPending, keyFileUnreadable: String    // APP-1 addition (D4: the one-time move)

    /// The Home / Languages warning while the launch key read is not `.ready`.
    func keyNotice(_ a: Secrets.KeychainAccess) -> String {
        switch a {
        case .denied: return keychainDenied
        case .pending: return keychainPending
        case .unreadable: return keyFileUnreadable
        case .waiting, .ready: return keychainWaiting
        }
    }

    // Menu bar
    let mHold, mMicFirst, mWorks: String
    let mConnect: @Sendable (CloudCombo) -> String
    let mMic, mOpen, mPaste, mCopyLast, mSettings, mSetup, mReport, mQuit: String
    let mAxFirst, mAx, mKeyFirst, mSecure: String              // APP-1 addition
    let mHotkeyOff: String                                      // APP-1 (b) addition

    // Languages page (b)
    let eTitle, eSub: String
    let eInfo: [String]
    let eCloud, eCloudC, eMac, eMacC: String
    let key, service, gC, oC, notAdded, replace, model, modelC, macModel, macModelC, connected: String
    let keyRemove, keyRejected, keyUnchecked, keyChecking: String   // APP-1 (b) addition

    // Main menu (b, APP-1 addition: not in the prototype)
    let mmAbout, mmUpdates, mmHide, mmHideOthers, mmEdit, mmUndo, mmRedo, mmCut, mmCopy, mmPaste, mmSelectAll: String
    let mmView, mmSettingsTab, mmWindow, mmSoylaWindow, mmMinimize, mmClose, mmHelp: String

    // (c) Pill cards (APP-1 addition)
    let pillOpen: @Sendable (String) -> String
    let pillRetry: String

    // (c) Privacy & data (prototype `privacy`)
    let pvTitle, pvSub: String
    let pvInfo: [String]
    let pvWhere, stays, rMac, recs, keep, keepC, keepI: String
    let retNever, ret14, retForever, ret7, retAfterRun: String          // ret7, retAfterRun: APP-1 addition (older values)
    let folder, finder, mic, warm, warmC, warmI, warmOff, warm30, warmOn, builtin: String
    let builtinNow: @Sendable (String) -> String
    let startup, login, loginApproval: String
    let loginFailed: @Sendable (String) -> String                         // APP-1 addition

    // (c) Other pages (APP-1 addition: the prototype draws only Home, Languages and Privacy)
    let permSub, pSpeech, pSpeechC: String
    let dicSub, dLang, dLangC, dLangI, langAuto, dClean, dCleanC, dCleanI, cleanOff, cleanLight, dDict: String
    let hkSub, hkHold, hkHoldI, hkWhere, hkPaste, hkPasteC: String
    let hkMore, hkHeld, hkWorks, hkDoes, hkGHold, hkGHoldC, hkGTwice, hkGTwiceC: String   // HOTKEY-1
    let hkTest: @Sendable (String) -> String
    let plSub, plPos, plPosI, plPlace, plReset, plOwn, plHiddenC, plShow, plWhile: String
    let plHidden: @Sendable (String) -> String
    let plLive, plLiveC, plLiveI, plDetails, plDetailsC, plTouch, plTouchC, plTouchI: String
    let touchRelaxed, touchNormal, touchStrict, plSounds: String
    let abSub, abVersion, abUpdates, abUpdatesI, abDaily, abCheck, abAuto, abAutoC, abAutoI, abSource, abGitHub: String
    let abSetup, abSetupC, abOpen, devSub: String
    let hiSub, hiSearch, hiClean, hiRaw, hiEmpty, hiNoMatch, hiKeys: String
    let hiCount: @Sendable (Int, Int) -> String

    // v3: the inline Connect panel (prototype-v3 `cx*`)
    let cxFail, cxCancel, cxBoth: String
    let cxPriv: @Sendable (String) -> String

    // Audit 2026-10-19 additions: a row waiting for permissions (V-01), the pill's key card (V-10). Uzbek and Russian
    // wait for the owner's review.
    let waitPerms, pillKeyHint: String
    let pFnSet, attention: String                                   // V-24, V-28
    let pcNoSound: String                                           // flows F-05
    let keyRemoveQ, keyRemoveCloud, eWhere, modelCFull, plSoundsC: String   // flows F-09, F-25, F-24, F-23
    let plVolume, plPlay: String                                    // main's volume + preview on the Dictation page
    let keyRemoveStops: @Sendable (CloudCombo) -> String
    let dRepl, dReplC, dAdd, dSpell, dSpellC, devMode, devModeC, devModeI: String   // V-15, V-16
    let pillKey: @Sendable (CloudCombo) -> String
    /// R-11 (D24): what VoiceOver says for an ⓘ next to `x` ("About Languages", not "Languages").
    let about: @Sendable (String) -> String

    /// (d) The remaining words: dictionary, History cards, pill, Report a Problem, updates, custom endpoint, engine status.
    let d: AppDStrings

    static func `for`(_ l: UILanguage) -> AppStrings {
        switch l { case .en: return en; case .uz: return uz; case .ru: return ru }
    }

    /// Home's (and the menu header's) title line.
    func title(_ t: HomeState.Title) -> String {
        switch t {
        case .micOff: return micOff
        case .axOff: return axOff
        case .needsKey: return keyTitle
        case .oneMore(let c): return more(c)
        case .ready: return ready
        }
    }

    /// The line under the title (`{key}` still in it, so the view can draw the key inline).
    func sub(_ t: HomeState.Title) -> String {
        switch t {
        case .micOff: return micOffSub
        case .axOff: return axOffSub
        case .needsKey: return needsKeySub
        case .oneMore: return moreSub
        case .ready: return holdSub
        }
    }

    /// F-06: the line under Home's title. "English works now." only while English is chosen and really works.
    func sub(_ h: HomeState) -> String {
        if case .oneMore = h.title, !h.englishWorksNow { return needsKeySub }
        return sub(h.title)
    }

    /// `{key}` → the hotkey's short label ("fn").
    static func fill(_ s: String, key: String) -> String { s.replacingOccurrences(of: "{key}", with: key) }

    /// Milliseconds as "0.5" in English, "0,5" in Uzbek and Russian.
    static func seconds(_ ms: Double, language: UILanguage) -> String { SetupFlow.seconds(ms / 1000, language: language) }

    /// The words in the language the app is set to now (for views that carry no strings of their own).
    @MainActor static var current: AppStrings { .for(SettingsStore.shared.current.uiLanguage) }

    static func cap1(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The data folder as the Privacy page shows it: its last two parts ("Application Support › Soyla"); the full
    /// path is the tooltip (no home-folder name on screen).
    static func folderPath(_ url: URL) -> String { url.pathComponents.suffix(2).joined(separator: " › ") }
}

extension AppStrings {
    static let en: AppStrings = {
        let subj: [CloudCombo: String] = [.uz: "Uzbek", .ru: "Russian", .uzru: "Uzbek and Russian"]
        return AppStrings(
            navHome: "Home", navHistory: "History",
            page: [.apiKeys: "Languages", .permissions: "Permissions", .dictation: "Dictation", .hotkey: "Hotkey", .pill: "Pill",
                   .privacy: "Privacy & data", .about: "About", .developer: "Developer"],
            version: { "Version \($0)" }, setupA: "Setup Assistant…", uiAria: "Interface language",
            n: [.en: "English", .uz: "Uzbek", .ru: "Russian"],
            ready: "Soyla is ready", holdSub: "Hold {key} in any app.",
            more: { "One more step for \(subj[$0] ?? "")" }, moreSub: "English works now.",
            micOff: "Soyla can’t hear you yet", micOffSub: "Allow the microphone, then hold {key}.",
            axOff: "Soyla can’t type for you yet", axOffSub: "Allow Accessibility, then hold {key}.",
            keyTitle: "Soyla needs an API key", needsKeySub: "Add an API key, then hold {key}.",
            tryPh: "Click here, hold fn and speak", handsFree: "Hands-free", cancel: "Cancel", tShort: "Hold a little longer.",
            listening: "Listening…", writing: "Writing…", secs: "s", onMacLow: "on this Mac", via: { "via \($0)" },
            langs: "Your languages", change: "Change…", onMac: "On this Mac", cloudVia: { "Cloud · \($0)" }, cloudOnly: "Cloud",
            readyW: "Ready", needsKey: "Needs an API key", connect: "Connect…", offW: "Off", useCloud: "Use Cloud",
            perms: "Permissions", pMic: "Hear your voice", pMicC: "Microphone", pMicB: "Allow…", pOff: "Not allowed",
            pAx: "Type where your cursor is", pAxC: "Accessibility",
            last: "Last dictation", allHist: "All in History", copy: "Copy", copied: "Copied",
            today: { "Today: \($0) · usually \($1) s" },
            todayEmpty: "Nothing yet. Your first sentence will appear here.", metaToday: "Today",
            failedRun: "This one didn’t go through. Retry it from History.",
            keychainWaiting: "Soyla now keeps your API key in a private file on this Mac. macOS is asking for your Mac password one last time so Soyla can move the key out of the Keychain. Type it and click Allow.",
            keychainDenied: "macOS didn’t let Soyla move your saved API key out of the Keychain. Quit and reopen Soyla, then type your Mac password and click Allow.",
            keychainPending: "Soyla couldn’t open the Keychain to move your saved API key. Quit and reopen Soyla to try again.",
            keyFileUnreadable: "Soyla can’t read its saved keys file. Connect your API key again.",
            mHold: "Hold {key} in any app", mMicFirst: "Allow the microphone first.", mWorks: "English works now.",
            mConnect: { "Connect \(subj[$0] ?? "")…" }, mMic: "Allow the Microphone…", mOpen: "Open Soyla",
            mPaste: "Paste Last Dictation", mCopyLast: "Copy Last Dictation", mSettings: "Settings…", mSetup: "Setup Assistant…",
            mReport: "Report a Problem…", mQuit: "Quit Soyla",
            mAxFirst: "Allow Accessibility first.", mAx: "Allow Accessibility…", mKeyFirst: "Add an API key first.",
            mSecure: "Secure Input is on: paste disabled",
            mHotkeyOff: "Hotkey not active: check permissions",
            eTitle: "Languages", eSub: "Where each language turns into text.",
            eInfo: ["English can run on this Mac with Apple’s speech model: free, offline, nothing leaves the Mac.",
                    "Uzbek, Russian and mixed speech use the Cloud service you pick, with your own API key. Audio goes from this Mac straight to that service. There is no Soyla server.",
                    "With Cloud on, English goes through the same service."],
            eCloud: "Cloud", eCloudC: "All languages, mixed sentences", eMac: "On this Mac", eMacC: "English only · free, offline",
            key: "API key", service: "Service", gC: "Free to start", oC: "Pay as you go", notAdded: "Not added", replace: "Replace…",
            model: "Model", modelC: "Flash-Lite: faster, less exact", macModel: "English speech model", macModelC: "Apple · offline",
            connected: "Connected",
            keyRemove: "Remove key", keyRejected: "Key rejected", keyUnchecked: "Not checked", keyChecking: "Checking…",
            mmAbout: "About Soyla", mmUpdates: "Check for Updates…", mmHide: "Hide Soyla", mmHideOthers: "Hide Others",
            mmEdit: "Edit", mmUndo: "Undo", mmRedo: "Redo", mmCut: "Cut", mmCopy: "Copy", mmPaste: "Paste", mmSelectAll: "Select All",
            mmView: "View", mmSettingsTab: "Settings", mmWindow: "Window", mmSoylaWindow: "Soyla Window", mmMinimize: "Minimize",
            mmClose: "Close", mmHelp: "Help",
            pillOpen: { "Open \($0)" }, pillRetry: "Retry",
            pvTitle: "Privacy & data", pvSub: "What stays on this Mac and what leaves it.",
            pvInfo: ["Soyla has no account and no server. Text and recordings are saved only on this Mac.",
                     "Cloud services receive only the audio of a dictation, with your API key."],
            pvWhere: "Where your voice goes", stays: "Stays on this Mac", rMac: "This Mac", recs: "Recordings",
            keep: "Keep recordings", keepC: "Text stays in History",
            keepI: "Recordings let you retry a dictation. A failed dictation keeps its recording until you retry or remove it.",
            retNever: "Don’t keep", ret14: "14 days", retForever: "Forever", ret7: "7 days", retAfterRun: "Until it’s pasted",
            folder: "Data folder", finder: "Show in Finder", mic: "Microphone", warm: "Keep the microphone on", warmC: "Faster start",
            warmI: "The mic light stays on while it’s open. Off: the mic opens only while you hold the key, about 0.3 s after you press. It always closes when the screen locks or the Mac sleeps.",
            warmOff: "Off between dictations", warm30: "For 30 s after a dictation", warmOn: "Always",
            builtin: "Prefer the built-in microphone", builtinNow: { "Now: \($0)" },
            startup: "Startup", login: "Open Soyla at login", loginApproval: "Approve it in System Settings → General → Login Items.",
            loginFailed: { "Couldn’t change the login item: \($0)" },
            permSub: "What macOS lets Soyla do.", pSpeech: "Recognize English on this Mac", pSpeechC: "Speech Recognition",
            dicSub: "How your words are written.", dLang: "Mainly speak", dLangC: "Auto handles mixed speech",
            dLangI: "Auto-detect handles mixed sentences. Pick one language only if Soyla keeps guessing wrong.", langAuto: "Auto-detect",
            dClean: "Correction pass", dCleanC: "Removes fillers and repeats",
            dCleanI: "Light removes repeats and fillers and applies self-corrections (about 1.8 s extra). Raw pastes the text as heard. The original is always kept in History.",
            cleanOff: "Raw", cleanLight: "Light", dDict: "Personal dictionary",
            hkSub: "The key you hold to talk.", hkHold: "Hold to talk",
            hkHoldI: "For fn: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, and quit other dictation apps.",
            hkWhere: "Where the text goes", hkPaste: "Paste into the app", hkPasteC: "Off: copy only", hkMore: "More keys", hkHeld: "Now let go", hkWorks: "Works", hkDoes: "What it does",
            hkGHold: "Hold", hkGHoldC: "Talk while it’s held", hkGTwice: "Press twice", hkGTwiceC: "Hands-free; press again to stop",
            hkTest: { "Hold \($0) to test it" },
            plSub: "Where it appears, what it shows.", plPos: "Position",
            plPosI: "Click a spot on the screen map. Or put the pill exactly where you want it: click Place on screen, then drag it.",
            plPlace: "Place on screen", plReset: "Reset", plOwn: "Your own spot", plHiddenC: "Errors still show", plShow: "Show again",
            plWhile: "While you dictate", plHidden: { "Hidden until \($0)" },
            plLive: "Live text", plLiveC: "Preview while you speak",
            plLiveI: "Preview only: the pasted text still comes from the model. Needs a Google AI Studio key. May lag or stop on mixed speech.",
            plDetails: "Transcript and timing", plDetailsC: "After each dictation",
            plTouch: "Ignore accidental touches", plTouchC: "Drops taps and silence",
            plTouchI: "Taps and silent holds are dropped before anything is sent: no request, no paste.",
            touchRelaxed: "Relaxed", touchNormal: "Normal", touchStrict: "Strict", plSounds: "Sounds",
            abSub: "Version and updates.", abVersion: "Version", abUpdates: "Updates",
            abUpdatesI: "Checking only asks GitHub for the latest version number; nothing else is sent. An update is installed only if it is signed like the Soyla you have.",
            abDaily: "Check daily", abCheck: "Check now", abAuto: "Install automatically", abAutoC: "Restarts when idle",
            abAutoI: "Soyla installs a new version when you’re not dictating and restarts by itself. macOS then asks once for your Mac password.",
            abSource: "Source code", abGitHub: "Soyla on GitHub", abSetup: "Setup Assistant", abSetupC: "Run setup again", abOpen: "Open…",
            devSub: "Lab controls and timings.",
            hiSub: "Every dictation, newest first.", hiSearch: "Search", hiClean: "Cleaned", hiRaw: "Raw",
            hiEmpty: "Hold {key} in any app. Your words appear here.", hiNoMatch: "No matches.", hiKeys: "Paste last ⌃⌘V · Copy last ⌃⌘C",
            hiCount: { "\($0) of \($1)" },
            cxFail: "That key didn’t work. Check it and try again.", cxCancel: "Cancel",
            cxBoth: "One key covers Uzbek and Russian.", cxPriv: { "Audio goes straight to \($0)." },
            waitPerms: "Waiting for permissions", pillKeyHint: "English works without one.", pFnSet: "Set", attention: "Needs attention", pcNoSound: "No sound from the mic",
            keyRemoveQ: "Remove the API key?", keyRemoveCloud: "Dictation through Cloud stops until you add a key.",
            eWhere: "Where it runs", modelCFull: "More exact; Lite is faster", plSoundsC: "Start and stop", plVolume: "Sound volume", plPlay: "Play",
            keyRemoveStops: { "\(subj[$0] ?? "") will stop working." },
            dRepl: "Replacements", dReplC: "Heard → written", dAdd: "Add…", dSpell: "Spelling", dSpellC: "Names, one per line",
            devMode: "Developer mode", devModeC: "Timings in History",
            devModeI: "Shows timings and run tags in History, and the lab controls below. Nothing here is needed for everyday use.",
            pillKey: { "\(subj[$0] ?? "") \($0 == .uzru ? "need" : "needs") an API key" }, about: { "About \($0)" }, d: .en)
    }()

    static let uz: AppStrings = {
        let subj: [CloudCombo: String] = [.uz: "o‘zbek tili", .ru: "rus tili", .uzru: "o‘zbek va rus tillari"]
        return AppStrings(
            navHome: "Bosh sahifa", navHistory: "Tarix",
            page: [.apiKeys: "Tillar", .permissions: "Ruxsatlar", .dictation: "Diktovka", .hotkey: "Tezkor tugma", .pill: "Indikator",
                   .privacy: "Maxfiylik va ma’lumotlar", .about: "Soyla haqida", .developer: "Dasturchi"],
            version: { "Versiya \($0)" }, setupA: "Sozlash yordamchisi…", uiAria: "Interfeys tili",
            n: [.en: "Ingliz tili", .uz: "O‘zbek tili", .ru: "Rus tili"],
            ready: "Soyla tayyor", holdSub: "Istalgan ilovada {key}’ni bosib turing.",
            more: { "\(AppStrings.cap1(subj[$0] ?? "")) uchun yana bir qadam" }, moreSub: "Ingliz tili hozir ishlaydi.",
            micOff: "Soyla hali sizni eshitmayapti", micOffSub: "Mikrofonga ruxsat bering, so‘ng {key}’ni bosib turing.",
            axOff: "Soyla hali siz uchun yoza olmaydi", axOffSub: "Accessibility’ga ruxsat bering, so‘ng {key}’ni bosib turing.",
            keyTitle: "Soyla’ga API\u{00A0}key kerak", needsKeySub: "API key qo‘shing, so‘ng {key}’ni bosib turing.",
            tryPh: "Shu yerni bosing, fn’ni bosib turib gapiring", handsFree: "Ushlab turmasdan", cancel: "Bekor qilish",
            tShort: "Biroz uzoqroq bosib turing.",
            listening: "Tinglayapman…", writing: "Yozyapman…", secs: "s", onMacLow: "shu Mac’da", via: { "\($0) orqali" },
            langs: "Tillaringiz", change: "O‘zgartirish…", onMac: "Shu Mac’da", cloudVia: { "Cloud · \($0)" }, cloudOnly: "Cloud",
            readyW: "Ishlaydi", needsKey: "API key kerak", connect: "Ulash…", offW: "O‘chiq", useCloud: "Cloud’ni yoqish",
            perms: "Ruxsatlar", pMic: "Ovozingizni eshitish", pMicC: "Microphone", pMicB: "Ruxsat berish…", pOff: "Ruxsat yo‘q",
            pAx: "Kursor turgan joyga yozish", pAxC: "Accessibility",
            last: "Oxirgi diktovka", allHist: "Hammasi Tarixda", copy: "Nusxa olish", copied: "Nusxa olindi",
            today: { "Bugun: \($0) ta · odatda \($1) s" },
            todayEmpty: "Hozircha hech narsa yo‘q. Birinchi gapingiz shu yerda chiqadi.", metaToday: "Bugun",
            failedRun: "Bu diktovka o‘tmadi. Uni Tarixdan qayta yuboring.",
            keychainWaiting: "Soyla endi API key’ingizni shu Mac’dagi shaxsiy faylda saqlaydi. API key’ni Keychain’dan ko‘chirish uchun macOS oxirgi marta Mac parolingizni so‘rayapti. Parolni kiriting va Allow’ni bosing.",
            keychainDenied: "macOS Soyla’ga saqlangan API key’ni Keychain’dan ko‘chirishga ruxsat bermadi. Soyla’dan chiqib, uni qayta oching, so‘ng Mac parolingizni kiriting va Allow’ni bosing.",
            keychainPending: "Soyla saqlangan API key’ni ko‘chirish uchun Keychain’ni ocha olmadi. Qayta urinish uchun Soyla’dan chiqib, uni qayta oching.",
            keyFileUnreadable: "Soyla saqlangan API key’lar faylini o‘qiy olmayapti. API key’ni qayta ulang.",
            mHold: "Istalgan ilovada {key}’ni bosib turing", mMicFirst: "Avval mikrofonga ruxsat bering.", mWorks: "Ingliz tili hozir ishlaydi.",
            mConnect: { "\(AppStrings.cap1(subj[$0] ?? "")) uchun API key ulash…" }, mMic: "Mikrofonga ruxsat berish…",
            mOpen: "Soyla’ni ochish", mPaste: "Oxirgi diktovkani qo‘yish", mCopyLast: "Oxirgi diktovkadan nusxa olish",
            mSettings: "Sozlamalar…", mSetup: "Sozlash yordamchisi…", mReport: "Muammo haqida xabar berish…", mQuit: "Soyla’dan chiqish",
            mAxFirst: "Avval Accessibility’ga ruxsat bering.", mAx: "Accessibility’ga ruxsat berish…", mKeyFirst: "Avval API key qo‘shing.",
            mSecure: "Secure Input yoqilgan: qo‘yish o‘chiq",
            mHotkeyOff: "Tugma ishlamayapti: ruxsatlarni tekshiring",
            eTitle: "Tillar", eSub: "Har bir til qayerda matnga aylanadi.",
            eInfo: ["Ingliz tili shu Mac’da Apple’ning nutq modeli bilan ishlay oladi: bepul, internetsiz, hech narsa Mac’dan chiqmaydi.",
                    "O‘zbek, rus va aralash nutq siz tanlagan Cloud xizmatida o‘z API key’ingiz bilan ishlaydi. Ovoz shu Mac’dan to‘g‘ridan-to‘g‘ri o‘sha xizmatga boradi. Soyla serveri yo‘q.",
                    "Cloud yoqilganda ingliz tili ham o‘sha xizmat orqali ishlaydi."],
            eCloud: "Cloud", eCloudC: "Barcha tillar, aralash gaplar", eMac: "Shu Mac’da",
            eMacC: "Faqat ingliz tili · bepul, internetsiz",
            key: "API key", service: "Xizmat", gC: "Boshlash bepul", oC: "Ishlatganingizga yarasha to‘lov", notAdded: "Qo‘shilmagan", replace: "Almashtirish…",
            model: "Model", modelC: "Flash-Lite: tezroq, aniqligi pastroq", macModel: "Ingliz tili nutq modeli", macModelC: "Apple · internetsiz",
            connected: "Ulandi",
            keyRemove: "API key’ni o‘chirish", keyRejected: "API key qabul qilinmadi", keyUnchecked: "Tekshirilmagan", keyChecking: "Tekshirilmoqda…",
            mmAbout: "Soyla haqida", mmUpdates: "Yangilanishlarni tekshirish…", mmHide: "Soyla’ni yashirish", mmHideOthers: "Boshqalarni yashirish",
            mmEdit: "Tahrirlash", mmUndo: "Ortga qaytarish", mmRedo: "Qayta bajarish", mmCut: "Kesish", mmCopy: "Nusxa olish", mmPaste: "Qo‘yish",
            mmSelectAll: "Hammasini tanlash", mmView: "Ko‘rinish", mmSettingsTab: "Sozlamalar", mmWindow: "Oyna", mmSoylaWindow: "Soyla oynasi",
            mmMinimize: "Kichraytirish", mmClose: "Yopish", mmHelp: "Yordam",
            pillOpen: { "\($0)’ni ochish" }, pillRetry: "Qayta yuborish",
            pvTitle: "Maxfiylik va ma’lumotlar", pvSub: "Nima shu Mac’da qoladi, nima chiqib ketadi.",
            pvInfo: ["Soyla’da hisob ham, server ham yo‘q. Matn va yozuvlar faqat shu Mac’da saqlanadi.",
                     "Cloud xizmatlari faqat diktovka ovozini, API key’ingiz bilan oladi."],
            pvWhere: "Ovozingiz qayerga boradi", stays: "Shu Mac’da qoladi", rMac: "Shu Mac", recs: "Yozuvlar",
            keep: "Yozuvlarni saqlash", keepC: "Matn Tarixda qoladi",
            keepI: "Yozuv diktovkani qayta yuborishga imkon beradi. Muvaffaqiyatsiz diktovka yozuvi qayta yuborguningizcha yoki o‘chirguningizcha saqlanadi.",
            retNever: "Saqlamaslik", ret14: "14 kun", retForever: "Doim", ret7: "7 kun", retAfterRun: "Qo‘yilguncha",
            folder: "Ma’lumotlar papkasi", finder: "Finder’da ko‘rsatish", mic: "Mikrofon", warm: "Mikrofonni yoqiq qoldirish",
            warmC: "Tezroq boshlanadi",
            warmI: "Mikrofon ochiq turganda uning chirog‘i yonib turadi. O‘chiq: mikrofon faqat tugmani bosib turganingizda, bosgandan taxminan 0,3 s keyin ochiladi. Ekran qulflanganda yoki Mac uxlaganda doim yopiladi.",
            warmOff: "Diktovkalar orasida o‘chiq", warm30: "Diktovkadan keyin 30 s", warmOn: "Doim",
            builtin: "Ichki mikrofonni afzal ko‘rish", builtinNow: { "Hozir: \($0)" },
            startup: "Ishga tushirish", login: "Tizimga kirganda Soyla’ni ochish",
            loginApproval: "System Settings → General → Login Items’da tasdiqlang.",
            loginFailed: { "Ishga tushirish sozlamasini o‘zgartirib bo‘lmadi: \($0)" },
            permSub: "macOS Soyla’ga nimalarga ruxsat beradi.", pSpeech: "Ingliz tilini shu Mac’da tanish", pSpeechC: "Speech Recognition",
            dicSub: "So‘zlaringiz qanday yoziladi.", dLang: "Asosan qaysi tilda", dLangC: "Avto aralash nutqni tushunadi",
            dLangI: "Avtoaniqlash aralash gaplarni tushunadi. Soyla tez-tez adashsa, bitta tilni tanlang.", langAuto: "Avtoaniqlash",
            dClean: "Tuzatish", dCleanC: "Ortiqcha so‘zlarni olib tashlaydi",
            dCleanI: "Yengil: takror va ortiqcha so‘zlarni olib tashlaydi, o‘z-o‘zini tuzatishlarni qo‘llaydi (taxminan 1,8 s qo‘shimcha). Asl matn: matn eshitilganicha qo‘yiladi. Asl matn doim Tarixda saqlanadi.",
            cleanOff: "Asl matn", cleanLight: "Yengil", dDict: "Shaxsiy lug‘at",
            hkSub: "Gapirish uchun bosib turiladigan tugma.", hkHold: "Bosib turib gapirish",
            hkHoldI: "fn uchun: System Settings → Keyboard → “Press 🌐 key to” → Do Nothing’ni tanlang va boshqa diktovka ilovalarini yoping.",
            hkWhere: "Matn qayerga boradi", hkPaste: "Ilovaga qo‘yish", hkPasteC: "O‘chiq: faqat nusxa", hkMore: "Boshqa tugmalar", hkHeld: "Endi qo‘yib yuboring", hkWorks: "Ishlayapti", hkDoes: "Nima qiladi",
            hkGHold: "Bosib turish", hkGHoldC: "Bosib turganingizda gapiring", hkGTwice: "Ikki marta bosish", hkGTwiceC: "Ushlab turmasdan; to‘xtatish uchun yana bosing",
            hkTest: { "Sinash uchun \($0)’ni bosib turing" },
            plSub: "Qayerda chiqadi, nimani ko‘rsatadi.", plPos: "Joylashuv",
            plPosI: "Ekran xaritasida joyni bosing. Yoki indikatorni aniq joyga qo‘ying: «Ekranda joylash»ni bosib, uni suring.",
            plPlace: "Ekranda joylash", plReset: "Tiklash", plOwn: "O‘zingiz tanlagan joy", plHiddenC: "Xatolar baribir ko‘rinadi",
            plShow: "Yana ko‘rsatish", plWhile: "Diktovka paytida", plHidden: { "\($0)gacha yashirin" },
            plLive: "Jonli matn", plLiveC: "Gapirayotganda oldindan ko‘rish",
            plLiveI: "Faqat oldindan ko‘rish: qo‘yiladigan matn baribir modeldan keladi. Google AI Studio API key kerak. Aralash nutqda kechikishi yoki to‘xtashi mumkin.",
            plDetails: "Matn va vaqt", plDetailsC: "Har bir diktovkadan keyin",
            plTouch: "Tasodifiy bosishlarni e’tiborsiz qoldirish", plTouchC: "Qisqa bosish va jimlik",
            plTouchI: "Qisqa bosishlar va jim ushlab turishlar hech narsa yuborilmasdan tashlab yuboriladi: so‘rov ham, qo‘yish ham yo‘q.",
            touchRelaxed: "Yumshoq", touchNormal: "Oddiy", touchStrict: "Qattiq", plSounds: "Ovozlar",
            abSub: "Versiya va yangilanishlar.", abVersion: "Versiya", abUpdates: "Yangilanishlar",
            abUpdatesI: "Tekshirish faqat GitHub’dan oxirgi versiya raqamini so‘raydi; boshqa hech narsa yuborilmaydi. Yangilanish faqat sizdagi Soyla kabi imzolangan bo‘lsa o‘rnatiladi.",
            abDaily: "Har kuni tekshirish", abCheck: "Hozir tekshirish", abAuto: "Avtomatik o‘rnatish", abAutoC: "Bo‘sh paytda yangilanadi",
            abAutoI: "Soyla diktovka qilmayotganingizda yangi versiyani o‘rnatib, o‘zi qayta ishga tushadi. Keyin macOS bir marta Mac parolingizni so‘raydi.",
            abSource: "Manba kodi", abGitHub: "GitHub’da Soyla", abSetup: "Sozlash yordamchisi", abSetupC: "Sozlashni qayta o‘tish", abOpen: "Ochish…",
            devSub: "Sinov sozlamalari va vaqtlar.",
            hiSub: "Barcha diktovkalar, yangilari birinchi.", hiSearch: "Qidirish", hiClean: "Tuzatilgan", hiRaw: "Asl matn",
            hiEmpty: "Istalgan ilovada {key}’ni bosib turing. So‘zlaringiz shu yerda chiqadi.", hiNoMatch: "Hech narsa topilmadi.", hiKeys: "Oxirgini qo‘yish ⌃⌘V · Nusxa olish ⌃⌘C",
            hiCount: { "\($1) tadan \($0) ta" },
            cxFail: "Bu API key ishlamadi. Tekshirib, qayta urinib ko‘ring.", cxCancel: "Bekor qilish",
            cxBoth: "Bitta API key o‘zbek va rus tili uchun ishlaydi.", cxPriv: { "Ovoz to‘g‘ridan-to‘g‘ri \($0)’ga boradi." },
            waitPerms: "Ruxsat kutilmoqda", pillKeyHint: "Ingliz tili usiz ishlaydi.", pFnSet: "Sozlangan", attention: "E’tibor kerak", pcNoSound: "Mikrofondan ovoz kelmayapti",
            keyRemoveQ: "API key o‘chirilsinmi?", keyRemoveCloud: "API key qo‘shmaguningizcha Cloud orqali diktovka to‘xtaydi.",
            eWhere: "Qayerda ishlaydi", modelCFull: "Aniqroq; Lite tezroq", plSoundsC: "Boshlash va to‘xtatish", plVolume: "Ovoz balandligi", plPlay: "Tinglash",
            keyRemoveStops: { "\(AppStrings.cap1(subj[$0] ?? "")) ishlamay qoladi." },
            dRepl: "Almashtirishlar", dReplC: "Eshitilgan → yoziladi", dAdd: "Qo‘shish…", dSpell: "Imlo", dSpellC: "Ismlar, har qatorda bittadan",
            devMode: "Dasturchi rejimi", devModeC: "Tarixda vaqtlar",
            devModeI: "Tarixda vaqtlar va yozuv belgilarini, pastda esa sinov sozlamalarini ko‘rsatadi. Kundalik ishlatish uchun bularning hech biri kerak emas.",
            pillKey: { "\(AppStrings.cap1(subj[$0] ?? "")) uchun API key kerak" }, about: { "\($0) haqida" }, d: .uz)
    }()

    static let ru: AppStrings = {
        let gen: [CloudCombo: String] = [.uz: "узбекского", .ru: "русского", .uzru: "узбекского и русского"]
        let acc: [CloudCombo: String] = [.uz: "узбекский", .ru: "русский", .uzru: "узбекский и русский"]
        return AppStrings(
            navHome: "Главная", navHistory: "История",
            page: [.apiKeys: "Языки", .permissions: "Разрешения", .dictation: "Диктовка", .hotkey: "Клавиша", .pill: "Индикатор",
                   .privacy: "Конфиденциальность", .about: "О программе", .developer: "Разработчик"],
            version: { "Версия \($0)" }, setupA: "Ассистент настройки…", uiAria: "Язык интерфейса",
            n: [.en: "Английский", .uz: "Узбекский", .ru: "Русский"],
            ready: "Soyla готова", holdSub: "Зажмите {key} в любом приложении.",
            more: { "Ещё один шаг для \(gen[$0] ?? "")" }, moreSub: "Английский уже работает.",
            micOff: "Soyla пока вас не слышит", micOffSub: "Разрешите доступ к микрофону, затем зажмите {key}.",
            axOff: "Soyla пока не может печатать за вас", axOffSub: "Включите Универсальный доступ (Accessibility), затем зажмите {key}.",
            keyTitle: "Soyla нужен API-ключ", needsKeySub: "Добавьте API-ключ, затем зажмите {key}.",
            tryPh: "Нажмите сюда, зажмите fn и говорите", handsFree: "Не удерживая", cancel: "Отмена", tShort: "Держите чуть дольше.",
            listening: "Слушаю…", writing: "Пишу…", secs: "с", onMacLow: "на этом Mac", via: { "через \($0)" },
            langs: "Ваши языки", change: "Изменить…", onMac: "На этом Mac", cloudVia: { "Облако · \($0)" }, cloudOnly: "Облако",
            readyW: "Работает", needsKey: "Нужен API-ключ", connect: "Подключить…", offW: "Выключен", useCloud: "Включить облако",
            perms: "Разрешения", pMic: "Слышать ваш голос", pMicC: "Микрофон", pMicB: "Разрешить…", pOff: "Не разрешено",
            pAx: "Печатать там, где курсор", pAxC: "Accessibility (Универсальный доступ)",
            last: "Последняя диктовка", allHist: "Вся история", copy: "Копировать", copied: "Скопировано",
            today: { "Сегодня: \($0) · обычно \($1) с" },
            todayEmpty: "Пока пусто. Здесь появится ваша первая фраза.", metaToday: "Сегодня",
            failedRun: "Эта диктовка не прошла. Повторите её из Истории.",
            keychainWaiting: "Теперь Soyla хранит API-ключ в личном файле на этом Mac. macOS в последний раз просит пароль Mac, чтобы Soyla перенесла ключ из Keychain. Введите его и нажмите Allow.",
            keychainDenied: "macOS не дала Soyla перенести сохранённый API-ключ из Keychain. Завершите и снова откройте Soyla, затем введите пароль Mac и нажмите Allow.",
            keychainPending: "Soyla не смогла открыть Keychain, чтобы перенести сохранённый API-ключ. Завершите и снова откройте Soyla, чтобы попробовать ещё раз.",
            keyFileUnreadable: "Soyla не может прочитать файл с сохранёнными ключами. Подключите API-ключ заново.",
            mHold: "Зажмите {key} в любом приложении", mMicFirst: "Сначала разрешите доступ к микрофону.", mWorks: "Английский уже работает.",
            mConnect: { "Подключить \(acc[$0] ?? "")…" }, mMic: "Разрешить доступ к микрофону…", mOpen: "Открыть Soyla",
            mPaste: "Вставить последнюю диктовку", mCopyLast: "Скопировать последнюю диктовку", mSettings: "Настройки…",
            mSetup: "Ассистент настройки…", mReport: "Сообщить о проблеме…", mQuit: "Завершить Soyla",
            mAxFirst: "Сначала включите Универсальный доступ (Accessibility).", mAx: "Включить Универсальный доступ…", mKeyFirst: "Сначала добавьте API-ключ.",
            mSecure: "Включён Secure Input: вставка отключена",
            mHotkeyOff: "Клавиша не работает: проверьте разрешения",
            eTitle: "Языки", eSub: "Где каждый язык превращается в текст.",
            eInfo: ["Английский может работать на этом Mac через речевую модель Apple: бесплатно, без интернета, ничего не покидает Mac.",
                    "Узбекский, русский и смешанная речь идут в выбранный облачный сервис с вашим API-ключом. Звук идёт с этого Mac прямо в сервис. Серверов Soyla нет.",
                    "Когда включено облако, английский идёт через тот же сервис."],
            eCloud: "Облако", eCloudC: "Все языки, смешанные фразы", eMac: "На этом Mac",
            eMacC: "Только английский · бесплатно, без интернета",
            key: "API-ключ", service: "Сервис", gC: "Бесплатно для начала", oC: "Оплата по факту", notAdded: "Не добавлен", replace: "Заменить…",
            model: "Модель", modelC: "Flash-Lite: быстрее, менее точная", macModel: "Английская речевая модель", macModelC: "Apple · без интернета",
            connected: "Подключено",
            keyRemove: "Удалить ключ", keyRejected: "Ключ отклонён", keyUnchecked: "Не проверен", keyChecking: "Проверяем…",
            mmAbout: "О программе Soyla", mmUpdates: "Проверить обновления…", mmHide: "Скрыть Soyla", mmHideOthers: "Скрыть остальные",
            mmEdit: "Правка", mmUndo: "Отменить", mmRedo: "Повторить", mmCut: "Вырезать", mmCopy: "Копировать", mmPaste: "Вставить",
            mmSelectAll: "Выбрать все", mmView: "Вид", mmSettingsTab: "Настройки", mmWindow: "Окно", mmSoylaWindow: "Окно Soyla",
            mmMinimize: "Свернуть", mmClose: "Закрыть", mmHelp: "Справка",
            pillOpen: { "Открыть «\($0)»" }, pillRetry: "Повторить",
            pvTitle: "Конфиденциальность", pvSub: "Что остаётся на этом Mac, а что уходит.",
            pvInfo: ["У Soyla нет аккаунта и сервера. Текст и записи хранятся только на этом Mac.",
                     "Облачный сервис получает только звук диктовки, с вашим API-ключом."],
            pvWhere: "Куда идёт ваш голос", stays: "Остаётся на этом Mac", rMac: "Этот Mac", recs: "Записи",
            keep: "Хранить записи", keepC: "Текст остаётся в Истории",
            keepI: "Запись позволяет повторить диктовку. Запись неудачной диктовки хранится, пока вы её не повторите или не удалите.",
            retNever: "Не хранить", ret14: "14 дней", retForever: "Всегда", ret7: "7 дней", retAfterRun: "До вставки",
            folder: "Папка данных", finder: "Показать в Finder", mic: "Микрофон", warm: "Держать микрофон включённым", warmC: "Быстрый запуск",
            warmI: "Пока микрофон открыт, горит его индикатор. Выключен: микрофон открывается, только пока вы держите клавишу, примерно через 0,3 с после нажатия. При блокировке экрана и сне Mac он всегда закрывается.",
            warmOff: "Выключен между диктовками", warm30: "30 с после диктовки", warmOn: "Всегда",
            builtin: "Предпочитать встроенный микрофон", builtinNow: { "Сейчас: \($0)" },
            startup: "Запуск", login: "Открывать Soyla при входе", loginApproval: "Подтвердите в System Settings → General → Login Items.",
            loginFailed: { "Не удалось изменить объект входа: \($0)" },
            permSub: "Что macOS разрешает Soyla.", pSpeech: "Распознавать английский на этом Mac", pSpeechC: "Speech Recognition",
            dicSub: "Как записываются ваши слова.", dLang: "В основном говорю", dLangC: "Авто понимает смешанную речь",
            dLangI: "Автоопределение понимает смешанные фразы. Выберите один язык, только если Soyla часто ошибается.", langAuto: "Автоопределение",
            dClean: "Коррекция", dCleanC: "Убирает лишние слова",
            dCleanI: "Лёгкая убирает повторы и слова-паразиты и применяет самоисправления (примерно +1,8 с). Исходный: текст вставляется как услышан. Оригинал всегда остаётся в Истории.",
            cleanOff: "Исходный", cleanLight: "Лёгкая", dDict: "Личный словарь",
            hkSub: "Клавиша, которую вы держите.", hkHold: "Зажать и говорить",
            hkHoldI: "Для fn: System Settings → Keyboard → «Press 🌐 key to» → Do Nothing, и закройте другие приложения диктовки.",
            hkWhere: "Куда идёт текст", hkPaste: "Вставлять в приложение", hkPasteC: "Выключено: только копия", hkMore: "Другие клавиши", hkHeld: "Теперь отпустите", hkWorks: "Работает", hkDoes: "Что делает",
            hkGHold: "Удерживать", hkGHoldC: "Говорите, пока держите", hkGTwice: "Нажать дважды", hkGTwiceC: "Не удерживая; нажмите ещё раз, чтобы остановить",
            hkTest: { "Зажмите \($0), чтобы проверить" },
            plSub: "Где появляется и что показывает.", plPos: "Положение",
            plPosI: "Нажмите на место на карте экрана. Или поставьте индикатор точно: нажмите «Разместить на экране» и перетащите его.",
            plPlace: "Разместить на экране", plReset: "Сбросить", plOwn: "Своё место", plHiddenC: "Ошибки всё равно видны",
            plShow: "Показать снова", plWhile: "Во время диктовки", plHidden: { "Скрыт до \($0)" },
            plLive: "Живой текст", plLiveC: "Предпросмотр во время речи",
            plLiveI: "Только предпросмотр: вставленный текст всё равно приходит от модели. Нужен ключ Google AI Studio. На смешанной речи может отставать или останавливаться.",
            plDetails: "Текст и время", plDetailsC: "После каждой диктовки",
            plTouch: "Игнорировать случайные нажатия", plTouchC: "Короткие нажатия и тишина",
            plTouchI: "Короткие нажатия и тихие удержания отбрасываются до отправки: ни запроса, ни вставки.",
            touchRelaxed: "Мягко", touchNormal: "Обычно", touchStrict: "Строго", plSounds: "Звуки",
            abSub: "Версия и обновления.", abVersion: "Версия", abUpdates: "Обновления",
            abUpdatesI: "Проверка только спрашивает у GitHub номер последней версии; больше ничего не отправляется. Обновление ставится, только если подписано так же, как ваша Soyla.",
            abDaily: "Проверять ежедневно", abCheck: "Проверить сейчас", abAuto: "Устанавливать автоматически", abAutoC: "Перезапуск в простое",
            abAutoI: "Soyla ставит новую версию, когда вы не диктуете, и сама перезапускается. Затем macOS один раз спросит пароль Mac.",
            abSource: "Исходный код", abGitHub: "Soyla на GitHub", abSetup: "Ассистент настройки", abSetupC: "Пройти настройку снова", abOpen: "Открыть…",
            devSub: "Настройки для тестов и замеры.",
            hiSub: "Все диктовки, новые сверху.", hiSearch: "Поиск", hiClean: "Исправленный", hiRaw: "Исходный",
            hiEmpty: "Зажмите {key} в любом приложении. Слова появятся здесь.", hiNoMatch: "Ничего не найдено.", hiKeys: "Вставить последнюю ⌃⌘V · Копировать ⌃⌘C",
            hiCount: { "\($0) из \($1)" },
            cxFail: "Ключ не подошёл. Проверьте его и попробуйте снова.", cxCancel: "Отмена",
            cxBoth: "Один ключ работает для узбекского и русского.", cxPriv: { "Звук идёт напрямую в \($0)." },
            waitPerms: "Ждёт разрешений", pillKeyHint: "Английский работает и без него.", pFnSet: "Настроено", attention: "Требует внимания", pcNoSound: "Нет звука с микрофона",
            keyRemoveQ: "Удалить API-ключ?", keyRemoveCloud: "Диктовка через облако остановится, пока вы не добавите ключ.",
            eWhere: "Где работает", modelCFull: "Точнее; Lite быстрее", plSoundsC: "Начало и конец", plVolume: "Громкость звуков", plPlay: "Прослушать",
            keyRemoveStops: { "\(AppStrings.cap1(acc[$0] ?? "")) \($0 == .uzru ? "перестанут" : "перестанет") работать." },
            dRepl: "Замены", dReplC: "Услышано → пишется", dAdd: "Добавить…", dSpell: "Написание", dSpellC: "Имена, по одному в строке",
            devMode: "Режим разработчика", devModeC: "Замеры в Истории",
            devModeI: "Показывает замеры и метки записей в Истории и настройки для тестов ниже. Для повседневной работы ничего из этого не нужно.",
            pillKey: { "Для \(gen[$0] ?? "") нужен API-ключ" }, about: { "Подробнее: \($0)" }, d: .ru)
    }()
}
