import type { MetadataRoute } from "next";
import { SITES } from "@/lib/sites";

// Sitemap для публичных страниц — рекомендация Яндекс Вебмастера.
// Страницы с личными данными (/zapis, /poezdki, /kabinet, /t/*, /admin, /api/*)
// в sitemap не входят: они либо запрещены в robots.txt, либо имеют свой noindex.
//
// Публичные страницы, которые должны быть в индексе:
//   /           — главная (карта, витрина полок, быстрый набор)
//   /nomera     — справочник номеров
//   /dannye     — уведомление о данных
//   /pravila    — правила комментариев
//
// Страницы без контента для поисковика (/zapis, /poezdki, /kabinet) не включены:
// они либо требуют входа, либо показывают 404 для гостя.

const PUBLIC_PATHS = ["/", "/nomera", "/dannye", "/pravila"];

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = new Date();

  const urls: MetadataRoute.Sitemap = [];

  for (const site of SITES) {
    if (!site.live) continue;

    for (const path of PUBLIC_PATHS) {
      urls.push({
        url: `https://${site.host}${path}`,
        lastModified,
        changeFrequency: path === "/" ? "daily" : "weekly",
        priority: path === "/" ? 1.0 : 0.8,
      });
    }
  }

  return urls;
}