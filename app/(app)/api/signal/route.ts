import { NextResponse } from "next/server";
import { crowdReady, recordAnswer, recordCall, type Outcome } from "@/lib/crowd-signals";
import { limited } from "@/lib/rate-limit";

// Краудсигналы: { action: "call" | "answer", entryId, installId, outcome?, priceMismatch? }
//
// Без сессии и без токена: сигнал анонимен по построению (спринт 5, п.5). Что удерживает
// от накрутки — первичный ключ (номер, устройство, день): сколько ни шли, строка одна.
// Что удерживает от мусора — запись должна существовать и быть опубликованной: по чужим
// и непроверенным номерам сигналов нет.

export const dynamic = "force-dynamic";

const bad = (m: string, status = 400) => NextResponse.json({ error: m }, { status });

export async function POST(request: Request) {
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return bad("Неверный запрос.");
  }

  const entryId = typeof body.entryId === "number" && Number.isInteger(body.entryId) ? body.entryId : NaN;
  const installId = typeof body.installId === "string" ? body.installId.trim() : "";
  if (!Number.isInteger(entryId) || installId.length < 16 || installId.length > 128) {
    return bad("Нужны entryId и installId.");
  }

  // ⚠️ Потолка не было вовсе, и это стоило дороже, чем кажется: каждый POST идёт в пул
  // соединений — тот же, что принимает точки записи поездок, `max: 4` (`lib/track-db.ts`).
  // Анонимный флуд здесь бьёт не по счётчику, а по приёму трасс у человека, который уже
  // едет. Ключ — ресурс, а не клиент: адресов посетителей у приложения нет намеренно.
  if (limited(`sig:${entryId}`, 30) || limited("sig:all", 600, 60 * 60_000)) {
    return bad("Слишком часто — попробуйте позже.", 429);
  }

  if (!(await crowdReady())) return bad("Сигналы пока недоступны.", 503);

  // Опубликованность проверяется теми же access-правилами, что и для всего мира.
  const { getPayload } = await import("payload");
  const { default: config } = await import("@payload-config");
  const payload = await getPayload({ config });
  const found = await payload.find({
    collection: "entries",
    where: { id: { equals: entryId } },
    limit: 1,
    overrideAccess: false,
  });
  if (found.docs.length === 0) return bad("Номер не найден.", 404);

  if (body.action === "call") {
    await recordCall(entryId, installId);
    return NextResponse.json({ ok: true });
  }

  if (body.action === "answer") {
    const outcome: Outcome =
      body.outcome === "answered" ? "answered" : body.outcome === "no_answer" ? "no_answer" : "unknown";
    await recordAnswer(entryId, installId, outcome, body.priceMismatch === true);
    return NextResponse.json({ ok: true });
  }

  return bad("Неизвестное действие.");
}
