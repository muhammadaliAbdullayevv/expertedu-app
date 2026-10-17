# V2 design reference (Expert Learning Center CRM)

Open any .html file in a browser. Static mockups with SAMPLE data: the visual and layout source of truth.
Do not copy the HTML into Flutter; recreate each screen with Flutter widgets and these tokens.

## Design tokens
- Font DM Sans (400-700). Accent (single theme token) #5B4DDB; soft accent #EFEDFD; accent text on soft #3B2FA8.
- Page #F7F7F5, surface #FFFFFF, border #E8E8E4, divider #EFEFEC, ink #17171A, muted #62626B.
- Status chips (always with text): ok #E4F5EC/#0B5C3B; warning #FFF1D6/#7A4800; danger #FDECEA/#8F1D16; info #EFEDFD/#3B2FA8; neutral #EFEFEC/#44444C.
- Radius: cards 14, buttons/inputs 10-12, chips pill.
- Desktop: sidebar 244 + top bar (Ctrl K command bar, "+ Yangi"); lists = table plus right side panel (400-460).
- Phone screens (11, 12) are NOT being built yet.

## Screens
01 bugun, 02 qabul-yangi-qoshish, 03 qabul-royxat, 04 oquvchi-qilish-dialog, 05 kurs-qidirish,
06 oquvchilar, 07 guruhlar, 08 oqituvchilar, 09 jadval, 10 moliya, 11 telefon-bugun, 12 telefon-tolov.

## Qabul (admissions) is deliberately minimal
Two views switched by a button at the top of the page: "Yangi qo'shish" (default, a fast form) and "Ro'yxat".
NO stats, NO counters, NO stages, NO kanban on Qabul. Speed is the priority: the form must save in a few keystrokes
and clear itself for the next customer (with a short "saved / Qaytarish" notice).
A saved person is NOT a student: no seat, no charge, no debt. Optional free trial date. "O'quvchi qilish" converts them.

## Sample-data inconsistencies (ignore)
Counts differ across screens. Teacher percent shows as [FOIZ] placeholder.
