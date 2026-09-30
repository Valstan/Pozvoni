import { NextResponse } from "next/server";
import { karmaReady, vote, type Vote } from "@/lib/karma";
import { limited } from "@/lib/rate-limit";
import { ORG_KEY, phoneKey } from "@/lib/phone-key";
import { phoneKeysOf } from "@/lib/comments";

// Карма: { entryId, phone?, value: 1 | -1, installId }.
//
// Без сессии и без токена — решение владельца: «пока чтобы плюсовали и минусовали без
// авторизации, чтобы начать жизнь сайта хотя бы; потом привыкнут и заставим авторизоваться».
//
// Что удерживает от накрутки вместо авторизации:
//  1. первичный ключ (запись, номер, устройство) — сколько ни жми, строка одна;
//  2. запись обязана существовать и быть опубликованной — проверяется теми же
//     access-правилами, что и для всего мира (`overrideAccess: false`), значит по чужим
//     и непроверенным номерам голосовать нельзя;
//  3. номер, которому ставят оценку, сверяется с номерами карточки: ключ приходит из
//     тела, и без сверки в таблицу писался любой ключ с цифрой, которого на карточке нет;
//  4. рейт-лимит по ресурсу и общий по сайту: адреса посетителей приложение намеренно не
//     читает, поэтому ключ — карточка, а не клиент. Против распределённой накрутки это не
//     защита, и это принято: цена ошибки здесь — неверное число на карточке, а не утечка.

export const dynamic = "force-dynamic";

const bad = (m: string, status = 400) => NextResponse.json({ error: m }, { status });

export async function POST(request: Request) {
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return bad("Неверный запрос.");
  }

  const entryId =
    typeof body.entryId === "number" && Number.isInteger(body.entryId) ? body.entryId : NaN;
  const installId = typeof body.installId === "string" ? body.installId.trim() : "";
  const phone = typeof body.phone === "string" ? body.phone : "";
  const value: Vote | null = body.value === 1 ? 1 : body.value === -1 ? -1 : null;

  if (!Number.isInteger(entryId) || installId.length < 16 || installId.length > 128) {
    return bad("Нужны entryId и installId.");
  }
  if (value === null) return bad("Голос — только +1 или −1.");
  // ⚠️ Потолок сюда, а не после проверки записи. Раньше `limited('karma:<entryId>')` стоял
  // ДО того, как мы убеждались, что карточка вообще существует, а `entryId` приходит из
  // тела: 120 запросов в минуту к произвольному целому числу выжигали лимит чужой карточки,
  // и легитимный посетитель этой карточки получал 429.
  if (limited(`karma:${entryId}`, 120) || limited("karma:all", 900, 60 * 60_000)) {
    return bad("Слишком часто — попробуйте позже.", 429);
  }
  if (!(await karmaReady())) return bad("Оценки пока недоступны.", 503);

  const { getPayload } = await import("payload");
  const { default: config } = await import("@payload-config");
  const payload = await getPayload({ config });
  const found = await payload.find({
    collection: "entries",
    where: { id: { equals: entryId } },
    limit: 1,
    depth: 0,
    overrideAccess: false,
  });
  const entry = found.docs[0];
  if (!entry) return bad("Номер не найден.", 404);

  // Ключ номера приходит из тела, а раньше только нормализовался: любую строку с цифрой
  // можно было записать в `crowd.karma` как `phone_key`, которого на карточке нет. На
  // отображение это не влияло (виджет рисуется по номерам карточки), но таблица получала
  // мусор на год — ретеншн кармы 365 дней. Теперь ключ сверяется с номерами карточки,
  // ровно как это уже сделано для комментариев (`phoneKeysOf`).
  if (phone.trim()) {
    const key = phoneKey(phone);
    if (key === ORG_KEY || !phoneKeysOf(entry.phones ?? []).includes(key)) {
      return bad("У этой карточки нет такого номера.", 409);
    }
  }

  const r = await vote(entryId, phone, installId, value);
  if (r === "bad_target") return bad("У этого поля нет номера — оценивать нечего.");
  return NextResponse.json({ ok: true, state: r === "cleared" ? 0 : value });
}
