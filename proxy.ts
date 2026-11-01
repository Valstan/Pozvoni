import { NextResponse, type NextRequest } from "next/server";

import { judgeOrigin } from "./lib/request-origin";

// Единственная задача этого файла: не дать чужой странице писать в приложение от имени
// вошедшего человека. Подробно, почему проверка стоит здесь, а не в Payload `csrf`, и
// почему `SameSite=Lax` от соседа по домену не спасает — `lib/request-origin.ts` и
// `docs/WRITE_AUTHZ.md`.
//
// Что важно знать при правке:
//
// - Файл называется `proxy.ts`, а не `middleware.ts`: в Next 16 middleware переименован,
//   старое имя ещё работает, но `next build` ругается на устаревшее соглашение.
// - Правила живут в `lib/request-origin.ts`, здесь только клей к заголовкам запроса.
//   Правило, размазанное по workflow и прокси, невозможно проверить таблицей — а эту
//   проверяет `npm run check:authz` в CI.
// - Отказ — 403 с коротким JSON: тело нужно, чтобы поломку было видно в браузере и в
//   логах, но значение чужого `Origin` в ответ не попадает (публичный лог — не место
//   для чужих данных, D-038).
// - Ответ не кэшируется: иначе прокси или браузер запомнят отказ и повторят его уже
//   законному запросу.
export default function proxy(request: NextRequest): NextResponse {
  const verdict = judgeOrigin({
    method: request.method,
    origin: request.headers.get("origin"),
    fetchSite: request.headers.get("sec-fetch-site"),
    host: request.headers.get("host"),
    production: process.env.NODE_ENV === "production",
  });

  if (verdict.allowed) {
    return NextResponse.next();
  }

  return NextResponse.json(
    { error: "origin_not_allowed", reason: verdict.reason },
    {
      status: 403,
      headers: {
        "cache-control": "no-store",
        vary: "Origin, Sec-Fetch-Site",
      },
    },
  );
}

// Чего прокси не касается: статика и ассеты. Это GET'ы, правило их и так пропускает, но
// вызов прокси на каждый файл карты — чистая плата за вход без пользы: файлов там
// сотни тысяч запросов, а `_next/static` раздаётся ещё и с `immutable`.
export const config = {
  matcher: ["/((?!_next/static|_next/image|map/|icons/|favicon.ico|icon.svg|llms.txt).*)"],
};
