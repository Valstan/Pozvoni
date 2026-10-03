import type { MetadataRoute } from "next";

// PWA-манифест (B6): «установить как приложение». Иконки PNG сгенерированы из
// `app/icon.svg` через sharp в `public/icons` (коммичены картинками, а не скриптом:
// перегенерировать понадобится, только если сменится сама иконка).
//
// Service worker'а нет осознанно: офлайн-стратегии без аккуратной инвалидации врали бы
// номерами, а карта и так своя. Манифест даёт установку и отдельный запуск — этого для
// звонилки достаточно.

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Позвони в Малмыже — справочник района",
    short_name: "Позвони",
    description:
      "Справочник Малмыжского района: такси, магазины, мастера, бригады, госучреждения.",
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#f6f5f2",
    theme_color: "#f6f5f2",
    lang: "ru",
    dir: "ltr",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
  };
}
