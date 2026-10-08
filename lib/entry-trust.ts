// Бейджи доверия карточки справочника (вскрытие 2026-10-07).
//
// Правило: только выводимое из данных, ничего не выдумываем. Слов «проверено
// звонком» с датой здесь нет сознательно: для них нужно отдельное поле и
// разметка владельцем по каждой карточке. Что есть честного уже сейчас:
// свежесть правки (`updatedAt`) и официальный источник (`source` — госсайт
// или сайт сети, а не агрегатор).

/** Подстроки официальных источников: госвеб, суды, ведомства, сети. */
const OFFICIAL_MARKERS = [
  "gosweb.gosuslugi.ru",
  "sudrf.ru",
  "genproc.gov.ru",
  "kirovreg.ru",
  "mchs.gov.ru",
  ".mvd.ru",
  "гибдд",
  "gibdd",
  "apteka40kirov.ru",
  "apteka-april.ru",
  "kirovops.ru",
  "bus.gov.ru",
  "medkirov.ru",
];

/** Источник — официальный сайт, а не агрегатор. */
export function isOfficialSource(source?: string | null): boolean {
  if (!source) return false;
  const s = source.toLowerCase();
  return OFFICIAL_MARKERS.some((m) => s.includes(m));
}

const MONTHS_GEN = [
  "января",
  "февраля",
  "марта",
  "апреля",
  "мая",
  "июня",
  "июля",
  "августа",
  "сентября",
  "октября",
  "ноября",
  "декабря",
];

/**
 * «октябрь 2026» из ISO-даты. Мусор на входе — null на выходе: бейджа не будет,
 * а не враньё.
 */
export function updateMonth(iso?: string | null): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return `${MONTHS_GEN[d.getMonth()]} ${d.getFullYear()}`;
}
