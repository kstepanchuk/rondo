# Rondo

**Конвертер файлов для macOS с круговым меню.** Тяните файл, зажмите модификатор, отпустите над нужным сектором. Всё работает локально, без загрузки файлов в интернет.

*[English below](#english)*

| Клавиша | Режим | Примеры |
|---|---|---|
| ⇧ Shift | Конвертация | JPG/PNG/HEIC/AVIF/PDF, MP4/WebM/GIF/MP3, DOCX→PDF, XLSX⇄CSV, PPTX→PDF, SRT⇄VTT, иконки ICNS+ICO |
| ⌃ Control | Инструменты | убрать фон, OCR, QR, палитра, «для веба», разложить PDF/PPTX в PNG, видео 9:16, сжать, убрать тишину, расшифровать речь |
| ⌥ Option | Действия | ZIP/7Z, распаковать, AirDrop, SHA-256, путь, дубликат, ваши Быстрые команды |

- **Несколько файлов**: «Объединить в PDF», «Коллаж», «ZIP всех».
- **Без мыши**: выделите файлы в Finder и нажмите ⌃⌥Пробел (Tab меняет режим, стрелки и Enter выбирают). Или правый клик → Службы → **Rondo…**
- **Свои действия**: создайте в «Быстрых командах» папку **Rondo**, и её команды появятся в режиме ⌥.
- **Разложить в PNG**: рядом с PDF или PPTX создаётся папка с именем файла, внутри `01.png`, `02.png`… Слайды 16:9 получаются ровно 1920×1080.
- Темы: красно-чёрная, бело-голубая или как в системе. Языки: русский и английский.

## Установка

**Homebrew**
```bash
brew install --cask kstepanchuk/rondo/rondo
```

**DMG**: скачайте `Rondo-x.y.z.dmg` из [Releases](https://github.com/kstepanchuk/rondo/releases/latest) и перетащите Rondo в «Программы».
Приложение не нотаризовано, поэтому при первом запуске откройте *Системные настройки → Конфиденциальность и безопасность → Всё равно открыть*.

Rondo обновляется сам из GitHub Releases: раз в день или через меню «Проверить обновления…». Перед установкой обновление проверяется по SHA-256 и подписи.

**Дополнительные движки** (необязательно): `brew install ffmpeg pandoc sevenzip` для аудио, видео, Markdown/EPUB и 7z.
Для DOCX/XLSX/PPTX → PDF используются Microsoft Word, Excel и PowerPoint (или Keynote), если они установлены.

## Приватность и безопасность

- Файлы не покидают Mac. Распознавание речи работает только на устройстве.
- Исходники не перезаписываются: результаты сохраняются в `~/Downloads/Rondo`, «Разложить в PNG» и «Дубликат» кладут файлы рядом с исходником.
- ffmpeg запускается только с локальным протоколом `file`, pandoc с `--sandbox`. Архивы распаковываются без выхода за пределы папки.
- Не нужен доступ к «Универсальному доступу»: модификаторы считываются без перехвата клавиатуры.

## Сборка

```bash
./scripts/build.sh 0.1.0                         # dist/Rondo.app, .zip, .dmg и .sha256
dist/Rondo.app/Contents/MacOS/Rondo --self-test ./samples [--office]
```
Релиз: `git tag v0.1.1 && git push --tags`, после чего GitHub Actions соберёт и опубликует zip и dmg.

Идея вдохновлена [Sweetch](https://github.com/krllmrzv/Sweetch) (@mmmorozov) для Windows. Код написан с нуля.

---

## English

Rondo is a radial-menu file converter for macOS. Drag a file and hold ⇧ to convert, ⌃ for tools or ⌥ for actions, then drop it on a sector. Everything runs locally.

```bash
brew install --cask kstepanchuk/rondo/rondo
```
Or download the DMG from Releases. Optional engines: `brew install ffmpeg pandoc sevenzip`. Office conversions use Word, Excel and PowerPoint (or Keynote) when installed. Rondo updates itself from GitHub Releases and verifies each update by SHA-256 and code signature.

MIT License.
