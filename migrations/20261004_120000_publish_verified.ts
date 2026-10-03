import type { MigrateUpArgs, MigrateDownArgs } from '@payloadcms/db-postgres'
import type { Payload } from 'payload'
import type { Entry } from '../payload-types.ts'
import { phoneKey } from '../lib/phone-key.ts'
import { nameKey } from '../lib/org-search.ts'

// Публикация проверенных черновиков и слияние дублей — решение владельца 2026-10-04
// («проверено, публикуй как есть»; «Фаворитов» объединить в одну организацию такси;
// «Ветер» и «Круиз» — одна организация, одно название видимо устаревшее).
//
// Почему миграцией, а не кликами в админке: решение одно на полсотни записей, и оно
// обязано остаться в истории репозитория, а не в памяти. Область строго ограничена
// явными списками имён ниже: будущие черновики этот прогон не тронет (их в списках
// нет), повторный прогон — no-op (статусы уже не draft, дубли уже слиты).
// Вниз — осознанно пусто: слияние необратимо, а снимать публикацию назад миграцией
// значило бы решать за владельца в обратную сторону.

// 55 имён из seed/directory-draft.ts на 2026-10-04. Записи, опубликованные раньше,
// сюда не попали бы и так (условие — только status draft).
const PUBLISH_NAMES: readonly string[] = [
  'Такси «Фортуна»',
  'Такси «Гермес»',
  '«Любимое такси»',
  'Такси «Ветер»',
  'Такси «Круиз»',
  'Яндекс Такси (федеральный)',
  'Межгород Малмыж—Казань',
  'Межгород (диспетчерская, круглосуточно)',
  'Пятёрочка',
  'Магнит Косметик',
  'СтройМаркет «Добреев»',
  'СтройБаза «Добреев»',
  'Магазин «Крепёж»',
  'Магазин «Интерьер»',
  '«Левша»',
  'Магазин «Победа»',
  'Магазин райпо',
  '«Всё для вас» (ИП Юнусова)',
  'Магазин «Малышок»',
  '«Добреев Техно»',
  'ИП Асхатзянов',
  'Малмыжский РЭС',
  'АО «Малмыжский ремзавод»',
  'МегаФон',
  'Администрация Малмыжского района',
  'Администрация Малмыжского городского поселения',
  'Администрация Арыкского сельского поселения',
  'Администрация Савальского сельского поселения',
  'Администрация Калининского сельского поселения',
  'Администрация Мари-Малмыжского сельского поселения',
  'Администрация Аджимского сельского поселения',
  'Администрация Константиновского сельского поселения',
  'КОГБУЗ Малмыжская ЦРБ',
  'Психиатрическая больница',
  'Средняя школа № 2',
  'Средняя школа с. Калинино',
  'Средняя школа с. Аджим',
  'Основная школа с. Каксинвай',
  'Средняя школа с. Константиновка',
  'Средняя школа с. Старый Ирюк',
  'Начальная школа д. Малый Китяк',
  'МФЦ «Мои документы» (Савали)',
  'МФЦ «Мои документы» (Калинино)',
  'МФЦ «Мои документы» (Новая Смаиль)',
  'Социальный фонд России',
  'Отделение почты (Калинино, 612927)',
  'Отделение почты (Малмыж, 612921)',
  'Отделение почты (Савали, 612940)',
  'Единый номер экстренных служб',
  'АптекаПлюс',
  'Планета здоровья',
  'Бережная аптека',
  'Аптека «Здоровье»',
  'Аптека «Михайлов»',
  'Сбербанк',
]

type Log = (message: string) => void

async function publishVerified(payload: Payload, log: Log): Promise<void> {
  let published = 0
  let missing = 0
  for (const name of PUBLISH_NAMES) {
    const found = await payload.find({
      collection: 'entries',
      where: { name: { equals: name } },
      limit: 10,
      depth: 0,
      overrideAccess: true,
    })
    if (found.docs.length === 0) {
      log(`публикация: нет записи «${name}» — пропуск`)
      missing += 1
      continue
    }
    for (const doc of found.docs) {
      if (doc.status === 'draft') {
        await payload.update({
          collection: 'entries',
          id: doc.id,
          data: { status: 'published' },
          overrideAccess: true,
        })
        published += 1
      }
    }
  }
  log(`публикация: опубликовано ${published}, имён без записи ${missing}`)
}

// Слияние записей-дублей в одну: первая в списке выживает, остальные уходят в rejected
// с пометкой (история сохраняется, наружу ничего не выходит). Телефоны объединяются
// (дедуп по phoneKey — тому же ключу, что у кармы и очереди правок).
// Карма/сигналы/комментарии висят на entry_id без внешних ключей — строки осиротевших
// id тихо гаснут в существующих механиках (очередь переживает удаление записи).
async function mergeRecords(
  payload: Payload,
  ordered: Entry[],
  survivorNote: string,
  log: Log,
): Promise<void> {
  if (ordered.length < 2) {
    log(`слияние: записей ${ordered.length} — пропуск`)
    return
  }
  const [survivor, ...rest] = ordered
  const seen = new Set((survivor.phones ?? []).map((p) => phoneKey(p.number)))
  const extra: { number: string }[] = []
  for (const doc of rest) {
    for (const phone of doc.phones ?? []) {
      if (!seen.has(phoneKey(phone.number))) {
        seen.add(phoneKey(phone.number))
        extra.push({ number: phone.number })
      }
    }
  }
  const mergedNames = rest.map((d) => `«${d.name}»`).join(', ')
  await payload.update({
    collection: 'entries',
    id: survivor.id,
    data: {
      phones: [...(survivor.phones ?? []).map((p) => ({ number: p.number })), ...extra],
      note: [survivor.note, `${survivorNote} Присоединены номера из записей-дублей: ${mergedNames}.`]
        .filter(Boolean)
        .join('\n'),
    },
    overrideAccess: true,
  })
  for (const doc of rest) {
    await payload.update({
      collection: 'entries',
      id: doc.id,
      data: {
        status: 'rejected',
        note: `Дубль: номера присоединены к записи #${survivor.id} («${survivor.name}»).`,
      },
      overrideAccess: true,
    })
  }
  log(`слияние: выжила #${survivor.id} («${survivor.name}»), погашены ${rest.map((d) => `#${d.id}`).join(', ')}`)
}

// «Фавориты»: строго один узкий ключ (nameKey: регистр, «ё», кавычки, пробелы).
// Посторонний «Фаворит-цветы» под слияние не попадёт — у него ключ другой.
async function mergeFavorits(payload: Payload, log: Log): Promise<void> {
  const found = await payload.find({
    collection: 'entries',
    where: { name: { contains: 'аворит' } },
    limit: 50,
    depth: 0,
    overrideAccess: true,
  })
  const dups = found.docs.filter((d) => nameKey(d.name) === 'фаворит')
  const others = found.docs.filter((d) => nameKey(d.name) !== 'фаворит')
  for (const d of others) log(`«Фаворит»: «${d.name}» (#${d.id}) — ключ другой, не трогаю`)
  await mergeRecords(
    payload,
    [...dups].sort((a, b) => a.id - b.id),
    '«Фаворит»: две записи — одна служба (объединено по решению владельца 2026-10-04).',
    log,
  )
}

// «Ветер» + «Круиз»: явная пара по точным именам (ключи разные — contains не годится).
// Выживает «Ветер»; какое название устаревшее — в пометке без выбора стороны.
async function mergeVeterKruiz(payload: Payload, log: Log): Promise<void> {
  const docs: Entry[] = []
  for (const name of ['Такси «Ветер»', 'Такси «Круиз»']) {
    const found = await payload.find({
      collection: 'entries',
      where: { name: { equals: name } },
      limit: 10,
      depth: 0,
      overrideAccess: true,
    })
    docs.push(...found.docs)
  }
  if (docs.length < 2) {
    log(`«Ветер»+«Круиз»: записей ${docs.length} — пропуск`)
    return
  }
  const veter = docs.find((d) => d.name === 'Такси «Ветер»') ?? [...docs].sort((a, b) => a.id - b.id)[0]
  await mergeRecords(
    payload,
    [veter, ...docs.filter((d) => d.id !== veter.id)],
    'Служба также известна как «Круиз»; одно из названий, видимо, устаревшее (объединено по решению владельца 2026-10-04).',
    log,
  )
}

export async function up({ payload }: MigrateUpArgs): Promise<void> {
  const log: Log = (message) => payload.logger.info(`[publish-verified] ${message}`)
  await publishVerified(payload, log)
  await mergeFavorits(payload, log)
  await mergeVeterKruiz(payload, log)
}

export async function down(): Promise<void> {
  // Осознанно пусто (см. шапку): слияние необратимо, публикацию назад не снимаем.
}
