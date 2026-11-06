# topbar

Остров в вырезе MacBook для сессий Claude Code (Swift/SwiftPM, AppKit + SwiftUI, macOS 14+) и служба `server/` (Node 24 + Hono + SQLite).

## Команды

```bash
swift build                                 # сборка
swift test                                  # все тесты (XCTest, только TopbarCore)
swift test --filter BranchReaderTests       # один класс тестов
scripts/build-app.sh --install              # собрать build/topbar.app и поставить в ~/Applications
cd server && npm test                       # тесты службы (node --test)
cd server && node --test test/app.test.ts   # один файл
```

Линтера и форматтера нет.

## Устройство

- `TopbarCore` — логика без AppKit, её покрывают тесты; `Sources/topbar` — оболочка (окна, строка меню, плеер). Новую логику — в ядро, с тестом.
- `topbar-hook` — мост: Claude Code запускает его на каждый хук, он передаёт событие приложению через сокет и при любой неудаче молча выходит с кодом 0, чтобы не мешать сессии.
- Адреса ленты обновлений и службы вшиваются при сборке (`TOPBAR_FEED_URL`, `TOPBAR_SERVER_URL`): `build-app.sh` без них собирает приложение без обновлений и без отправки, `release.sh` подставляет боевые.

## Словарь

Остров — панель в вырезе; уши — его части слева и справа от выреза; знак topbar — значок приложения в строке меню; выталкиватель — невидимый значок впритык левее знака: в свёрнутом виде он растягивается, и система убирает всё, что левее.

## Не делать

- Выкладка наружу (`scripts/publish.sh`, `gh release create`, деплой службы) — только по решению владельца.
- `scripts/sparkle-public-key.txt` не менять: им проверяются обновления у всех уже установленных копий.
