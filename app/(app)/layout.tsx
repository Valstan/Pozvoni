import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import Script from "next/script";
import Metrika from "@/components/Metrika";
import SiteToolbar from "@/components/SiteToolbar";
import { resolveSite } from "@/lib/sites";
import "./globals.css";

// Заголовок и описание зависят от домена матрёшки (`lib/sites.ts`): на
// `такси.вмалмыже.рф` во вкладке должно стоять «ТАКСИ МАЛМЫЖ», а не «ПОЗВОНИ» —
// иначе поддомен выглядит чужой страницей, случайно отдавшей другой сайт.
export async function generateMetadata(): Promise<Metadata> {
  const site = resolveSite((await headers()).get("host"));

  return {
    title: { default: site.metaTitle, template: "%s" },
    description: site.tagline,
    // Canonical НЕ ставится здесь: общий корневой canonical отправлял /nomera и
    // остальные страницы в дубликат главной и душил их индексацию (вскрытие
    // 2026-10-07). Каждая индексируемая страница ставит свой через
    // `siteCanonical` (см. главную, /nomera, /kontakty, /dannye).
    // Иконка для «добавить на домашний экран» у Apple: PNG 192 из public/icons
    // (сгенерированы из app/icon.svg через sharp). Манифест — app/manifest.ts.
    icons: { apple: "/icons/icon-192.png" },
    appleWebApp: { capable: true, title: "Позвони", statusBarStyle: "default" },
    // Глобальный noindex убран 2026-09-29: сайт работает открыто, главная и справочник
    // должны быть в индексе. Страницы с личными данными (/zapis, /poezdki, /kabinet,
    // /t/*, /admin, /api/*) имеют свой локальный robots: { index: false, follow: false }.
  };
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#f6f5f2" },
    { media: "(prefers-color-scheme: dark)", color: "#161513" },
  ],
};

// Выбор темы применяется ДО отрисовки: сохранённое в localStorage значение ставится на
// <html> раньше первого paint, и тёмная не моргает светлой. Скрипт инлайн и синхронный
// намеренно; CSP его разрешает (`script-src 'unsafe-inline'`, next.config.mjs). Без
// сохранённого выбора — ничего: решает prefers-color-scheme из CSS (режим «авто»).
const THEME_BOOT = `try{var t=localStorage.getItem("pozvoni-theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}`;

// ⚠️ Тулбар в корневом layout делает динамическими ВСЕ страницы группы `(app)`: он читает
// `Host` и сессию. Сегодня это ничего не ломает — все семь страниц и так объявляли
// `dynamic = "force-dynamic"`, — но с этого дня статической страницы под `(app)` быть уже
// не может, и это ограничение постоянное.
//
// ⚠️ И второе следствие: имя вошедшего теперь есть в HTML ЛЮБОЙ страницы. Общий кэш перед
// приложением (`proxy_cache` у nginx, CDN) стал бы утечкой имён между людьми. Сейчас его
// нет — динамические ответы App Router уходят с `no-store`, а `deploy/nginx.conf.example`
// кэш не включает; появится — это инвариант, который придётся держать явно.
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru">
      <body>
        <Script id="pozvoni-theme" strategy="beforeInteractive">
          {THEME_BOOT}
        </Script>
        {/* Бар добавляет четыре-шесть остановок табуляции перед содержимым на каждой
            странице — без этой ссылки клавиатурой до текста не добраться коротким путём. */}
        <a className="skip-link" href="#main">
          К содержимому
        </a>
        <SiteToolbar />
        {children}
        {/* Счётчик — последним в body и только в проде: `lib/metrika.ts`. */}
        <Metrika />
      </body>
    </html>
  );
}
