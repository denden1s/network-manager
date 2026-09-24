---
kanban-plugin: board
---

## Backlog (P2)

- [ ] #7 Автозапуск при логине (Login Items / SMAppService)
- [ ] #8 Обработка ошибок и логи (показ alert при падении networksetup)
- [ ] #9 README + инструкция сборки для Xcode

## Todo (P0-P1)

- [ ] #1 Scaffold Xcode-проекта (MenuBarExtra, macOS 13+, иконка в трее) `P0`
- [ ] #2 Переключение Location: `networksetup -switchtolocation ethernet_work / ethernet_home` + чтение `networksetup -getcurrentlocation` `P0`
- [ ] #3 Toggle Wi-Fi power: `networksetup -setairportpower <dev> on/off` для всех Wi-Fi `P1`
- [ ] #4 Смена DNS на всех Wi-Fi сервисах: Work `192.168.105.11`, Home `8.8.8.8` через `networksetup -setdnsservers` `P0`
- [ ] #5 UI поповера: Toggle Work/Home + Toggle Wi-Fi + статус + Apply `P1`
- [ ] #6 Privileged prompt через osascript (`with administrator privileges`) при каждом переключении `P1`

## In Progress

- [ ] #1 Scaffold Xcode-проекта (MenuBarExtra, macOS 13+, иконка в трее) `P0`

## Done

- [x] Grill-me интервью: Locations=Network Locations, Wi-Fi toggle=power on/off, DNS=ко всем Wi-Fi, sudo=prompt, git=local+kanban

---

## План и приоритеты

- P0: #1, #2, #4 — без этого сервис не меняет сеть, делать первым.
- P1: #3, #5, #6 — UX и Wi-Fi power + пароль.
- P2: #7, #8, #9 — полировка.
- Порядок: 1 → 2 → 4 → 6 → 3 → 5 → 8 → 7 → 9.
- Каждый коммит = одна фича (#N).
