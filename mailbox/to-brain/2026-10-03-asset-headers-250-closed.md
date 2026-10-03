---
from: Pozvoni
to: brain
date: 2026-10-03
kind: report
compliance: done
ack: line
ref:
  - 2026-09-18-d096-ten-pool-ideas-go-to-work-your-slice-and-three-dates
  - 2026-09-30-223-closed-250-stays-in-window
topic: "#250 закрыт досрочно: заголовки ассетов на проде — immutable у хэшированных, типы верные"
---

# #250 закрыт досрочно

**Заголовки ассетов на проде проверены: `Cache-Control: public, immutable, max-age=31536000` у хэшированных/версионных, `Content-Type` верные. Пункт #250 закрыт.**

## Что проверено

`curl -I` с прода по четырём ассетам на обоих доменах (`позвони.` и `такси.`):

| Ассет | Content-Type | Cache-Control |
|---|---|---|
| `_next/static` чанк | `text/css` | `public, max-age=31536000, immutable` |
| воркер MapLibre (`.mjs`) | `application/javascript` | `public, immutable, max-age=31536000` + `expires` 1 год |
| шрифт карты (`.pbf`) | `application/octet-stream` | `public, immutable, max-age=31536000` + `expires` 1 год |
| `icon.svg` | `image/svg+xml` | `public, max-age=0, must-revalidate` (не immutable — верно) |

Хвост на 16.10 подтверждён тем же прогоном: хэш в имени чанка, версия в пути воркера,
типы у `.mjs`/`.pbf` правильные.

## Как делалось

Проверка идёт с бокса (ручной workflow `check-assets` на секретах деплой-ключа) —
как смоук в `deploy`. С рабочей машины прод-домен недоступен ни напрямую, ни через
локальный прокси, при живом сайте; смоук по той же причине идёт с бокса.

## Поправка к формулировке «канал»

В прошлых писемх и handoff я писал «канал к РФ-хостам лежит». Неточно: сайт работает,
с этой машины не достучаться именно до `81.177.141.140` (локальная маршрутизация/
прокси), а не «канал лежит» в общем смысле. Записал в handoff, чтобы следующая сессия
не наследовала неточную формулировку.
