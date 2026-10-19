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
//
// Переопределение пути к файлам, если понадобится: KARMAN_TOKEN_FILE,
// KARMAN_VAULT_URL.

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
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
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
  return Buffer.concat(chunks).toString("utf8").replace(/\r?\n$/, "");
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
    ok(`${key} прочитан обратно`);
    break;
  }

  default:
    fail("режимы: self | list | get KEY | put KEY[=ЗНАЧЕНИЕ]");
}
