---
kanban-plugin: board
---

## Backlog (P2)

- [ ] #7 Автозапуск при логине (Login Items / SMAppService)
- [ ] #8 Обработка ошибок и логи (показ alert при падении networksetup)
- [ ] #10 Автоджойн к SSID по профилю (нужны SSID work/home + пароли/keychain)

## Todo (P0-P1)

(none)

## In Progress

(none)

## Done

- [x] Grill-me интервью (уточнено позже: не Locations, а службы ethernet-work/home)
- [x] #1 Scaffold Xcode-проекта (MenuBarExtra, macOS 13+, иконка в трее) `P0`
- [x] #2 Переключение СЛУЖБ: `setnetworkserviceenabled ethernet-work/home on/off` (свою вкл, чужую выкл + verify) `P0`
- [x] #3 Toggle Wi-Fi power only: `setairportpower <dev> on/off` + скан `airport -s` при ON `P1`
- [x] #4 Смена DNS на всех Wi-Fi сервисах: Work `192.168.105.11`, Home `8.8.8.8` + flush `P0`
- [x] #5 UI поповера: Work/Home + Wi-Fi + статус (Connected/Nearby) + Apply/Refresh/Quit/Copy Diagnostics `P1`
- [x] #6 Privileged prompt через osascript (`with administrator privileges`) `P1`
- [x] Динамическая иконка трея (wifi / cable.connector)
- [x] #9 README + инструкция сборки + scripts/build-and-deploy.sh

---

## План и приоритеты

- P0: #1, #2, #4 — без этого сервис не меняет сеть, делать первым.
- P1: #3, #5, #6 — UX и Wi-Fi power + пароль.
- P2: #7, #8, #9 — полировка.
- Порядок: 1 → 2 → 4 → 6 → 3 → 5 → 8 → 7 → 9.
- Каждый коммит = одна фича (#N).
