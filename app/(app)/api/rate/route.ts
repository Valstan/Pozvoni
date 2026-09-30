import { NextResponse } from "next/server";
import { rate, ratingsReady } from "@/lib/ratings";
import { limited } from "@/lib/rate-limit";
import { isOwnCard } from "@/lib/rating-self-vote";

// Звёзды бизнесу или его работнику (спринт 9). Тело: { entryId, workerId?, stars, installId }.
// Анонимно — решение владельца 2026-09-10; один голос на устройство в день — первичный ключ.
// Только карточкам с владельцем: у кого нет кабинета, у того нет и рейтинга. И владелец не
// оценивает себя (см. `lib/rating-self-vote.ts`).

export const dynamic = "force-dynamic";
const bad = (m: string, status = 400) => NextResponse.json({ error: m }, { status });

export async function POST(request: Request) {
  let body: Record<string, unknown>;
  try { body = (await request.json()) as Record<string, unknown>; } catch { return bad("Неверный запрос."); }
  const entryId = typeof body.entryId === "number" && Number.isInteger(body.entryId) ? body.entryId : NaN;
  const workerId = typeof body.workerId === "number" && Number.isInteger(body.workerId) && body.workerId > 0 ? body.workerId : 0;
  const stars = typeof body.stars === "number" ? body.stars : NaN;
  const installId = typeof body.installId === "string" ? body.installId.trim() : "";
  if (!Number.isInteger(entryId) || installId.length < 16 || installId.length > 128) return bad("Нужны entryId и installId.");

  // Потолка не было: каждый POST идёт в пул соединений, общий с приёмом трасс. Ключ —
  // ресурс, а не клиент (адресов посетителей приложение намеренно не читает).
  if (limited(`rate:${entryId}`, 30) || limited("rate:all", 300, 60 * 60_000)) {
    return bad("Слишком часто — попробуйте позже.", 429);
  }

  if (!(await ratingsReady())) return bad("Оценки пока недоступны.", 503);

  const { getPayload } = await import("payload");
  const { default: config } = await import("@payload-config");
  const payload = await getPayload({ config });
  const found = await payload.find({ collection: "entries", where: { id: { equals: entryId } }, limit: 1, depth: 0, overrideAccess: false });
  const entry = found.docs[0];
  if (!entry) return bad("Номер не найден.", 404);
  if (!entry.owner) return bad("Оценивать можно только бизнес с кабинетом.", 409);

  // Конфликт интересов: владелец не оценивает себя. Раньше эндпоинт сессию не читал вовсе,
  // поэтому владелец, вошедший в «ПОЗВОНИ», ставил звёзды своему же бизнесу и своим же
  // работникам — а это единственный случай, где оценка заведомо не о чужом опыте.
  //
  // Читаем сессию только здесь и только чтобы спросить одно поле. Стоимость — одна проверка
  // подписи куки; посторонний (без куки) платит ноль, и это правильно: он голосует как и раньше.
  // Ошибка разбора куки означает «сессии нет» — анонимный голосование не отменяет, и новой
  // дыры тут не появляется: анонимный голос и раньше был разрешён.
  let sessionUserId: unknown = null;
  try {
    const { user } = await payload.auth({ headers: request.headers });
    sessionUserId = (user as { id?: unknown } | null)?.id ?? null;
  } catch {
    sessionUserId = null;
  }
  if (isOwnCard(entry.owner, sessionUserId)) {
    return bad("Свою карточку и своих работников оценить нельзя.", 409);
  }

  const r = await rate(entryId, workerId, installId, stars);
  if (r === "bad_stars") return bad("Звёзды — от 1 до 5.");
  if (r === "no_worker") return bad("Такого работника нет.", 404);
  return NextResponse.json({ ok: true });
}
