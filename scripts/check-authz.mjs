// Инварианты прав доступа, которые не доказываются схемой: их проверяет вызовом
// настоящей функции-предиката, а не чтением её текста.
//
// Почему отдельным файлом, а не ещё одной секцией `check-track.mjs`: там нужен живой
// PostgreSQL, а эти проверки — чистые функции на подставном `req`. Плюс по #125 гейт должен
// быть в CI, и `ci.yml` зовёт `check:authz` отдельно: предикат доступа может сломаться
// без единой миграции.
//
// Запуск: npm run check:authz   (базы не нужно)

import { readFileSync } from "node:fs";
import { esaLinkAllowed } from "../lib/esa-link-rule.ts";
import { Users } from "../collections/Users.ts";
import { limited, rateLimitSize } from "../lib/rate-limit.ts";
import { isOwnCard } from "../lib/rating-self-vote.ts";
import { judgeOrigin } from "../lib/request-origin.ts";
import { SITES } from "../lib/sites.ts";

let failed = 0;
const ok = (m) => console.log(`✓ ${m}`);
const fail = (m) => { console.error(`✗ ${m}`); failed++; };
const eq = (a, b, m) => (a === b ? ok(`${m}: ${a}`) : fail(`${m}: получено ${a}, ожидалось ${b}`));

// ── 1. Привязка единого входа — только персоналу ────────────────────────────────────────
// Гейт стоит в двух местах (start выбирает режим, callback доигрывает ветку link), и
// обе реализации обязаны спрашивать одно и то же правило. Проверяем правило и обе роли.

eq(esaLinkAllowed("superadmin"), true, "link: персоналу можно");
eq(esaLinkAllowed("user"), false, "link: посетителю нельзя");
eq(esaLinkAllowed(undefined), false, "link: без роли нельзя");
eq(esaLinkAllowed(null), false, "link: null не роль");

// ── 2. Последнего супер-админа удалить нельзя ───────────────────────────────────────────
// Причина не «так аккуратнее»: пустая `users` — единственное условие, при котором
// анонимный `POST /api/users/first-register` создаёт учётку с ролью superadmin, а сид при
// пустой базе заводит admin/admin из публичного репозитория.

const del = Users.access?.delete;
if (typeof del !== "function") {
  fail("users.access.delete — не функция");
} else {
  const staffTotal = (n) => ({ totalDocs: n });
  const asRole = (role) => ({ role });

  eq(await del({ req: { user: asRole("user"), payload: { count: async () => staffTotal(5) } } }),
    false, "удаление: посетителю нельзя при любом числе сотрудников");
  eq(await del({ req: { user: null, payload: { count: async () => staffTotal(5) } } }),
    false, "удаление: гостю нельзя");
  eq(await del({ req: { user: asRole("superadmin"), payload: { count: async () => staffTotal(1) } } }),
    false, "удаление: последнего супер-админа нельзя");
  eq(await del({ req: { user: asRole("superadmin"), payload: { count: async () => staffTotal(2) } } }),
    true, "удаление: при двух супер-админах можно");

  // `count` бросил — отказ, а не пропуск: обратное значение здесь стоило бы учётки.
  eq(await del({ req: { user: asRole("superadmin"), payload: { count: async () => { throw new Error("db"); } } } }),
    false, "удаление: падение count даёт отказ, а не разрешение");
}

// ── 3. `first-register` недостижим ──────────────────────────────────────────────────────
// Payload вешает эндпоинт на любую коллекцию с `auth` безусловно; закрыт он тенью —
// статическим сегментом, который побеждает `[...slug]`. Проверяем, что тень на месте и
// действительно отвечает 404 (импорт роута — такой же вызов, какой делает Next).

for (const [slug, what] of [["first-register", "регистрация первого пользователя"],
  ["unlock", "снятие блокировки входа"]]) {
  try {
    const mod = await import(`../app/(app)/api/users/${slug}/route.ts`);
    const res = await mod.POST();
    eq(res.status, 404, `${slug}: тень отвечает 404 (${what})`);
  } catch (e) {
    fail(`${slug}: роут не импортируется или падает: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// ── 4. `unlock` — только персоналу ─────────────────────────────────────────────────────
// Без этого правила Payload подставляет `defaultUnlockAccess`: он смотрит только
// `user.collection === admin.user`, то есть пропускает ЛЮБУЮ сессию `users`. Посетительская
// сессия бесплатна, а снятие блокировки обнуляет счётчик неудачных входов супер-админа —
// то есть снимает единственную защиту от подбора пароля.

const unlock = Users.access?.unlock;
if (typeof unlock !== "function") {
  fail("users.access.unlock — не задан (Payload подставит defaultUnlockAccess: любая сессия users)");
} else {
  eq(await unlock({ req: { user: { role: "superadmin", collection: "users" } } }),
    true, "unlock: персоналу можно");
  eq(await unlock({ req: { user: { role: "user", collection: "users" } } }),
    false, "unlock: посетителю нельзя даже при своей коллекции");
  eq(await unlock({ req: { user: { collection: "users" } } }),
    false, "unlock: без роли нельзя");
  eq(await unlock({ req: { user: null } }),
    false, "unlock: гостю нельзя");
}

// ── 5. Сборка действительно отдаёт эти пути нашим роутам ────────────────────────────────
// Проверка выше зовёт обработчик, но не отвечает на вопрос «кому принадлежит маршрут».
// Ответ — в манифесте сборки: пока статический сегмент побеждает `[...slug]` Payload, рядом
// с ним лежит и наш путь. Потерять его можно не только правкой кода: регенерация Payload
// перезаписывает `app/(payload)/api/[...slug]/route.ts`, и ошибка была бы молчаливой.
//
// ⚠️ На прод этот путь НЕ проверяется пробой: проверка означала бы POST на эндпоинт, который
// при пустой таблице `users` создал бы супер-админа. Проверка живёт в сборке — там тот же
// риск отсутствует, потому что никто не отвечает за POST.
const manifest = readFileSync(".next/server/app-paths-manifest.json", "utf8");
// Ключи манифеста — с путями групп: `/(app)/api/…/route`, регекспомендования `payload`
// лежат в `/route`. URL получается вырезанием группы и суффикса.
const own = new Set(
  Object.keys(JSON.parse(manifest)).map((k) => k.replace(/^\/[^/]*(?=\/)/, "").replace(/\/route$/, "")),
);
for (const p of ["/api/users/first-register", "/api/users/unlock"]) {
  eq(own.has(p), true, `сборка: ${p} принадлежит нашему роуту, а не catch-all Payload`);
}
eq(own.has("/api/[...slug]"), true, "сборка: catch-all Payload на месте (остальное API не сломано)");

// ── 6. Потолок нельзя обнулить массой чужих ключей ──────────────────────────────────────
// Раньше при переполнении памяти карта счётчиков очищалась ЦЕЛИКОМ, и атакующий, чередуя
// ~5000 ключей, которые задаёт сам (`cmt-act:<commentId>` — целое число), обнулял лимиты
// всех ресурсов разом: поездок, ссылок, комментариев.
//
// ⚠️ Что именно здесь проверяется, а что НЕ проверяется — сказано прямо, потому что
// разница неочевидна. Проверяются два достижимых свойства:
//
//   1. счётчик, к которому обращаются ПОСЛЕ начала флуда, переживает флуд (при `clear()`
//      он обнулялся — это и была дыра);
//   2. память ограничена: после шести тысяч чужих ключей их не шесть тысяч в карте.
//
// НЕ проверяется (и не обещается): что счётчик, заведённый ДО флуда, выживет. В карте
// конечного размера он вытесняется первым — по времени последнего обращения он самый
// старый. Обещать иначе значило бы врать: при настоящем флуде защиту держат общие
// потолки на фиксированных ключах (`cmt:all`, `karma:all`, `sig:all`, `rate:all`) — их
// handful, они не вытесняются и переживают всё.

{
  const t0 = 1_000_000;
  const sizeBefore = rateLimitSize();

  // Потолок, который должны выбить.
  for (let i = 0; i < 3; i++) eq(limited("жертва-старая", 3, 60_000, t0), false, `потолок: наполнение ${i + 1}/3`);
  eq(limited("жертва-старая", 3, 60_000, t0), true, "потолок: счётчик сработал");

  // Флуд по тысячам чужих ключей — то, чем лимиты обнуляли раньше.
  for (let i = 0; i < 6000; i++) limited(`мусор:${i}`, 1, 60_000, t0 + i);
  eq(rateLimitSize() - sizeBefore <= 5000 + 1, true,
    `потолок: память ограничена (${rateLimitSize() - sizeBefore} ключей на 6000 запросов)`);

  // Счётчик, которого коснулись ПОСЛЕ флуда, обязан выстоять.
  eq(limited("жертва-свежая", 1, 60_000, t0 + 9000), false, "потолок: свежий ключ считается");
  eq(limited("жертва-свежая", 1, 60_000, t0 + 9000), true,
    "потолок: чужой флуд не обнулил счётчик, взятый после него");
}

// ── 7. Владелец не оценивает свою карточку ──────────────────────────────────────────────
// Правило одно на две формы значения `owner` (число при depth: 0 и объект отношения при
// большей глубине) и на четыре формы id сессии. Что НЕ закрыто — см. lib/rating-self-vote.ts:
// вышедший из аккаунта владелец остаётся анонимным, и это решение владельца про анонимные
// голоса, а не изъян гейта.

{
  const S = "Позвони";
  eq(isOwnCard(7, 7), true, "звёзды: владелец не оценивает себя");
  eq(isOwnCard(7, "7"), true, "звёзды: id сессии строкой — тот же человек");
  eq(isOwnCard(7, { id: 7 }), true, "звёзды: отношение объектом — тот же человек");
  eq(isOwnCard({ id: 7 }, 7), true, "звёзды: владелец объектом — тот же человек");
  eq(isOwnCard(7, 8), false, "звёзды: постороннему можно");
  eq(isOwnCard(7, null), false, "звёзды: анонимному можно (решение владельца)");
  eq(isOwnCard(7, undefined), false, "звёзды: без сессии — не самооценка");
  eq(isOwnCard(null, 7), false, "звёзды: без владельца решает гейт кабинета, а не это правило");
  eq(isOwnCard(7, {}), false, "звёзды: пустой id сессии — не самооценка");
}

// ── 8. Чужая страница не пишет от имени вошедшего ───────────────────────────────────────
// Та же беда, что с предикатами выше: правило, размазанное по прокси, не проверить
// таблицей. Поэтому `judgeOrigin` — чистая функция, а здесь её гоняют случаями. Главный из
// них — сосед по `вмалмыже.рф`: его `Origin` не наш, и запрос обязан получить отказ, хотя
// кука браузером будет приложена (он same-site).
//
// Что НЕ проверяется: реальное поведение браузера (приложит ли он куку и `Origin`) — это
// измеряется живой попыткой, а не таблицей. Здесь проверяется наше решение.

{
  const live = SITES.filter((s) => s.live);
  const root = live[0];
  const sibling = live[1];
  const planned = SITES.find((s) => !s.live);
  const zone = root.host.split(".").slice(-2).join(".");
  const base = { method: "POST", fetchSite: null, host: root.host, production: true };

  eq(judgeOrigin({ ...base, method: "GET", origin: `https://evil.${zone}` }).allowed, true,
    "origin: чтение не проверяем (иначе встанут переходы)");
  eq(judgeOrigin({ ...base, method: "HEAD", origin: `https://evil.${zone}` }).allowed, true,
    "origin: HEAD не проверяем");
  eq(judgeOrigin({ ...base, origin: null }).allowed, true,
    "origin: без Origin и без Sec-Fetch-Site пускаем (curl, проба, смоук)");
  eq(judgeOrigin({ ...base, origin: null, fetchSite: "same-origin" }).allowed, true,
    "origin: старый браузер без Origin, но сам сказал same-origin — пускаем");
  eq(judgeOrigin({ ...base, origin: null, fetchSite: "cross-site" }).allowed, false,
    "origin: без Origin, но браузер сказал cross-site — отказ");
  eq(judgeOrigin({ ...base, origin: null, fetchSite: "same-site" }).allowed, false,
    "origin: без Origin, но браузер сказал same-site — отказ");

  eq(judgeOrigin({ ...base, origin: `https://${root.host}` }).allowed, true,
    "origin: свой же адрес — same-origin");
  eq(judgeOrigin({ ...base, origin: `https://${root.host.toUpperCase()}` }).allowed, true,
    "origin: регистр в Origin не обманывает сравнение");
  eq(judgeOrigin({ ...base, origin: `http://localhost:3000`, host: `localhost:3000` }).allowed, true,
    "origin: dev на localhost — same-origin по Host");

  if (sibling) {
    eq(judgeOrigin({ ...base, origin: `https://${sibling.host}` }).allowed, true,
      "origin: соседнее живое лицо матрёшки — свои");
  }
  if (planned) {
    eq(judgeOrigin({ ...base, origin: `https://${planned.host}` }).allowed, false,
      "origin: домен из реестра, но не живой — отказ (нет ни DNS, ни сертификата)");
  }

  eq(judgeOrigin({ ...base, origin: `https://sabantuy.${zone}` }).allowed, false,
    "origin: сосед по зоне (same-site, кука уйдёт) — отказ");
  eq(judgeOrigin({ ...base, origin: `https://${root.host.replace(/^[^.]+\./, "злой.")}` }).allowed, false,
    "origin: чужое лицо зоны — отказ");
  eq(judgeOrigin({ ...base, origin: "null" }).allowed, false,
    "origin: `null` из sandbox-iframe — отказ");
  eq(judgeOrigin({ ...base, origin: "не-url" }).allowed, false,
    "origin: неразбираемый Origin — отказ");
  eq(judgeOrigin({ ...base, origin: "file:///etc/passwd" }).allowed, false,
    "origin: не-http схема — отказ");

  eq(judgeOrigin({ ...base, production: false, origin: "http://localhost:3001", host: "127.0.0.1:3000" }).allowed,
    true, "origin: dev — loopback любого порта");
  eq(judgeOrigin({ ...base, production: true, origin: "http://localhost:3001", host: "127.0.0.1:3000" }).allowed,
    false, "origin: на проде loopback не своё");
}

if (failed > 0) {
  console.error(`\nпроверка прав доступа: ${failed} провалов`);
  process.exit(1);
}
console.log("\nинварианты прав доступа держатся");