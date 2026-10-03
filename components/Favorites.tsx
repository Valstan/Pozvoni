"use client";

import { useSyncExternalStore } from "react";

// Избранное (B4): звезда на карточке и секция «Моё» на /nomera.
//
// Только localStorage этого устройства — ни аккаунта, ни сервера, ни персональных данных
// (нечего хранить по 152-ФЗ: список лежит у человека в браузере, а не у нас в базе).
// Без JS звёзд нет, но справочник работает целиком: деградация честная, а не молчаливая.
//
// Синхронизация звезды и секции — через useSyncExternalStore: серверная разметка всегда
// «не в избранном», клиент подтягивает сохранённое без каскадного рендера (тот же приём,
// что в ThemeSwitch — линтер setState в эффекте не пропускает).

const KEY = "pozvoni-fav";
const EVENT = "pozvoni-fav";

let cache: number[] | null = null;
const listeners = new Set<() => void>();

function readIds(): number[] {
  if (cache) return cache;
  try {
    const raw = window.localStorage.getItem(KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    cache = Array.isArray(parsed)
      ? [...new Set(parsed.filter((v): v is number => typeof v === "number" && Number.isInteger(v)))]
      : [];
  } catch {
    cache = [];
  }
  return cache;
}

function writeIds(ids: number[]) {
  cache = ids;
  try {
    if (ids.length === 0) window.localStorage.removeItem(KEY);
    else window.localStorage.setItem(KEY, JSON.stringify(ids));
  } catch {
    // Приватный режим: звезда поработает до перезагрузки.
  }
  window.dispatchEvent(new CustomEvent(EVENT));
  listeners.forEach((l) => l());
}

function subscribe(notify: () => void): () => void {
  listeners.add(notify);
  const onExternal = () => {
    cache = null;
    notify();
  };
  window.addEventListener(EVENT, onExternal);
  window.addEventListener("storage", onExternal);
  return () => {
    listeners.delete(notify);
    window.removeEventListener(EVENT, onExternal);
    window.removeEventListener("storage", onExternal);
  };
}

function toggle(id: number) {
  const has = readIds().includes(id);
  writeIds(has ? readIds().filter((v) => v !== id) : [...readIds(), id]);
}

/** Звезда на карточке. Сервер всегда рисует «не в избранном» — клиент поправляет. */
export function FavoriteStar({ id }: { id: number }) {
  const ids = useSyncExternalStore(subscribe, readIds, () => [] as number[]);
  const on = ids.includes(id);
  return (
    <button
      type="button"
      className={on ? "fav-star is-on" : "fav-star"}
      aria-pressed={on}
      aria-label={on ? "Убрать из избранного" : "В избранное"}
      title={on ? "Убрать из избранного" : "В избранное"}
      onClick={() => toggle(id)}
    >
      {on ? "★" : "☆"}
    </button>
  );
}

export type FavItem = { id: number; name: string; phones: string[] };

/** Секция «Моё»: быстрый звонок по избранному. Пусто — секции нет вовсе. */
export function FavoritesBar({ items }: { items: FavItem[] }) {
  const ids = useSyncExternalStore(subscribe, readIds, () => [] as number[]);
  if (ids.length === 0) return null;
  const mine = items.filter((it) => ids.includes(it.id));
  if (mine.length === 0) return null;
  return (
    <section className="favs" aria-label="Избранное">
      <h2 className="favs-title">Моё · {mine.length}</h2>
      <ul className="favs-list">
        {mine.map((it) => (
          <li key={it.id} className="favs-row">
            <span className="favs-name">{it.name}</span>
            {it.phones.map((p) => (
              <a key={p} className="dir-phone" href={`tel:${p.replace(/[^\d+]/g, "")}`}>
                {p}
              </a>
            ))}
          </li>
        ))}
      </ul>
    </section>
  );
}
