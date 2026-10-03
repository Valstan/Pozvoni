import Link from "next/link";
import { getPayload } from "payload";
import config from "@payload-config";
import { headers } from "next/headers";
import type { Metadata } from "next";
import SuggestForm from "@/components/SuggestForm";
import PageHead from "@/components/PageHead";
import DirectoryList from "@/components/DirectoryList";
import { FavoritesBar, type FavItem } from "@/components/Favorites";
import {
  CATEGORIES,
  ROOT_SITE,
  WHOLE_SERVICE_FALLBACK,
  resolveScope,
  resolveSite,
  siteHref,
  type EntryCategory,
} from "@/lib/sites";
import { CATEGORY_LABELS, shelfByKey } from "@/lib/shelves";
import { crowdReady, entryStats } from "@/lib/crowd-signals";
import { currentUser } from "@/lib/session";
import { marketReady, myClaims } from "@/lib/market";
import { ratingsReady, ratingStats } from "@/lib/ratings";
import { karmaReady, karmaStats } from "@/lib/karma";
import { commentCounts, commentsReady } from "@/lib/comments";

// Страница ходит в базу — пререндерить её на сборке нельзя (в CI базы нет),
// а кэшировать надолго не нужно: правки супер-админа должны быть видны сразу.
export const dynamic = "force-dynamic";

export async function generateMetadata({
  searchParams,
}: {
  searchParams: Promise<{ scope?: string }>;
}): Promise<Metadata> {
  const site = resolveSite((await headers()).get("host"));

  // Заголовок по полке (C1): «Магазины — ПОЗВОНИ — Малмыжский район» вместо общего на
  // всех скоупах. Берётся из заголовка полки, а не из категории: у «Услуг» их три, и
  // перечисление дало бы простыню. Дубли «Такси — Такси Малмыж…» нет: если metaTitle
  // уже начинается с названия полки, остаётся общий заголовок. Описание — общий
  // tagline: он и так про весь scope лица, а плодить строки на скоуп — класс #087.
  const scope = (await searchParams).scope;
  const shelf = shelfByKey(scope);
  const categories = resolveScope(site, scope);
  const scopeTitle =
    shelf?.title ??
    (categories?.length === 1 ? CATEGORY_LABELS[categories[0]] : null);
  const title =
    scopeTitle && !site.metaTitle.startsWith(scopeTitle)
      ? `${scopeTitle} — ${site.metaTitle}`
      : `Справочник номеров — ${site.metaTitle}`;

  return {
    title,
    description: site.tagline,
    openGraph: {
      title,
      description: site.tagline,
      type: "website",
      locale: "ru_RU",
      siteName: site.title,
    },
    twitter: { card: "summary", title, description: site.tagline },
  };
}

export default async function NomeraPage({
  searchParams,
}: {
  searchParams: Promise<{ scope?: string; q?: string; cat?: string }>;
}) {
  const site = resolveSite((await headers()).get("host"));

  // `?scope=` — общий адрес полки: сюда ведут плашки витрины, и он же остаётся дверью
  // «покажи всё» (`scope=all`, `WHOLE_SERVICE_FALLBACK`). Разбор значений и поведение при
  // мусоре в адресе — `resolveScope` в `lib/sites.ts`.
  const params = await searchParams;
  const scope = params.scope;
  const categories = resolveScope(site, scope);
  const showAll = categories === null;

  // Поиск `?q=` и чипсы `?cat=` — серверные, без JS: работают и с выключенными скриптами,
  // и индексируются как обычные адреса. Мусор в `cat` игнорируется, как мусор в `scope`:
  // человек приходит по ссылке из мессенджера, где адрес мог обрезаться.
  const q = (params.q ?? "").trim().slice(0, 80);
  const chipCats = categories ?? [...CATEGORIES];
  const activeCat =
    chipCats.find((c) => c === (params.cat ?? "").trim().toLowerCase()) ?? null;

  // Заголовки категорий над секциями нужны, только когда категорий больше одной: над
  // единственной полкой «Магазины» заголовок «Магазины» не сообщает ничего сверх того,
  // что уже сказано строкой состояния.
  const showHeadings = categories === null || categories.length > 1;

  // Полка, выбранная скоупом, — она же категория по умолчанию в форме предложения. Без
  // этого человек, пришедший с пустой плашки «Магазины», предложил бы магазин в такси:
  // форма всегда открывалась на «Такси».
  //
  // Полка с несколькими категориями («Услуги») тоже задаёт стартовую — первую свою:
  // иначе с неё форма опять открывалась бы на «Такси», ровно та ошибка, от которой этот
  // default защищает (см. комментарий к defaultCategory в SuggestForm).
  const shelfHere = shelfByKey(scope);
  const defaultCategory =
    shelfHere?.categories[0] ?? (categories?.length === 1 ? categories[0] : undefined);

  const payload = await getPayload({ config });
  // Access-правило коллекции само отдаёт анониму только опубликованное;
  // overrideAccess: false здесь — чтобы страница жила по тем же правилам,
  // что и весь остальной мир, а не в обход них.
  const { docs } = await payload.find({
    collection: "entries",
    overrideAccess: false,
    ...(categories ? { where: { category: { in: categories } } } : {}),
    limit: 500,
    sort: "name",
    depth: 0, // owner — id, не документ: посетителю чужой пользователь не отдаётся
  });
  // Агрегат сигналов — если схема уже есть; страница не зависит от миграции спринта 5.
  const stats = (await crowdReady()) ? await entryStats(docs.map((d) => d.id)) : undefined;
  // Кто смотрит (спринт 8): вошедшему — «Это мой бизнес» и состояние его заявок.
  const viewer = await currentUser();
  const claims = viewer && (await marketReady()) ? await myClaims(viewer.id) : undefined;
  const ratings = (await ratingsReady()) ? await ratingStats(docs.map((d) => d.id)) : undefined;
  const karma = (await karmaReady()) ? await karmaStats(docs.map((d) => d.id)) : undefined;
  // Комментарии (2026-09-10): одно число на карточку, сама лента грузится по нажатию.
  const comments = (await commentsReady()) ? await commentCounts(docs) : undefined;

  // Фильтр применяется к уже прочитанному срезу (≤500): лишних запросов в базу нет,
  // агрегаты (сигналы, рейтинги, карма, комментарии) посчитаны заранее по всем id и
  // для видимого подмножества берутся из тех же карт. Ищет по названию, адресу,
  // примечанию и номерам; цифры ищутся и без форматирования («8912» находит
  // «+7 912 …»).
  const needle = q.toLowerCase();
  const needleDigits = needle.replace(/\D/g, "");
  const visible = docs.filter((d) => {
    if (activeCat && d.category !== activeCat) return false;
    if (!needle) return true;
    const hay = [d.name, d.address ?? "", d.note ?? "", (d.phones ?? []).map((p) => p.number).join(" ")]
      .join(" ")
      .toLowerCase();
    if (hay.includes(needle)) return true;
    return needleDigits.length > 0 && hay.replace(/\D/g, "").includes(needleDigits);
  });

  // Ссылки чипсов и сброса: сохраняют соседние параметры, мусор не плодят.
  const filterHref = (cat: EntryCategory | null, keepQuery: boolean) => {
    const p = new URLSearchParams();
    if (scope) p.set("scope", scope);
    if (cat) p.set("cat", cat);
    if (keepQuery && q) p.set("q", q);
    const s = p.toString();
    return `/nomera${s ? `?${s}` : ""}`;
  };
  const filtering = q !== "" || activeCat !== null;

  // Компакт для секции «Моё»: только JSON-значения, без Map — границу сервер→клиент
  // переезжает штатно. Берём из видимого среза: секция показывает то же, что список.
  const favItems: FavItem[] = visible.map((d) => ({
    id: d.id,
    name: d.name,
    phones: (d.phones ?? []).map((p) => p.number),
  }));

  return (
    <main className="page" id="main" tabIndex={-1}>
      <PageHead title="Справочник номеров" sub={site.tagline}>
        <Link href="/">← к карте</Link>
        {site.id !== ROOT_SITE.id && !showAll && (
          <a href={siteHref(site, ROOT_SITE, "/nomera", WHOLE_SERVICE_FALLBACK)}>
            Весь справочник района
          </a>
        )}
      </PageHead>

      <p className="page-sub">
        {categories === null
          ? "Весь справочник района. "
          : `Полка: ${categories.map((c) => CATEGORY_LABELS[c]).join(", ")}. `}
        Нажмите на номер — телефон наберёт сам. Цены справочные, не оферта: уточняйте
        при звонке.
      </p>

      {/* Поиск и чипсы категорий (B1): обычная GET-форма и ссылки — без JS. Форма шлёт
          относительный action, поэтому на категорийном домене фильтр остаётся в нём. */}
      <form className="dir-filter" method="get" action="/nomera" role="search">
        {scope && <input type="hidden" name="scope" value={scope} />}
        {activeCat && <input type="hidden" name="cat" value={activeCat} />}
        <label className="search-label" htmlFor="nomera-q">
          Поиск по справочнику
        </label>
        <span className="dir-filter-row">
          <input
            id="nomera-q"
            className="search-input"
            type="search"
            name="q"
            defaultValue={q}
            maxLength={80}
            placeholder="название, адрес или номер"
          />
          <button className="dir-filter-btn" type="submit">
            Найти
          </button>
        </span>
      </form>

      {chipCats.length > 1 && (
        <nav className="dir-chips" aria-label="Категории">
          <a
            className={activeCat ? "dir-chip" : "dir-chip is-current"}
            href={filterHref(null, true)}
            aria-current={!activeCat ? "true" : undefined}
          >
            Все
          </a>
          {chipCats.map((c) => (
            <a
              key={c}
              className={activeCat === c ? "dir-chip is-current" : "dir-chip"}
              href={filterHref(c, true)}
              aria-current={activeCat === c ? "true" : undefined}
            >
              {CATEGORY_LABELS[c]}
            </a>
          ))}
        </nav>
      )}

      {filtering && (
        <p className="page-sub" role="status">
          {visible.length === 0
            ? "Ничего не нашлось. "
            : `Найдено: ${visible.length} из ${docs.length}. `}
          <a href={filterHref(null, false)}>Показать всё</a>
        </p>
      )}

      {docs.length === 0 && (
        <p className="page-sub">
          Пока пусто: номера появляются после проверки. Предложите свой — форма ниже.
        </p>
      )}

      {docs.length > 0 && visible.length === 0 && (
        <p className="page-sub">
          Ничего не подошло — <a href="#predlozhit">предложите номер</a>: проверим и
          добавим.
        </p>
      )}

      <FavoritesBar items={favItems} />

      <DirectoryList
        entries={visible}
        showHeadings={showHeadings}
        stats={stats}
        viewer={viewer}
        claims={claims}
        ratings={ratings}
        karma={karma}
        comments={comments}
      />

      <SuggestForm defaultCategory={defaultCategory} />

      <footer className="page-footer">
        <p>
          Заметили неверный номер или цену? Напишите об этом в форме выше — проверим и
          поправим. Комментарии под номерами — мнения посетителей:{" "}
          <Link href="/pravila">правила и как убрать комментарий</Link>.
        </p>
      </footer>
    </main>
  );
}
