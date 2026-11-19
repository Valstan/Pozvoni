// Комната КАРМАНа с машины владельца (D-102).
//
// Пишущий токен комнаты живёт у владельца, вне репозитория: по умолчанию
// `%USERPROFILE%\.karman\pozvoni.token`, адрес хранилища — рядом
// (`pozvoni.vault-url`). Оба значения — recon (AGENTS.md, D-038): в отслеживаемые
// файлы они не попадают, и этот скрипт их не печатает.
//
// Зачем клиент, если CI ходит паспортом: строка канона (форма Б) разрешает
// паспортную сессию на деплое, но пишущий токен остаётся у владельца — им надо
// уметь пользоваться, не сочиняя curl заново. Радиус тот же, что у файла: кто
// читает домашний каталог, тот читает и комнату.
//
// Правила печати — как у инструментов деплоя: имена ключей можно, значения —
// только по явному `get`; тело чужого ответа не печатаем целиком (в не-контрактном
// ответе прокси виден хостнейм, а маска раннера знает только точное значение
// секрета).
//
//   node scripts/karman.mjs self              — кто я и есть ли право записи
//   node scripts/karman.mjs list              — имена ключей комнаты
//   node scripts/karman.mjs get KEY           — значение ключа (явный запрос)
//   node scripts/karman.mjs put KEY           — значение со stdin (не попадает в историю shell)
//   node scripts/karman.mjs put KEY=ЗНАЧЕНИЕ  — то же, но значение в командной строке
//   node scripts/karman.mjs grant KEY КОМНАТА — предложить выдачу ключа в другую комнату
//   node scripts/karman.mjs grants            — выдачи: предложенные нами и предложенные нам
//   node scripts/karman.mjs revoke-grant ID   — отозвать предложение (с любой стороны)
//   node scripts/karman.mjs section [РАЗДЕЛ]  — живые промты раздела (токен раздела из комнаты)
//   node scripts/karman.mjs archive РАЗДЕЛ ID — отправить промт раздела в архив
//
// Переопределение пути к файлам, если понадобится: KARMAN_TOKEN_FILE,
// KARMAN_VAULT_URL. Канал промтов живёт на том же сервисе, что и хранилище;
// если он на другой адрес — KARMAN_PROMPTS_URL.

import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function ok(message) {
  console.log(`✓ ${message}`);
}

const tokenFile =
  process.env.KARMAN_TOKEN_FILE ?? path.join(homedir(), ".karman", "pozvoni.token");
const urlFile = tokenFile.endsWith(".token")
  ? `${tokenFile.slice(0, -".token".length)}.vault-url`
  : `${tokenFile}.url`;

async function readTrimmed(file, what) {
  try {
    return (await readFile(file, "utf8")).trim();
  } catch {
    return fail(`нет файла с ${what}: ${file} (нужен доступ только владельцу)`);
  }
}

const token = process.env.KARMAN_TOKEN ?? (await readTrimmed(tokenFile, "токеном комнаты"));
const base = (process.env.KARMAN_VAULT_URL ?? (await readTrimmed(urlFile, "адресом хранилища"))).replace(/\/+$/, "");

// Ошибку сокращаем до контрактного поля: остальное тело — не наше дело.
function brief(body) {
  try {
    const parsed = JSON.parse(body);
    const field = parsed?.error ?? parsed?.missing;
    if (field) return ` — ${String(JSON.stringify(field)).slice(0, 200)}`;
  } catch {
    // не JSON: печатать нечего
  }
  return "";
}

async function call(method, url, payload) {
  return callWith(method, url, payload, token);
}

// Тот же вызов, но с ЧУЖИМ для комнаты токеном — токеном раздела промтов.
// Он не имеет права записи в хранилище и видит только свой раздел.
async function callWith(method, url, payload, bearer) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${bearer}`,
      ...(payload ? { "Content-Type": "application/json" } : {}),
    },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await response.text();
  return { status: response.status, text };
}

// `/api/secrets` отдаёт ТОЛЬКО `{secrets:{…}}` — поля права в нём нет (сниппет
// KARMAN_ROOM.md «проверка права» этим путём даёт пустоту, см. письмо в Мозг:
// право живёт в ответе `claim` и в `/self`). Поэтому право спрашиваем у `/self`.
async function whoami() {
  const { status, text } = await call("GET", `${base}/api/secrets/self`);
  if (status !== 200) fail(`self -> ${status}${brief(text)}`);
  const { slug, canWrite, identity } = JSON.parse(text);
  return { slug, canWrite: canWrite === true, identity: Boolean(identity) };
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  // BOM из пайпа (PowerShell 5.1 кодирует stdin для нативной программы с BOM) —
  // в значении секрета ему не место: значение пойдёт в заголовок Bearer, где
  // U+FEFF ломает запрос (fetch требует ByteString). Раньше это проходило
  // молча: значение записывалось, читалось обратно — и оставалось испорченным.
  return Buffer.concat(chunks)
    .toString("utf8")
    .replace(/^\uFEFF+/, "")
    .replace(/\r?\n$/, "");
}

const [command, ...rest] = process.argv.slice(2);

switch (command) {
  case "self": {
    const { slug, canWrite, identity } = await whoami();
    // projectId не печатаем: это порядковый номер комнаты в общем хранилище
    // (D-038, «состав соседей»).
    ok(`комната ${slug}: право записи ${canWrite ? "есть" : "нет"}, вход через ${identity ? "паспорт" : "статический токен"}`);
    break;
  }

  case "list": {
    const { canWrite } = await whoami();
    const { status, text } = await call("GET", `${base}/api/secrets`);
    if (status !== 200) fail(`list -> ${status}${brief(text)}`);
    const { secrets } = JSON.parse(text);
    const names = Object.keys(secrets ?? {});
    ok(`ключей ${names.length}; право записи ${canWrite ? "есть" : "нет"}`);
    for (const name of names) console.log(name);
    break;
  }

  case "get": {
    const key = rest[0];
    if (!key) fail("укажи ключ: karman.mjs get KEY");
    const { status, text } = await call("GET", `${base}/api/secrets?key=${encodeURIComponent(key)}`);
    if (status === 404) fail(`ключа ${key} в комнате нет (404, G331: промах назван)`);
    if (status !== 200) fail(`get ${key} -> ${status}${brief(text)}`);
    const { secrets } = JSON.parse(text);
    const value = secrets?.[key];
    if (value === undefined) fail(`${key} отсутствует в ответе`);
    process.stdout.write(value.endsWith("\n") ? value : `${value}\n`);
    break;
  }

  case "put": {
    if (!rest[0]) fail("укажи ключ: karman.mjs put KEY (значение со stdin) или KEY=ЗНАЧЕНИЕ");
    const eq = rest[0].indexOf("=");
    const key = eq === -1 ? rest[0] : rest[0].slice(0, eq);
    const value = eq === -1 ? await readStdin() : rest.join(" ").slice(eq + 1);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) fail(`имя ключа не env-стиля: ${key}`);
    if (value === "") fail("значение пустое — записывать нечего");
    const { status, text } = await call("POST", `${base}/api/secrets`, { secrets: { [key]: value } });
    if (status !== 200 && status !== 201) fail(`put ${key} -> ${status}${brief(text)}`);
    const { written } = JSON.parse(text);
    // Значение не печатаем даже здесь: подтверждение — со стороны хранилища.
    ok(`${key} записан (полей записано: ${written ?? "?"})`);
    const back = await call("GET", `${base}/api/secrets?key=${encodeURIComponent(key)}`);
    if (back.status !== 200) fail(`записанное не читается обратно (${back.status}) — зеркало не подтверждено`);
    const stored = JSON.parse(back.text).secrets?.[key];
    // Сверка ЗНАЧЕНИЯ, а не только ключа: зеркало может вернуть другое значение
    // (например, с испорченной кодировкой), и это обязано быть видно сразу.
    if (stored !== value) {
      fail(`прочитанное обратно не равно записанному (${key}) — зеркало исказило значение`);
    }
    ok(`${key} прочитан обратно — значение совпало побайтно`);
    break;
  }

  case "grant": {
    const key = rest[0];
    const target = rest[1];
    if (!key || !target) fail("укажи ключ и комнату: karman.mjs grant KEY КОМНАТА [ЗАМЕТКА]");
    const note = rest.slice(2).join(" ");
    const { status, text } = await call("POST", `${base}/api/secrets/grants`, {
      key,
      target_slug: target,
      alias: key,
      note: note || "Выдача токена раздела проекта",
    });
    if (status !== 200 && status !== 201) fail(`grant ${key} -> ${status}${brief(text)}`);
    const { id, state } = JSON.parse(text);
    // Состояние важнее id: 'active' — получатель принял сразу (политика приёма),
    // 'pending' — ждёт приёма комнатой-получателем своим токеном.
    ok(`выдача предложена: id ${id}, состояние ${state}`);
    if (state === "pending") {
      console.log(
        "  предложение ждёт приёма комнатой-получателем своим токеном: политика приёма в ней → перепредложить → отозвать старое",
      );
    }
    break;
  }

  case "grants": {
    const { status, text } = await call("GET", `${base}/api/secrets/grants`);
    if (status !== 200) fail(`grants -> ${status}${brief(text)}`);
    const { issued = [], received = [] } = JSON.parse(text);
    const line = (g, side) =>
      `  ${side} #${g.id} ${g.key ?? g.sourceKey} ${side === "наша" ? "→" : "←"} ${g.targetSlug ?? g.sourceSlug ?? "?"} [${g.state ?? "?"}]`;
    console.log(`предложенных нами: ${issued.length}`);
    for (const g of issued) console.log(line(g, "наша"));
    console.log(`предложенных нам: ${received.length}`);
    for (const g of received) console.log(line(g, "нам"));
    break;
  }

  case "revoke-grant": {
    const id = Number(rest[0]);
    if (!Number.isInteger(id)) fail("укажи id выдачи: karman.mjs revoke-grant ID");
    const { status, text } = await call("DELETE", `${base}/api/secrets/grants`, { id });
    if (status !== 200) fail(`revoke-grant ${id} -> ${status}${brief(text)}`);
    ok(`выдача #${id} отозвана`);
    break;
  }

  case "section":
  case "archive": {
    // Токен раздела — секрет нашей комнаты; в Bearer он уходит из комнаты
    // напрямую и в командную строку не попадает.
    const section = rest[0] ?? "Pozvoni";
    const secretName = `PROMPTS_TOKEN_${String(section).toUpperCase().replace(/[^A-Z0-9]+/g, "_")}`;
    const got = await call("GET", `${base}/api/secrets?key=${encodeURIComponent(secretName)}`);
    if (got.status !== 200) fail(`в комнате нет ${secretName} — сначала выпустите токен раздела`);
    const sectionToken = JSON.parse(got.text).secrets?.[secretName];
    if (!sectionToken) fail(`в комнате нет ${secretName}`);

    const promptsBase = (process.env.KARMAN_PROMPTS_URL ?? base).replace(/\/+$/, "");
    if (command === "section") {
      const archived = rest.includes("--archived") ? "1" : "0";
      const { status, text } = await callWith(
        "GET",
        `${promptsBase}/api/prompts/section?project=${encodeURIComponent(section)}&archived=${archived}`,
        undefined,
        sectionToken,
      );
      if (status === 503) fail("канал раздела не настроен (503) — токен ещё не дошёл до сервиса");
      if (status !== 200) fail(`section -> ${status}${brief(text)}`);
      const { prompts = [] } = JSON.parse(text);
      console.log(`раздел ${section}: промтов ${prompts.length}`);
      for (const p of prompts) {
        console.log(`  #${p.id} [${p.source ?? "?"}] ${p.title ?? "(без темы)"}`);
      }
      if (prompts.length === 0) console.log("  (пусто — живых промтов нет)");
      break;
    }

    const id = Number(rest[1]);
    if (!Number.isInteger(id)) fail("укажи id промта: karman.mjs archive РАЗДЕЛ ID");
    const { status, text } = await callWith(
      "POST",
      `${promptsBase}/api/prompts/section`,
      { project: section, id, archived: true },
      sectionToken,
    );
    if (status !== 200) fail(`archive -> ${status}${brief(text)}`);
    ok(`промт #${id} раздела ${section} отправлен в архив`);
    break;
  }

  default:
    fail(
      "режимы: self | list | get KEY | put KEY[=ЗНАЧЕНИЕ] | grant KEY КОМНАТА | grants | revoke-grant ID | section [РАЗДЕЛ] | archive РАЗДЕЛ ID",
    );
}
