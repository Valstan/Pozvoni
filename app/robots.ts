import type { MetadataRoute } from "next";
import { ROOT_SITE } from "@/lib/sites";

// Страницы поездок не индексируются никогда (M0.A §6.4): в адресе — ключ доступа.
// Служебные страницы тоже. Глобальный noindex снят 2026-09-29: главная и справочник
// индексируемы.
//
// ⚠️ С 2026-09-10 строка `/api/` держит ещё и неиндексируемость КОММЕНТАРИЕВ посетителей:
// лента под номерами грузится роутом `/api/comment`, а не рисуется сервером, но поисковые
// роботы исполняют JS — без этого запрета текст третьих лиц уехал бы в выдачу в тот день,
// когда метатег в layout снимут (docs/COMMENTS.md). Убирать `/api/` отсюда нельзя.
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: "*", disallow: ["/t/", "/zapis", "/poezdki", "/admin", "/api/"] }],
    sitemap: `https://${ROOT_SITE.host}/sitemap.xml`,
  };
}
