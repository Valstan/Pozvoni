// Черновик первичной базы номеров, собранный из открытых источников 2026-08-29.
//
// ⚠️ ВСЁ здесь заводится со статусом «На проверке» и наружу НЕ публикуется:
// гейт владельца — каждый номер проверяется звонком или лично до публикации
// (решение 2026-08-29). Источник записан у каждой записи — по нему проверять.
//
// Сеется идемпотентно: запись с таким же названием повторно не создаётся.
//
// ⚠️ Частных мастеров из агрегаторов (Zoon, Profi и подобных) сюда НЕ сеем — это
// персональные данные без согласия (решение 2026-10-03). Только самопредложение через
// форму или публикация с согласия человека.

type DraftEntry = {
  name: string;
  category: "taxi" | "shop" | "master" | "brigade" | "cargo" | "gos" | "other";
  phones: { number: string }[];
  prices?: { label: string; value: string }[];
  note?: string;
  address?: string;
  hours?: string;
  source: string;
};

export const directoryDraft: DraftEntry[] = [
  {
    name: "Такси «Фортуна»",
    category: "taxi",
    phones: [{ number: "+7 922 664-90-77" }, { number: "+7 919 529-10-20" }],
    prices: [{ label: "По городу", value: "от 100 ₽" }],
    note: "Город и межгород",
    source: "reiting-taksi.ru/malmyzh, спутник-такси.рф — сверить оба",
  },
  {
    name: "Такси «Гермес»",
    category: "taxi",
    phones: [{ number: "+7 953 135-02-74" }, { number: "+7 912 717-04-16" }],
    prices: [{ label: "По городу", value: "от 100 ₽" }],
    source: "reiting-taksi.ru/malmyzh, спутник-такси.рф — сверить оба",
  },
  {
    name: "«Любимое такси»",
    category: "taxi",
    phones: [{ number: "+7 912 370-81-05" }],
    source: "reiting-taksi.ru/malmyzh",
  },
  {
    name: "Такси «Ветер»",
    category: "taxi",
    phones: [{ number: "+7 912 717-69-08" }],
    source: "reiting-taksi.ru/malmyzh",
  },
  {
    name: "Такси «Круиз»",
    category: "taxi",
    phones: [{ number: "+7 912 717-69-08" }, { number: "+7 922 970-87-95" }],
    note: "⚠️ Первый номер совпадает с «Ветром» — возможно, одна служба под двумя именами",
    source: "reiting-taksi.ru/malmyzh",
  },
  {
    name: "Яндекс Такси (федеральный)",
    category: "taxi",
    phones: [{ number: "8 800 770-70-74" }],
    note: "Федеральная линия; работает ли подача в Малмыже — проверить",
    source: "reiting-taksi.ru/malmyzh",
  },
  {
    name: "Межгород Малмыж—Казань",
    category: "taxi",
    phones: [{ number: "+7 917 249-79-00" }],
    prices: [{ label: "До Казани", value: "≈ 3 800 ₽" }],
    note: "⚠️ Агрегатор-справочник, не местная служба — проверить особо",
    source: "mezhgorod-taksi.ru/malmyzh",
  },
  {
    name: "Межгород (диспетчерская, круглосуточно)",
    category: "taxi",
    phones: [{ number: "+7 939 555-01-39" }],
    prices: [
      { label: "До Казани", value: "≈ 3 800 ₽" },
      { label: "До Ижевска", value: "≈ 7 200 ₽" },
      { label: "До Йошкар-Олы", value: "≈ 5 600 ₽" },
    ],
    note: "⚠️ Агрегатор-справочник, не местная служба — проверить особо",
    source: "mezhgorod-taksi.ru/malmyzh",
  },
  // ── Пакет 2026-10-03: магазины и инфраструктура (план обогащения, A1). ──
  // Всё — черновики: каждый номер проверяется звонком до публикации (гейт 2026-08-29).
  // Телефоны и часы — по открытым справочникам на дату сбора, могут быть несвежими.
  {
    name: "Пятёрочка",
    category: "shop",
    phones: [{ number: "8 800 555-55-05" }, { number: "+7 963 926-98-01" }],
    address: "ул. Ленина, 31",
    hours: "ежедневно 8:00–22:00",
    source: "orgsprav.com, jsprav.ru — сбор 2026-10-03",
  },
  {
    name: "Магнит Косметик",
    category: "shop",
    phones: [{ number: "8 800 200-90-02" }],
    address: "ул. Карла Маркса, 4",
    hours: "ежедневно 8:00–20:00",
    source: "spravker.ru — сбор 2026-10-03",
  },
  {
    name: "СтройМаркет «Добреев»",
    category: "shop",
    phones: [{ number: "+7 83347 2-15-94" }, { number: "+7 912 338-34-85" }],
    address: "ул. Урицкого, 2",
    note: "Стройматериалы и отделка",
    source: "dobreev21.orgs.biz — сбор 2026-10-03",
  },
  {
    name: "СтройБаза «Добреев»",
    category: "shop",
    phones: [{ number: "+7 83347 2-17-13" }, { number: "+7 912 828-33-85" }],
    address: "ул. Карла Маркса, 88",
    hours: "пн–пт 7:30–17:30, сб–вс 7:30–14:00",
    source: "dobreev21.orgs.biz, jsprav.ru — сбор 2026-10-03",
  },
  {
    name: "Магазин «Крепёж»",
    category: "shop",
    phones: [{ number: "+7 83347 2-18-14" }, { number: "+7 912 370-20-14" }],
    address: "ул. Урицкого, 2",
    source: "dobreev21.orgs.biz — сбор 2026-10-03",
  },
  {
    name: "Магазин «Интерьер»",
    category: "shop",
    phones: [{ number: "+7 83347 2-07-36" }, { number: "+7 912 724-65-42" }],
    address: "ул. Карла Маркса, 10",
    hours: "пн–пт 8:00–17:30, сб–вс 8:00–14:00",
    source: "spravker.ru — сбор 2026-10-03",
  },
  {
    name: "«Левша»",
    category: "shop",
    phones: [{ number: "+7 912 821-61-17" }],
    address: "ул. Свободы, 16",
    hours: "вт–пт 9:00–17:00, сб–вс 9:00–13:00",
    note: "Товары для дома",
    source: "spravker.ru — сбор 2026-10-03",
  },
  {
    name: "Магазин «Победа»",
    category: "shop",
    phones: [{ number: "+7 83347 2-06-62" }],
    address: "ул. Победы, 17",
    hours: "ежедневно 7:00–21:00",
    note: "Малмыжское райпо",
    source: "orgsprav.com — сбор 2026-10-03",
  },
  {
    name: "Магазин райпо",
    category: "shop",
    phones: [{ number: "+7 83347 2-19-92" }],
    address: "ул. Дружбы, 2",
    hours: "ежедневно 7:30–20:00",
    source: "orgsprav.com — сбор 2026-10-03",
  },
  {
    name: "«Всё для вас» (ИП Юнусова)",
    category: "shop",
    phones: [{ number: "+7 912 368-70-55" }],
    address: "ул. Комсомольская, 69",
    hours: "пн–пт 8:00–18:00, сб–вс 8:00–14:00",
    note: "Канцтовары",
    source: "orgsprav.com — сбор 2026-10-03",
  },
  {
    name: "Магазин «Малышок»",
    category: "shop",
    phones: [{ number: "+7 912 717-76-57" }],
    address: "ул. Комсомольская, 38",
    hours: "пн–пт 8:30–17:30, сб–вс 9:00–14:00",
    note: "Детские товары",
    source: "orgsprav.com — сбор 2026-10-03",
  },
  {
    name: "«Добреев Техно»",
    category: "shop",
    phones: [{ number: "+7 982 387-00-96" }],
    address: "ул. Урицкого, 2",
    hours: "пн–пт 8:00–18:00, сб–вс 8:00–14:00",
    note: "Товары для дома",
    source: "spravker.ru — сбор 2026-10-03",
  },
  {
    name: "ИП Асхатзянов",
    category: "shop",
    phones: [{ number: "+7 83347 2-13-72" }, { number: "+7 83347 2-12-62" }],
    address: "ул. Ленина, 32А",
    hours: "пн–пт 8:00–17:30",
    note: "Товары для дома",
    source: "spravker.ru — сбор 2026-10-03",
  },
  {
    name: "Малмыжский РЭС",
    category: "other",
    phones: [{ number: "+7 83347 2-11-47" }],
    address: "ул. Юбилейная, 6",
    note: "Филиал Кировэнерго",
    source: "jsprav.ru — сбор 2026-10-03",
  },
  {
    name: "АО «Малмыжский ремзавод»",
    category: "other",
    phones: [{ number: "+7 83347 2-16-75" }],
    address: "ул. Дружбы, 2",
    note: "⚠️ Телефон из раскрытия e-disclosure.ru (указан у руководителя) — при проверке уточнить общий номер",
    source: "e-disclosure.ru — сбор 2026-10-03",
  },
  {
    name: "МегаФон",
    category: "other",
    phones: [{ number: "8 800 550-05-00" }],
    address: "ул. Карла Маркса, 4",
    hours: "пн–пт 8:00–18:00, сб–вс 8:00–14:00",
    note: "Салон связи",
    source: "jsprav.ru — сбор 2026-10-03",
  },
];
