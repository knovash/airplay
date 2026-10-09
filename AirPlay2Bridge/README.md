# AirPlay 2 Bridge (LMS plugin)

Обход бага **HomePodOS 27** (legacy RAOP принимается, RTP идёт, звук не рендерится —
[philippe44/LMS-Raop#57](https://github.com/philippe44/LMS-Raop/issues/57); philippe44
отказался внедрять AirPlay 2: «It's a big change … I don't want to go there»).

Идея — как у [cayco-squeezelite-airplay2-bridge](https://github.com/cayco/cayco-squeezelite-airplay2-bridge),
но оформлено как плагин LMS (Perl) и работает без Docker:

```
LMS → squeezelite (stdout PCM) → bridge.py (pyatv, AirPlay 2 / HAP transient) → HomePod
```

В LMS появляются обычные squeezelite-плееры — синкгруппы, УДЯ, Tasker работают как раньше.

## Credits (исходники)

- **[cayco/cayco-squeezelite-airplay2-bridge](https://github.com/cayco/cayco-squeezelite-airplay2-bridge)** —
  основной источник: архитектура squeezelite→pyatv, патч output_stdout.c, AP2-флаги,
  RingBuffer/бэкпрессура/idle-teardown/пересылка громкости (опубликовано в
  [LMS-Raop#57](https://github.com/philippe44/LMS-Raop/issues/57), октябрь 2026).
- **[postlund/pyatv](https://github.com/postlund/pyatv)** (MIT) — реализация AirPlay 2
  (HAP-transient pairing, ChaCha20, RAOP), на которой всё работает.
- **[philippe44/LMS-Raop](https://github.com/philippe44/LMS-Raop)** — RaopBridge: образец
  UI discovery-настроек и контекст проблемы (issue #57).
- **toralt** — исходный рецепт «squeezelite | pyatv» из треда #57.
- **squeezelite** (Adrian Smith, Ralph Irving) — база патча output_stdout.c (**GPLv3**).

Лицензии: `patches/output_stdout.c` — GPLv3 (наследует squeezelite); `bridge.py` —
наш код по рецепту cayco (у его репозитория лицензия не указана); сам плагин —
в рамках лицензии проекта lyrion-yandex-bridge.

## Настройки плагина (как у RaopBridge)

Кнопка **«Найти устройства» / Start Discovery Scan** запускает `bridge.py --scan`
(pyatv mDNS, ~10 сек) и показывает таблицу найденных AirPlay-устройств:
галочка «использовать», редактируемое имя плеера, IP, AirPlay ID, MAC, модель+ОС.
Новые устройства добавляются выключенными; отсутствующие при последнем скане
помечаются серым «не найден»; совпадение имени с существующим плеером LMS — метка «!».

Данные: преф `devices` = TSV-строки `id\tname\tip\tmac\tenabled\tmodel\tov`.
**MAC известных устройств никогда не перегенерируется** (наследование плейлистов/
синкгрупп от старых RaopBridge-плееров; новым — `aa:aa:` + начало airplay-id).
Преф `players` (формат BridgeProcess: `name,mac,id,host` на строку) генерируется
из отмеченных устройств при Save — мосты перезапускаются автоматически.
Миграция: при первом открытии страницы `devices` сеется из старого `players` (все включены).

## Состав

| Файл | Назначение |
|---|---|
| `Plugin.pm` | init/shutdown, дефолты (3 HomePod) |
| `BridgeProcess.pm` | запуск/стоп/автоперезапуск python-мостов (pid-файлы, beat 30с) |
| `Settings.pm` + `HTML/…/basic.html` | discovery-скан + таблица устройств (галочки/имена), пути |
| `Bin/bridge.py` | мост: RingBufferAudioSource → pyatv `stream_file()`, idle 30с → teardown, громкость LMS→HomePod; `--scan` — discovery (TSV: `id\tname\tip\tmodel\tov`) |
| `patches/output_stdout.c` | патч squeezelite: не писать тишину в stdout + usleep при пустом буфере (иначе idle = 100% CPU) |
| `patches/build_squeezelite.sh` | сборка патченого squeezelite из Debian-исходников |

## Установка на бокс (aarch64, Debian 12)

```sh
apt-get install -y squeezelite python3-pip
pip3 install --break-system-packages pyatv==0.18.0
# патченый squeezelite:
bash patches/build_squeezelite.sh     # -> /usr/local/bin/squeezelite-ap2
# плагин:
cp -r AirPlay2Bridge /usr/share/squeezeboxserver/Plugins/
chown -R squeezeboxserver:nogroup /usr/share/squeezeboxserver/Plugins/AirPlay2Bridge
# рестарт LMS, плагин включается сам (defaultState enabled)
```

## Настройка плееров (ручной формат)

Выбирается галочками в таблице после скана (см. выше). Ручной формат (преф `players`,
RaopBridge-плееров** (`aa:aa:…`), чтобы сохранить плейлисты/синкгруппы/имена;
RaopBridge при этом должен быть выключен (state.prefs → `RaopBridge: disabled`),
иначе будут дубли плееров.

AirPlay ID/IP берутся из `pyatv scan` (см. `bridge.py` — мDNS-скан приоритетнее,
ManualService с AP2-флагами — fallback).

## Поведение

- тишина/пауза 30 с → разрыв AirPlay-сессии (HomePod освобождается, уходит в сон);
- громкость: `digitalVolumeControl 0` в LMS (без двойного затухания), значение
  микшера пересылается в HomePod (+ повтор через 1.5с и 4с после старта — HomePodOS
  игнорирует ранние команды);
- backpressure: буфер ≤1.5с, squeezelite блокируется на stdout-пайпе;
- звуковое обнаружение: любой ненулевой чанк PCM (патч squeezelite не пишет нули в idle);
- endianness: squeezelite отдаёт LE → в RAOP шлём BE (`array.byteswap()`).

## Грабли, на которые наступили

1. pyatv 0.18: `scan(loop, …)`/`connect(conf, loop)` — loop обязателен.
2. pyatv 0.18: `AudioSource` требует `sample_size` и `duration` (у cayco их не было).
3. `atv.audio.volume` — свойство, не метод.
4. `-a :16:44100:2` для stdout неверно → S32_LE; правильно `-a 16`.
5. Без патча output_stdout.c: squeezelite в idle льёт нули и жжёт CPU (питон-ридер 95%).
6. SIGTERM: volume_monitor блокирован в readline() CLI — в stop() закрываем сокет
   + страховочный `os._exit(0)` через 5с.
7. `pgrep -f "bridge.py HomePod"` в SSH убивает свою же сессию — использовать `[b]ridge.py`.
8. LMS settings footer всегда шлёт hidden `saveSettings=1` — Scan-клик (submit
   `scanSettings`) обрабатывать ПЕРВЫМ, иначе скан будет сопровождаться сохранением.
9. LMS «needs-uninstall» в state.prefs: рестарт с таким флагом УДАЛЯЕТ файлы плагина
   (так бесследно исчез RaopBridge; восстановление — только переустановка из репо).
