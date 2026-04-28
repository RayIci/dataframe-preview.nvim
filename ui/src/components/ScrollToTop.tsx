import { useEffect, useRef, useState } from "react";
import { ChevronUp } from "lucide-react";

interface ScrollToTopProps {
  scrollRef: React.RefObject<HTMLDivElement | null>;
}

export function ScrollToTop({ scrollRef }: ScrollToTopProps) {
  const [visible, setVisible] = useState(false);
  // Keep a stable reference to the handler for cleanup
  const handlerRef = useRef<() => void>(() => {});

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;

    handlerRef.current = () => setVisible(el.scrollTop > 200);
    el.addEventListener("scroll", handlerRef.current, { passive: true });
    return () => el.removeEventListener("scroll", handlerRef.current);
  }, [scrollRef]);

  if (!visible) return null;

  return (
    <button
      onClick={() => scrollRef.current?.scrollTo({ top: 0, behavior: "smooth" })}
      className="fixed bottom-5 right-5 z-40 flex size-8 items-center justify-center
                 rounded-full bg-primary text-primary-foreground shadow-lg
                 hover:opacity-80 transition-opacity"
      aria-label="Scroll to top"
    >
      <ChevronUp size={14} />
    </button>
  );
}
