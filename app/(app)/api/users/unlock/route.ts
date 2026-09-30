// Тень над `/api/users/unlock`. Payload вешает этот эндпоинт на любую коллекцию с `auth`
// безусловно (payload/dist/auth/endpoints/index.js:67-73), а дефолтное правило доступа
// (`defaultUnlockAccess`) смотрит только `user.collection === admin.user` — то есть пропускает
// ЛЮБУЮ сессию `users`, независимо от роли (payload/dist/auth/defaultUnlockAccess.js:1-6).
//
// Посетительская сессия бесплатна и заводится автоматически при первом входе через ЕСА, то
// есть такой посетитель мог вызвать `resetLoginAttempts` для `admin` и обнулить счётчик
// неудачных входов — единственную защиту от подбора пароля, настроенную в
// `collections/Users.ts` (`maxLoginAttempts: 10`). Ответ 200 против 403 заодно служил оракулом
// «есть ли такой логин» для перебора без всякой аутентификации.
//
// Правило `access.unlock` в коллекции — настоящий гейт; эта тень страхует от его потери и от
// регенерации Payload. Отвечаем голым `Response`, чтобы модуль импортировался обычным node
// и проверялся настоящим вызовом в `npm run check:authz`.
//
// Настоящим снятием блокировки админка не пользуется: замок и так снимается по истечении
// `lockTime`.

export const dynamic = "force-dynamic";

export async function POST() {
  return new Response("Not Found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}