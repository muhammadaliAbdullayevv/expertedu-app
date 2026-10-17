# V2 design reference (Expert Learning Center CRM)

Open any .html file in a browser to see the screen. These are static mockups with SAMPLE data.
Use them as the visual and layout source of truth: structure, spacing, colors, typography, states.
Do not copy the HTML into Flutter. Recreate each screen with Flutter widgets and the design tokens below.

## Design tokens
- Font: DM Sans (400, 500, 600, 700). Use tabular numbers for money and counts.
- Accent (single theme token): #5B4DDB. Soft accent background: #EFEDFD. Accent text on soft: #3B2FA8.
- Page background #F7F7F5, surface #FFFFFF, border #E8E8E4, divider #EFEFEC.
- Ink #17171A, muted text #62626B.
- Status chips (always with text): ok bg #E4F5EC / text #0B5C3B; warning #FFF1D6 / #7A4800; danger #FDECEA / #8F1D16; info #EFEDFD / #3B2FA8; neutral #EFEFEC / #44444C.
- Radius: cards 14, buttons and inputs 10, chips pill. Buttons 38-44 high on desktop, touch targets >= 44 on phone.
- Layout: desktop sidebar 244 wide + top bar with command bar (Ctrl K) and "+ Yangi"; list screens use a table with a right-hand side panel (about 400-460 wide) for the selected item.
- Phone: 390 wide, bottom nav (Bugun, O'quvchi, center "+" for payment, Jadval, Moliya); payment is a bottom sheet.

## Screens
01 bugun, 02 qabul-kanban, 03 kurs-qidirish, 04 sinov-darsiga-yozish (dialog), 05 sinovdan-keyin (dialog),
06 oquvchilar, 07 guruhlar, 08 oqituvchilar, 09 jadval, 10 moliya, 11 telefon-bugun, 12 telefon-tolov.

## Known sample-data inconsistencies (ignore)
Student/group counts do not add up across screens. Teacher percent shows as [FOIZ] placeholder.
