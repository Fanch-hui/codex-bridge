"use client";

import { useEffect, useRef, useState } from "react";
import type { SetStateAction } from "react";

export function useDraft<T>(key: string, initial: T) {
  const [value, setValue] = useState(initial);
  const [loaded, setLoaded] = useState(false);
  const current = useRef(initial);
  useEffect(() => {
    try {
      const saved = sessionStorage.getItem(key);
      if (saved) { current.current = JSON.parse(saved) as T; setValue(current.current); }
    } catch {
      // The editor remains usable when browser storage is unavailable.
    }
    setLoaded(true);
  }, [key]);
  const update = (next: SetStateAction<T>) => {
    const result = typeof next === "function" ? (next as (value: T) => T)(current.current) : next;
    current.current = result;
    try { sessionStorage.setItem(key, JSON.stringify(result)); } catch {}
    setValue(result);
  };
  const reset = (next: T) => {
    try { sessionStorage.removeItem(key); } catch {}
    current.current = next;
    setValue(next);
  };
  return { value, setValue: update, reset, loaded };
}
