# Soyla long test scripts (phrases 6–10)

Read each one at a **natural pace** (don't slow down for the machine). Target lengths are for normal speech;
all stay under the 45 s warning that applies with *Transcribe while speaking* off (with it on, the limit is 5 min).
Before each recording, tag it: switch on **Developer mode** (Settings → Developer), then use the menu bar icon →
**Tag next run as → phrase N** (or Settings → Developer → **Tag next run as phrase**). The item is hidden without Developer mode.
Recommended: record each script **3 times**, once with **Mainly speak** = Auto-detect and twice with **Uzbek**
(Settings → Dictation → Mainly speak; stored as `languageHint`).

Accuracy is scored automatically against the text below: `python3 scripts/score.py` (word error rate per run).
The text between the ``` fences is the reference — edit it if you deliberately change wording.

Fillers (ee, xo'sh) and self-corrections in phrase 9 are meant to be spoken. The raw transcript is scored against the
**spoken** text; the cleaned transcript (cleanup on) should match the **clean** version.

---

## Phrase 6 — pure Uzbek, numbers and dates (~30 s)

```
Assalomu alaykum, hurmatli hamkasblar. Bugungi yig'ilishda uchta asosiy masalani ko'rib chiqamiz. Birinchisi, o'tgan oydagi savdo natijalari: umumiy tushum qirq ikki million besh yuz ming so'mni tashkil qildi, bu rejadan o'n ikki foiz yuqori. Ikkinchisi, yangi filial ochilishi. U Chilonzor tumanida, yigirma beshinchi noyabrda ishga tushadi. Uchinchisi, xodimlar malakasini oshirish bo'yicha trening, uni dekabr oyining birinchi haftasida o'tkazamiz.
```

Tests: o'/g' apostrophes, long numbers, ordinal dates, place names.

## Phrase 7 — Uzbek ↔ Russian switching (~35 s)

```
Kecha mijoz bilan gaplashdim, ular shartnomani imzolashga tayyor, но есть один нюанс: они хотят отсрочку платежа на шестьдесят дней. Men bunga darhol rozi bo'lmadim, chunki bizning moliyaviy holatimiz hozircha bunday muddatga imkon bermaydi. Предлагаю такой вариант: тридцать процентов предоплата, остальное через сорок пять дней. Agar ular rozi bo'lishsa, shartnomani shu haftaning oxirigacha yopamiz. Buxgalteriya bilan ham kelishib olish kerak, пусть они подготовят счёт-фактуру заранее.
```

Tests: Russian must stay **Cyrillic**, Uzbek must stay **Latin**, switches mid-sentence. This is the one most likely
to break with Mainly speak = Uzbek — compare Auto-detect vs Uzbek here.

## Phrase 8 — Uzbek + English tech terms (~35 s)

```
Bugun sprint review bor, shuning uchun hamma o'z tasklarini update qilib qo'ysin. Backend tomonda API endpointlar tayyor, lekin authentication flowda bitta bug bor: logindan keyin token refresh ishlamayapti. Frontend jamoasi dashboardni deploy qildi, stagingda tekshirib ko'ring. Pull requestlarni bugun soat beshgacha review qilib, merge qilamiz. Deadline o'zgarmaydi, release yigirmanchi noyabrda production ga chiqadi.
```

Tests: English words with Uzbek suffixes (tasklarini, endpointlar, dashboardni), times, dates.

## Phrase 9 — natural ramble: fillers, self-corrections, all three languages (~45 s)

Spoken (read this, including ee / xo'sh / yo'q):

```
Xo'sh, endi keyingi haftaning rejasi haqida. Dushanba kuni, yo'q, kechirasiz, seshanba kuni ertalab soat o'nda investorlar bilan uchrashuv bor. Ular ee asosan unit economics va retention metrikalarini so'rashadi, shuning uchun prezentatsiyaga oxirgi uch oyning ma'lumotlarini qo'shish kerak. Кстати, Дильноза обещала прислать отчёт по маркетингу, надо ей напомнить. Keyin ee chorshanba kuni, yo'q, payshanba kuni jamoa bilan offsite qilamiz, joyni hali tanlamadik, balki Chorvoqda bo'lar. Budjet taxminan yetti million so'm, ko'pi bilan sakkiz million. Xullas, hammaga rahmat, savollar bo'lsa Telegramda yozinglar.
```

Clean (what the cleanup pass should produce):

```
Endi keyingi haftaning rejasi haqida. Seshanba kuni ertalab soat o'nda investorlar bilan uchrashuv bor. Ular asosan unit economics va retention metrikalarini so'rashadi, shuning uchun prezentatsiyaga oxirgi uch oyning ma'lumotlarini qo'shish kerak. Кстати, Дильноза обещала прислать отчёт по маркетингу, надо ей напомнить. Keyin payshanba kuni jamoa bilan offsite qilamiz, joyni hali tanlamadik, balki Chorvoqda bo'lar. Budjet taxminan yetti million so'm, ko'pi bilan sakkiz million. Xullas, hammaga rahmat, savollar bo'lsa Telegramda yozinglar.
```

Tests: long clip near the limit, filler removal, "Dushanba … yo'q … seshanba" self-correction, three languages.

## Phrase 10 — finance / contract dictation (~30 s)

```
Shartnoma raqami A ikki ming yigirma oltidan bir yuz o'n yetti. To'lov jadvali quyidagicha: birinchi to'lov o'n beshinchi dekabrda, summasi uch million ikki yuz ming so'm. Ikkinchi to'lov o'n beshinchi yanvarda, xuddi shu summa. Ustama yillik yigirma ikki foiz, kechiktirilgan har bir kun uchun jarima nol butun bir foiz. Barcha to'lovlar bank o'tkazmasi orqali amalga oshiriladi.
```

Tests: dense numbers, decimals, IDs, financial vocabulary.

---

### Scoring note

Gemini usually writes numbers as digits ("42 500 000", "25-noyabr"), while the references spell them out. The
score script normalises apostrophe variants and punctuation but **not** numbers, so number-heavy phrases (6, 10)
carry a WER penalty for correct digits. Use `--show` to eyeball those; compare models/formats/settings against
each other on the same phrase rather than reading the absolute number.
