import { sql, type MigrateUpArgs } from '@payloadcms/db-postgres'
import type { Payload } from 'payload'
import { phoneKey } from '../lib/phone-key.ts'

// Подписи номеров и бейдж «проверено звонком» — вскрытие 2026-10-07, решение
// владельца «делать прямо сейчас».
//
// Схема: `entries_phones.label` (подпись рядом с номером, видна посетителям),
// `entries.verified_at` (дата проверки звонком; бейдж «проверено звонком ·
// месяц», пусто — бейджа нет). DDL идемпотентен (`IF NOT EXISTS`), повторный
// прогон данных — no-op (подписи уже стоят, `verified_at` уже не NULL).
//
// Бэкфилл `verified_at = 2026-10-04` — только строки, опубликованные ДО партии
// 2026-10-07: они вышли под действующим гейтом «публикация только после
// проверки» (миграция `20261004_120000_publish_verified` так и называется),
// значит опубликован ⇒ проверен. Партия 2026-10-07 опубликована explicit-исключением
// без прозвона — её бэкфилл не трогает (условие по `created_at`), бейджи там
// появятся только ручной разметкой в админке.
//
// Вниз — осознанно пусто: снимать подписи и бейджи назад миграцией значило бы
// решать за владельца в обратную сторону (тот же принцип, что в publish_verified).

// Точные имена записей → ключ номера → подпись. Ключи — тем же `phoneKey`, что
// у кармы: запись номера «двумя способами» не разъедется.
const PHONE_LABELS: Readonly<Record<string, Readonly<Record<string, string>>>> = {
  'ОМВД России «Малмыжский»': { '+78334722259': 'дежурная часть' },
  'Отделение ГИБДД ОМВД России «Малмыжский»': { '+78334726408': 'ИАЗ' },
  'Военный комиссариат (Вятские Поляны, Вятскополянский и Малмыжский районы)': {
    '+78333462867': 'дежурный',
    '+78333461087': 'военком',
  },
}

type Log = (message: string) => void

async function labelKnownPhones(payload: Payload, log: Log): Promise<void> {
  let labeled = 0
  for (const [name, labels] of Object.entries(PHONE_LABELS)) {
    const found = await payload.find({
      collection: 'entries',
      where: { name: { equals: name } },
      limit: 10,
      depth: 0,
      overrideAccess: true,
    })
    if (found.docs.length === 0) {
      log(`подписи: нет записи «${name}» — пропуск`)
      continue
    }
    for (const doc of found.docs) {
      const phones = (doc.phones ?? []) as { number: string; label?: string | null }[]
      let changed = false
      const next = phones.map((p) => {
        const want = labels[phoneKey(p.number)]
        if (want && p.label !== want) {
          changed = true
          return { number: p.number, label: want }
        }
        return p.label ? { number: p.number, label: p.label } : { number: p.number }
      })
      if (!changed) {
        log(`подписи: «${name}» (#${doc.id}) — уже стоят`)
        continue
      }
      await payload.update({
        collection: 'entries',
        id: doc.id,
        data: { phones: next },
        overrideAccess: true,
      })
      labeled += 1
      log(`подписи: «${name}» (#${doc.id}) — проставлено`)
    }
  }
  log(`подписи: обновлено записей ${labeled}`)
}

export async function up({ payload, db }: MigrateUpArgs): Promise<void> {
  const log: Log = (message) => payload.logger.info(`[verified-labels] ${message}`)
  await db.execute(sql.raw('ALTER TABLE "entries" ADD COLUMN IF NOT EXISTS "verified_at" timestamp(3) with time zone'))
  await db.execute(sql.raw('ALTER TABLE "entries_phones" ADD COLUMN IF NOT EXISTS "label" varchar'))
  await labelKnownPhones(payload, log)
  await db.execute(
    sql.raw(
      `UPDATE "entries" SET "verified_at" = '2026-10-04T00:00:00+03:00' ` +
        `WHERE "status" = 'published' AND "created_at" < '2026-10-07T00:00:00+03:00' AND "verified_at" IS NULL`,
    ),
  )
  log('бэкфилл verified_at=2026-10-04 для опубликованных до партии 2026-10-07 — выполнен')
}

export async function down(): Promise<void> {
  // Осознанно пусто (см. шапку).
}
