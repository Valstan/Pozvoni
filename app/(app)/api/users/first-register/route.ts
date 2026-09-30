// Тень над `/api/users/first-register`: Payload 3.90.1 вешает этот эндпоинт на любую
// коллекцию с `auth` безусловно (payload/dist/auth/endpoints/index.js:59-63), а сама операция
// отказывает только когда таблица `users` НЕ пуста (registerFirstUser.js:26-33) и создаёт
// пользователя через `payload.create` с `overrideAccess: true` — то есть ни `access.create`
// (`superadmin`), ни `role.access.update` на этом пути не проверяются, а роль приходит из тела.
//
// Итог: если таблица `users` хоть раз окажется пустой, анонимный POST даёт ему учётку с
// ролью `superadmin` и живой токен в `Set-Cookie`. Пустая таблица достижима: персонал может
// удалить всех пользователей из админки, а `onInit` при следующем старте заводит супер-админа
// с паролем из публичного репозитория (payload.config.ts, комментарий там это признаёт) —
// то есть условие не выдуманное.
//
// Закрываем на уровне маршрута: статический сегмент побеждает `[...slug]` Payload (так же
// устроены все наши /api/* — /api/track и соседние живут рядом с catch-all и не мешают друг
// другу). Регенерация `app/(payload)/api/[...slug]/route.ts` файл не трогает: он лежит вне
// группы `(payload)`.
//
// Мы первым пользователем не регистрируемся: супер-админа заводит сид при пустой базе.
//
// Отвечаем голым `Response`, а не `NextResponse`: так модуль импортируется обычным node, и
// `npm run check:authz` проверяет заглушку настоящим вызовом, а не чтением её текста.

export const dynamic = "force-dynamic";

export async function POST() {
  return new Response("Not Found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}