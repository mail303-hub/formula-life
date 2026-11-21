# Formula Life

A browser game: climb from junior karting to Formula 1.

- 6 tiers: Junior Karting, Senior Karting, Formula 4, Formula 3, Formula 2, Formula 1
- 10 tracks per tier, difficulty 1 to 10; clear one with a podium to unlock the next
- Corner sharpness: gentle / medium / sharp
- Team offers by reputation, weekend actions (training, rest, sponsors)
- Drive every race yourself (first-person view, full screen, barriers, rival contact)
- Sound, keyboard, gamepad (with button mapping) and on-screen touch sliders for phones
- Online races with friends: account = username + password (no email), friend requests, private rooms of up to 4 players; guests can join with a 6-character room code or an invite link (`?join=CODE`), no account
- Progress is saved in the browser (localStorage)

## Run

Open `index.html` in a browser. No build step.

## Online play

Online play uses a free Supabase project (accounts, friends, rooms, realtime channel).
`supabase/schema.sql` creates everything; run it once in the Supabase SQL editor, turn off
"Confirm email" and turn on "Allow anonymous sign-ins" under Authentication, and put the project URL and publishable key into `SB` in `index.html`.
All table access goes through functions; tables are locked by row level security.
