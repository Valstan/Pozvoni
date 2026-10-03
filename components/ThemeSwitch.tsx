"use client";

import { useSyncExternalStore } from "react";

// Переключатель темы: светлая / тёмная / авто (решение владельца: обе темы с ручным
// выбором). Выбор хранится в localStorage, default — авто (системная).
//
// Без JS кнопка не работает, но тема и не ломается: скрипт в layout ставит data-theme
// до отрисовки, а без него решает prefers-color-scheme из CSS. Чтение через
// useSyncExternalStore, а не setState в useEffect: серверная разметка всегда «авто»
// (getServerSnapshot), клиент подтягивает сохранённое без каскадного рендера.

type Mode = "auto" | "light" | "dark";
const KEY = "pozvoni-theme";
const LABEL: Record<Mode, string> = {
  auto: "Тема: авто",
  light: "Тема: светлая",
  dark: "Тема: тёмная",
};
const NEXT: Record<Mode, Mode> = { auto: "light", light: "dark", dark: "auto" };

let cached: Mode | null = null;
const listeners = new Set<() => void>();

function readMode(): Mode {
  if (cached) return cached;
  try {
    const v = window.localStorage.getItem(KEY);
    cached = v === "light" || v === "dark" ? v : "auto";
  } catch {
    cached = "auto";
  }
  return cached;
}

function writeMode(mode: Mode) {
  cached = mode;
  try {
    if (mode === "auto") window.localStorage.removeItem(KEY);
    else window.localStorage.setItem(KEY, mode);
  } catch {
    // Приватный режим: тема применится, но не запомнится.
  }
  if (mode === "auto") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", mode);
  listeners.forEach((l) => l());
}

function subscribe(notify: () => void): () => void {
  listeners.add(notify);
  // Чужая вкладка сменила тему — подхватить и здесь.
  const onStorage = () => {
    cached = null;
    notify();
  };
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(notify);
    window.removeEventListener("storage", onStorage);
  };
}

export default function ThemeSwitch() {
  const mode = useSyncExternalStore(subscribe, readMode, () => "auto" as Mode);

  return (
    <button
      type="button"
      className="tb-theme"
      onClick={() => writeMode(NEXT[mode])}
      title="Переключить тему: авто, светлая, тёмная"
    >
      {LABEL[mode]}
    </button>
  );
}
