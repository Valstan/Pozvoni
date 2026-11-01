// Проверка происхождения небезопасного запроса — то, чего у нас не было.
//
// Почему свой разбор, а не `csrf` в `payload.config.ts`: в Payload 3.90 `csrf`/`cors`
// только НАПОЛНЯЮТ список доверенных origin'ов, а список читает `getRequestOrigin`,
// которым строят абсолютные адреса. Проверки `Origin` в cookie-аутентифицированных
// роутах нет ни одной — это прочитано по
// `node_modules/payload/dist/utilities/getRequestOrigin.js`, записано в
// `docs/WRITE_AUTHZ.md`. То есть `csrf: [...]` создал бы видимость защиты, не добавив
// ни одной строки отказа.
//
// Что защищаем. Сессионная кука host-bound (`__Host-`), поэтому сосед по
// `вмалмыже.рф` не может её подсунуть. Но `SameSite=Lax` ЕГО НЕ ОСТАНАВЛИВАЕТ в другую
// сторону: сосед — same-site, и браузер приложит нашу куку к запросу, который сочинила
// чужая страница (форма или fetch). Кука при этом уйдёт вместе с запросом, и роут
// выполнится от имени вошедшего человека. Отличает такой запрос только `Origin`.
//
// Правила (нарочно узкие):
//
// 1. `GET`/`HEAD`/`OPTIONS` не проверяем: они не меняют состояние, а проверка на них
//    ломала бы переходы по ссылкам и загрузку картинок.
// 2. `Origin` нет — пропускаем. Так ходят curl, проба и смоук (у них нет ни `Origin`,
//    ни `Sec-Fetch-Site`), и так же вёл себя старый браузер, который `Origin` на
//    same-origin POST не слал. Но если браузер прислал `Sec-Fetch-Site: cross-site`
//    или `same-site` БЕЗ `Origin` — это уже не «старый браузер», а чужая страница;
//    отказываем.
// 3. `Origin` есть — пускаем, только если он наш:
//    - совпадает с `Host` запроса (same-origin: так ходят все наши формы и fetch'и,
//      включая dev на `localhost:<порт>` и админку);
//    - или это один из живых домов реестра `lib/sites.ts` (переход между лицами
//      матрёшки — свои же: `позвони.` и `такси.` — один продукт и один владелец);
//    - или, вне прода, loopback любого порта (dev: страница на `127.0.0.1`, а запрос
//      на `localhost` — для браузера это разные origin'ы, для разработчика одно и то же).
//    Всё остальное — отказ, включая литерал `null` (его присылает sandbox-iframe:
//    origin есть, доверия нет, и без явной ветки он бы не совпал ни с чем и «повис»).

// Расширение `.ts` намеренное: этот модуль запускает не только Next, но и обычный node из
// `scripts/check-authz.mjs` (там правило гоняется таблицей случаев), а без расширения node
// модуль не найдёт. Тот же приём и та же причина, что у `lib/track-*` (`tsconfig.json`).
import { SITES } from "./sites.ts";

/** Методы, которые не меняют состояние. `OPTIONS` — предварительный CORS-запрос. */
const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/**
 * Origin'ы живых лиц продукта. Не `live: false`: у тех домена нет ни в DNS, ни в
 * сертификате, браузер туда не попадёт, и разрешать их значило бы разрешать адрес,
 * которого в природе не существует. Домен завели — значит в реестре `live: true`, и
 * он попадает сюда сам.
 */
const LIVE_ORIGINS = new Set(
  SITES.filter((site) => site.live).map((site) => `https://${site.host}`.toLowerCase()),
);

const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]"]);

export interface OriginCheckInput {
  /** Метод запроса как есть; регистр приводим сами. */
  method: string;
  /** Заголовок `Origin` (браузер) или `null`, если его нет. */
  origin: string | null;
  /** Заголовок `Sec-Fetch-Site`, если браузер его прислал: modern-браузеры всегда. */
  fetchSite: string | null;
  /** Заголовок `Host`: адрес, по которому пришёл запрос. */
  host: string | null;
  /** `NODE_ENV === "production"`: в dev доменов реестра в браузере нет. */
  production: boolean;
}

export type OriginVerdict =
  | { allowed: true; reason: "safe-method" | "same-origin" | "sibling-site" | "no-origin" | "dev-loopback" }
  | { allowed: false; reason: "foreign-origin" | "foreign-site" | "opaque-origin" | "bad-origin" };

/**
 * Пускать ли запрос. Чистая функция без побочных эффектов: её гоняет
 * `npm run check:authz` на таблице случаев, а `proxy.ts` — на живом трафике. Одна
 * реализация на оба применения, чтобы проверка не разъехалась с поведением.
 */
export function judgeOrigin(input: OriginCheckInput): OriginVerdict {
  if (SAFE_METHODS.has(input.method.toUpperCase())) {
    return { allowed: true, reason: "safe-method" };
  }

  const fetchSite = input.fetchSite?.toLowerCase() ?? null;
  const origin = input.origin;

  if (origin === null || origin === "") {
    if (fetchSite === "cross-site" || fetchSite === "same-site") {
      return { allowed: false, reason: "foreign-site" };
    }
    return { allowed: true, reason: "no-origin" };
  }

  // `Origin: null` — sandbox-iframe или `file://`. Заголовок есть, источника нет.
  if (origin.toLowerCase() === "null") {
    return { allowed: false, reason: "opaque-origin" };
  }

  let parsed: URL;
  try {
    parsed = new URL(origin);
  } catch {
    return { allowed: false, reason: "bad-origin" };
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    return { allowed: false, reason: "bad-origin" };
  }

  const host = input.host?.toLowerCase() ?? "";
  if (host !== "" && parsed.host.toLowerCase() === host) {
    return { allowed: true, reason: "same-origin" };
  }

  if (LIVE_ORIGINS.has(`${parsed.protocol}//${parsed.host}`.toLowerCase())) {
    return { allowed: true, reason: "sibling-site" };
  }

  if (!input.production && LOOPBACK.has(parsed.hostname.toLowerCase())) {
    return { allowed: true, reason: "dev-loopback" };
  }

  return { allowed: false, reason: "foreign-origin" };
}
