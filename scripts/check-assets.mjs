// Проверка, что карта и адресный справочник на месте и не пустые.
//
// Зачем отдельным шагом: сборка проходит и без них — Next не знает, что
// `public/map/malmyzh.pmtiles` кому-то нужен. Отсутствие файла всплыло бы уже
// у пользователя серым прямоугольником вместо карты, а поиск отвечал бы
// «в Малмыже такого адреса нет» на любой запрос.
//
// Проверяются свойства, а не просто существование: заголовок PMTiles, диапазон
// зумов, непустой корпус адресов и четыре улицы приречной части — те самые,
// что выпадали из ошибочного bbox первой редакции M0.B (§5).

import { readFile, stat } from "node:fs/promises";

const CONTROL_STREETS = [
  "Прибрежная улица",
  "Пристанская улица",
  "Флотская улица",
  "Тихий переулок",
];

let failed = false;

function fail(message) {
  console.error(`✗ ${message}`);
  failed = true;
}

function ok(message) {
  console.log(`✓ ${message}`);
}

// --- вырезка карты

try {
  const path = "public/map/malmyzh.pmtiles";
  const info = await stat(path);
  const head = (await readFile(path)).subarray(0, 127);

  if (head.subarray(0, 7).toString("latin1") !== "PMTiles" || head[7] !== 3) {
    fail(`${path}: не архив PMTiles v3`);
  } else if (info.size < 256 * 1024) {
    fail(`${path}: подозрительно мал — ${info.size} Б`);
  } else {
    ok(`карта: ${(info.size / 1024 ** 2).toFixed(2)} МиБ, зумы ${head[100]}..${head[101]}`);
  }
} catch (e) {
  fail(`вырезка карты не читается: ${e.message}`);
}

// --- шрифты и спрайты: без них карта рисуется без подписей

for (const path of [
  "public/map/fonts/Noto Sans Regular/1024-1279.pbf",
  "public/map/sprites/light.json",
]) {
  try {
    const info = await stat(path);
    if (info.size === 0) fail(`${path}: пустой файл`);
    else ok(`ассет на месте: ${path}`);
  } catch {
    fail(`нет файла ${path} — карта останется без подписей или значков`);
  }
}

// --- воркер MapLibre: без него карта серая, и молча

try {
  const { createRequire } = await import("node:module");
  const { version } = createRequire(import.meta.url)("maplibre-gl/package.json");
  const dir = `public/map/maplibre/${version}`;

  // Проверяются оба файла: воркер импортирует shared относительным путём, и
  // отсутствие второго ломает так же тихо, как отсутствие первого — воркер
  // умирает внутри себя, главный поток об этом не узнаёт, карта остаётся серой
  // без единой ошибки в консоли. Ровно это и случилось 2026-08-30.
  for (const name of ["maplibre-gl-worker.mjs", "maplibre-gl-shared.mjs"]) {
    const info = await stat(`${dir}/${name}`);
    if (info.size === 0) fail(`${dir}/${name}: пустой файл`);
  }
  ok(`воркер MapLibre на месте: ${dir}`);
} catch (e) {
  fail(`воркер MapLibre не на месте (${e.message}) — карта будет серой`);
}

// --- адресный справочник

try {
  const index = JSON.parse(await readFile("data/addresses.json", "utf8"));
  const names = new Set(index.streets.map((s) => s.name));
  const missing = CONTROL_STREETS.filter((s) => !names.has(s));

  if (index.addresses.length < 1500) {
    fail(`адресов всего ${index.addresses.length} — корпус собран неверно`);
  } else if (missing.length > 0) {
    fail(`нет улиц приречной части: ${missing.join(", ")} — bbox снова срезал город`);
  } else {
    ok(`справочник: улиц ${index.streets.length}, адресов ${index.addresses.length}`);
  }
} catch (e) {
  fail(`адресный справочник не читается: ${e.message}`);
}

// --- счётчик Метрики: две копии одной константы обязаны совпадать
//
// Хост счётчика записан ДВАЖДЫ: в `lib/metrika.ts` (его читает код страницы) и в
// `next.config.mjs` (его читает сборщик, обычным node, и `lib/*.ts` ему недоступен — тот
// же случай, что с DEFAULT_ISSUER). Разъедутся — CSP запретит ровно тот хост, который
// страница грузит, счётчик умрёт молча, а «визитов нет» неотличимо от «людей нет».

try {
  const lib = await readFile("lib/metrika.ts", "utf8");
  const cfg = await readFile("next.config.mjs", "utf8");
  // Без регулярного выражения намеренно: одна константа, одно место, точное совпадение.
  const from = (src, name) => {
    const at = src.indexOf(name + ' = "');
    if (at === -1) return null;
    const from0 = at + name.length + 4;
    const to = src.indexOf('"', from0);
    return to === -1 ? null : src.slice(from0, to);
  };
  const a = from(lib, "METRIKA_HOST");
  const b = from(cfg, "METRIKA_HOST");

  if (!a || !b) {
    fail(`METRIKA_HOST не найден: lib/metrika.ts=${a ?? "нет"}, next.config.mjs=${b ?? "нет"}`);
  } else if (a !== b) {
    fail(`METRIKA_HOST разъехался: lib/metrika.ts=${a}, next.config.mjs=${b}`);
  } else if (!cfg.includes("`connect-src 'self' ${METRIKA_HOST}`")) {
    fail("хост Метрики не попал в connect-src — счётчик не сможет отправить визит");
  } else {
    ok(`счётчик Метрики: хост ${a} совпадает в коде и в политике`);
  }
} catch (e) {
  fail(`проверка счётчика не прошла: ${e.message}`);
}

// --- предложенная копия базы по ODbL §4.6
//
// Пункт чек-листа выхода в свет: «предложена копия адресной базы или файл изменений».
// Сама копия — `data/addresses.json` в этом публичном репозитории, то есть ровно тот файл,
// которым отвечает поиск адреса. Отдельная выгрузка в CSV не делается сознательно: два
// представления расходятся, а молча разошедшаяся выгрузка хуже одного формата.
//
// Значит проверять надо не «файл существует», а согласованность обеих сторон обязательства:
//   · в самой базе — лицензия, атрибуция и граница (без них копию нечем назвать копией);
//   · в `data/README.md` — те же лицензия и атрибуция, причём атрибуция ССЫЛКОЙ, как того
//     требует OSMF, и дата снимка, совпадающая с `timestamp_osm_base` исходника.
// Последнее — самое интересное: без сверки даты страница рано или поздно начнёт описывать
// выгрузку, которой уже не соответствует база, и это будет правдоподобный, но неверный текст.

try {
  const index = JSON.parse(await readFile("data/addresses.json", "utf8"));
  const raw = JSON.parse(await readFile("data/osm/malmyzh-raw.json", "utf8"));
  const doc = await readFile("data/README.md", "utf8");

  const problems = [];
  if (index.licence !== "ODbL 1.0") problems.push(`в базе licence=${JSON.stringify(index.licence)}`);
  if (!index.attribution?.includes("OpenStreetMap contributors")) {
    problems.push(`в базе attribution=${JSON.stringify(index.attribution)}`);
  }
  if (typeof index.boundary !== "string" || !index.boundary.startsWith("relation/")) {
    problems.push(`в базе boundary=${JSON.stringify(index.boundary)}`);
  }
  if (!doc.includes("ODbL")) problems.push("в data/README.md нет упоминания ODbL");
  // Атрибуция обязана быть ссылкой: OSMF требует не только «© OpenStreetMap contributors»,
  // но и адрес openstreetmap.org/copyright. Голое слово формально не выполняет требование.
  if (!/OpenStreetMap contributors\]\(https?:\/\/www\.openstreetmap\.org\/copyright\)/.test(doc)) {
    problems.push("в data/README.md атрибуция OpenStreetMap не оформлена ссылкой на copyright");
  }
  const snapshot = raw.osm3s?.timestamp_osm_base;
  if (!snapshot) {
    problems.push("в исходнике нет osm3s.timestamp_osm_base — сверять дату не с чем");
  } else if (!doc.includes(snapshot)) {
    problems.push(`дата снимка ${snapshot} не названа в data/README.md`);
  }

  if (problems.length > 0) {
    for (const p of problems) fail(`предложенная копия базы: ${p}`);
  } else {
    ok(
      `предложенная копия базы: ODbL 1.0, атрибуция ссылкой, граница ${index.boundary}, ` +
        `снимок ${snapshot}`,
    );
  }
} catch (e) {
  fail(`предложенная копия базы не проверяется: ${e.message}`);
}

process.exit(failed ? 1 : 0);
